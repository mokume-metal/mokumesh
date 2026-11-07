// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import IOSurface
import MokumeshLinkC

/// 受け渡す画素の形式。
///
/// 送り手が名乗り、受け手がその形式で面を用意する (ADR-0001 決定 3)。
public enum LinkFormat: UInt32, Sendable, CaseIterable {
    /// 8 bit の RGBA。原色は Display P3、値には sRGB の曲線が掛かっている。alpha は straight。
    ///
    /// mokume の出口 (`OutputFrame.texture`) が渡す絵そのものの形式である。
    case rgba8DisplayP3 = 1

    /// 1 画素あたりのバイト数。
    public var bytesPerPixel: Int {
        switch self {
        case .rgba8DisplayP3: 4
        }
    }

    /// IOSurface の画素形式 (`'RGBA'`)。
    var surfacePixelFormat: OSType {
        switch self {
        case .rgba8DisplayP3: 0x5247_4241
        }
    }
}

/// 受け渡しの失敗。
public enum LinkError: Error, Equatable, Sendable {
    /// 受け手の名前を bootstrap に登録できなかった (同じチャンネルの受け手が既に居るなど)。
    case checkInFailed(channel: String, code: Int32)
    /// 受け口を作れなかった。
    case portAllocationFailed(code: Int32)
}

/// 送り手と受け手が出会うための名前。
///
/// 受け手が `org.mokume-metal.mokumesh.<チャンネル>` を bootstrap に登録し、送り手が
/// それを引く。同じ Mac の上で受け手を複数動かすときは、チャンネルを分ける。
public enum LinkChannel {
    /// 何も指定しないときのチャンネル。
    public static let defaultName = "default"

    static func serviceName(_ channel: String) -> String {
        "org.mokume-metal.mokumesh.\(channel)"
    }
}

/// host time (`mach_absolute_time`) を秒へ直す。
public enum HostTime {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// いまの host time。
    public static func now() -> UInt64 { mach_absolute_time() }

    /// host time の差を秒にする。
    public static func seconds(_ ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }

    /// `later - earlier` を秒にする。`later` のほうが前なら負になる。
    public static func interval(from earlier: UInt64, to later: UInt64) -> Double {
        later >= earlier ? seconds(later - earlier) : -seconds(earlier - later)
    }
}

// MARK: - メッセージ

/// 1 通の中身。C の固定長の構造体を、Swift から扱いやすい形にしたもの。
struct LinkMessage {
    var kind: MokumeshKind
    var version: UInt32 = UInt32(MOKUMESH_PROTOCOL_VERSION)
    var generation: UInt32 = 0
    var slot: UInt32 = 0
    var width: UInt32 = 0
    var height: UInt32 = 0
    var format: UInt32 = 0
    var surfaceCount: UInt32 = 0
    var frame: Int64 = 0
    var time: Double = 0
    var handedHostTime: UInt64 = 0
    var readyHostTime: UInt64 = 0
    var stream: String = ""

    init(kind: MokumeshKind) { self.kind = kind }

    init(_ payload: MokumeshPayload) {
        kind = MokumeshKind(rawValue: payload.kind)
        version = payload.version
        generation = payload.generation
        slot = payload.slot
        width = payload.width
        height = payload.height
        format = payload.format
        surfaceCount = payload.surfaceCount
        frame = payload.frame
        time = payload.time
        handedHostTime = payload.handedHostTime
        readyHostTime = payload.readyHostTime
        stream = withUnsafeBytes(of: payload.stream) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    var payload: MokumeshPayload {
        var payload = MokumeshPayload()
        payload.kind = kind.rawValue
        payload.version = version
        payload.generation = generation
        payload.slot = slot
        payload.width = width
        payload.height = height
        payload.format = format
        payload.surfaceCount = surfaceCount
        payload.frame = frame
        payload.time = time
        payload.handedHostTime = handedHostTime
        payload.readyHostTime = readyHostTime
        withUnsafeMutableBytes(of: &payload.stream) { raw in
            // 最後の 1 バイトは NUL のために空ける。UTF-8 の途中で切らない
            var utf8 = Array(stream.utf8)
            while utf8.count > raw.count - 1 { utf8.removeLast() }
            while !utf8.isEmpty, String(validating: utf8, as: UTF8.self) == nil { utf8.removeLast() }
            raw.copyBytes(from: utf8)
        }
        return payload
    }
}

/// 送るときの port の並び。使わない枠は `MACH_PORT_NULL`。
struct LinkPorts {
    var names: [mach_port_t] = Array(repeating: mach_port_t(MACH_PORT_NULL), count: Int(MOKUMESH_PORT_COUNT))
    var dispositions: [mach_msg_type_name_t] = Array(
        repeating: mach_msg_type_name_t(MACH_MSG_TYPE_COPY_SEND), count: Int(MOKUMESH_PORT_COUNT))
}

enum LinkTransport {
    /// 1 通を送る。送れなければ C の層が MOVE の権利を片付けている。
    static func send(
        _ message: LinkMessage, to destination: mach_port_t, ports: LinkPorts = LinkPorts(),
        timeoutMs: UInt32 = 100
    ) -> kern_return_t {
        var payload = message.payload
        return ports.names.withUnsafeBufferPointer { names in
            ports.dispositions.withUnsafeBufferPointer { dispositions in
                mokumesh_send(destination, &payload, names.baseAddress, dispositions.baseAddress, timeoutMs)
            }
        }
    }

    /// 1 通を受ける。`timeoutMs` が `nil` なら届くまで待つ。受けた port の権利は呼び手のもの。
    static func receive(on port: mach_port_t, timeoutMs: UInt32?) -> (LinkMessage, [mach_port_t])? {
        var payload = MokumeshPayload()
        var names = Array(repeating: mach_port_t(MACH_PORT_NULL), count: Int(MOKUMESH_PORT_COUNT))
        let result = names.withUnsafeMutableBufferPointer { buffer in
            mokumesh_receive(port, &payload, buffer.baseAddress, timeoutMs == nil ? 1 : 0, timeoutMs ?? 0)
        }
        guard result == KERN_SUCCESS else { return nil }
        return (LinkMessage(payload), names)
    }

    /// 受けた port の権利を全部手放す。
    static func releaseAll(_ ports: [mach_port_t]) {
        for port in ports where port != MACH_PORT_NULL { mokumesh_release_send(port) }
    }
}

/// 受け手が面を作るときの大きさと形式。
func makeSurface(width: Int, height: Int, format: LinkFormat) -> IOSurfaceRef? {
    let bytesPerRow = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * format.bytesPerPixel)
    let properties: [CFString: Any] = [
        kIOSurfaceWidth: width,
        kIOSurfaceHeight: height,
        kIOSurfaceBytesPerElement: format.bytesPerPixel,
        kIOSurfaceBytesPerRow: bytesPerRow,
        kIOSurfacePixelFormat: format.surfacePixelFormat,
    ]
    return IOSurfaceCreate(properties as CFDictionary)
}
