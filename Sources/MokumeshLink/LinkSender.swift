// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import IOSurface
import MokumeshLinkC

/// 送り手の側の受け渡し。mokume にも Metal にも依存しない。
///
/// 面は受け手が用意する。送り手は毎フレーム ``prepare(width:height:format:)`` で
/// 繋がりと面の組を整え、``acquire()`` で空いている面を 1 枚借りて書き、書き終えたら
/// ``publish(_:frame:time:handedHostTime:)`` で知らせる。書けなかったら
/// ``abandon(_:)`` で借りた面を戻す。
///
/// ``publish(_:frame:time:handedHostTime:)`` と ``abandon(_:)`` はどのスレッドから
/// 呼んでもよい (GPU の完了の知らせから呼ぶため)。それ以外は 1 つのスレッドから呼ぶ。
public final class LinkSender: Sendable {
    /// 借りた 1 枚。
    public struct Slot: Sendable, Equatable {
        public let generation: UInt32
        public let index: UInt32
        nonisolated(unsafe) public let surface: IOSurfaceRef

        public static func == (lhs: Slot, rhs: Slot) -> Bool {
            lhs.generation == rhs.generation && lhs.index == rhs.index
        }
    }

    /// 数えたもの。検査と計測のためにある。
    public struct Counters: Sendable, Equatable {
        /// 受け手へ届けた FRAME の数。
        public var framesPublished = 0
        /// 空いている面が無く、送れなかったフレームの数。
        public var framesDropped = 0
        /// 受け手を引けた回数 (繋ぎ直すたびに増える)。
        public var connections = 0
        /// 面が空かないまま続いたので、名乗り直して面の組を作り直してもらった回数。
        public var regenerations = 0
    }

    public let channel: String
    public let stream: String

    /// 受け手が見つからないとき、次に引きに行くまでの間。
    public static let lookUpInterval: TimeInterval = 0.5

    /// 空いている面が無いまま、名乗り直すまでに許すフレームの数。
    ///
    /// 受け手が面を返す通 (RELEASE) が失われると、その面は二度と空かない。3 枚とも失うと
    /// 送り手は止まったままになる。60fps で 0.5 秒続いたら、面の組を作り直してもらって立ち直る。
    public static let starvationLimit = 30

    private enum Phase {
        /// 受け手を引けていない。
        case disconnected(lastAttempt: Date?)
        /// HELLO を送り、面を待っている。
        case waiting(receiver: mach_port_t, width: Int, height: Int, format: LinkFormat)
        /// 面がある。
        case ready(receiver: mach_port_t, width: Int, height: Int, format: LinkFormat, generation: UInt32,
            surfaces: [IOSurfaceRef], free: Set<UInt32>)
    }

    private struct State {
        var phase = Phase.disconnected(lastAttempt: nil)
        var counters = Counters()
        /// 続けて面が空いていなかった回数。
        var starved = 0
    }

    /// 受け手からの通 (SURFACES・RELEASE) を受ける口。
    private let replyPort: mach_port_t
    private let state = Locked(State())

    public init(channel: String = LinkChannel.defaultName, stream: String = "main") throws(LinkError) {
        self.channel = channel
        self.stream = stream
        var port = mach_port_t(MACH_PORT_NULL)
        let result = mokumesh_allocate_port(&port)
        guard result == KERN_SUCCESS else { throw .portAllocationFailed(code: result) }
        replyPort = port
    }

    deinit {
        close()
        mokumesh_destroy_receive(replyPort)
    }

    /// BYE を送らずに受け口を壊す。送り手のプロセスが落ちたときと同じことを、検査で起こす。
    func destroyWithoutGoodbye() {
        mokumesh_destroy_receive(replyPort)
    }

    public var counters: Counters { state.withLock { $0.counters } }

    /// 面があり、書ける状態か。
    public var isReady: Bool {
        state.withLock { state in
            if case .ready = state.phase { return true }
            return false
        }
    }

    /// 繋がりと面の組を整える。毎フレームの最初に呼ぶ。
    ///
    /// 受け手が居なければ ``lookUpInterval`` ごとに引きに行く。大きさや形式が変わったら
    /// HELLO を送り直し、新しい面の組を待つ。届いている通 (面・返された面) をここで読む。
    public func prepare(width: Int, height: Int, format: LinkFormat, now: Date = Date()) {
        drainReplies()
        let hello = state.withLock { state -> (mach_port_t, LinkMessage)? in
            switch state.phase {
            case .disconnected(let lastAttempt):
                if let lastAttempt, now.timeIntervalSince(lastAttempt) < Self.lookUpInterval { return nil }
                var receiver = mach_port_t(MACH_PORT_NULL)
                guard mokumesh_look_up(LinkChannel.serviceName(channel), &receiver) == KERN_SUCCESS else {
                    state.phase = .disconnected(lastAttempt: now)
                    return nil
                }
                state.counters.connections += 1
                state.phase = .waiting(receiver: receiver, width: width, height: height, format: format)
                return (receiver, helloMessage(width: width, height: height, format: format))
            case .waiting(let receiver, let w, let h, let f), .ready(let receiver, let w, let h, let f, _, _, _):
                let starving = state.starved >= Self.starvationLimit
                guard w != width || h != height || f != format || starving else { return nil }
                if starving {
                    state.starved = 0
                    state.counters.regenerations += 1
                }
                state.phase = .waiting(receiver: receiver, width: width, height: height, format: format)
                return (receiver, helloMessage(width: width, height: height, format: format))
            }
        }
        guard let (receiver, message) = hello else { return }
        var ports = LinkPorts()
        ports.names[0] = replyPort
        ports.dispositions[0] = mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND)
        if LinkTransport.send(message, to: receiver, ports: ports) != KERN_SUCCESS {
            disconnect(now: now)
        }
    }

    /// 空いている面を 1 枚借りる。無ければ `nil` (そのフレームは送らない)。
    public func acquire() -> Slot? {
        state.withLock { state -> Slot? in
            guard case .ready(let receiver, let w, let h, let f, let generation, let surfaces, var free) = state.phase
            else { return nil }
            guard let index = free.min() else {
                state.counters.framesDropped += 1
                state.starved += 1
                return nil
            }
            state.starved = 0
            free.remove(index)
            state.phase = .ready(
                receiver: receiver, width: w, height: h, format: f, generation: generation,
                surfaces: surfaces, free: free)
            return Slot(generation: generation, index: index, surface: surfaces[Int(index)])
        }
    }

    /// 借りた面に書き終えたことを受け手へ知らせる。どのスレッドから呼んでもよい。
    public func publish(_ slot: Slot, frame: Int, time: Double, handedHostTime: UInt64) {
        let receiver = state.withLock { state -> mach_port_t? in
            guard case .ready(let receiver, _, _, _, let generation, _, _) = state.phase,
                generation == slot.generation
            else { return nil }
            return receiver
        }
        guard let receiver else { return }
        var message = LinkMessage(kind: MokumeshKindFrame)
        message.generation = slot.generation
        message.slot = slot.index
        message.frame = Int64(frame)
        message.time = time
        message.handedHostTime = handedHostTime
        message.readyHostTime = HostTime.now()
        message.stream = stream
        if LinkTransport.send(message, to: receiver, timeoutMs: 10) == KERN_SUCCESS {
            state.withLock { $0.counters.framesPublished += 1 }
        } else {
            disconnect(now: Date())
        }
    }

    /// 借りた面を、送らずに戻す (書くのに失敗したとき)。どのスレッドから呼んでもよい。
    public func abandon(_ slot: Slot) {
        state.withLock { state in
            guard case .ready(let receiver, let w, let h, let f, let generation, let surfaces, var free) = state.phase,
                generation == slot.generation
            else { return }
            free.insert(slot.index)
            state.phase = .ready(
                receiver: receiver, width: w, height: h, format: f, generation: generation,
                surfaces: surfaces, free: free)
        }
    }

    /// 映像を終える。受け手には BYE を送る。
    public func close() {
        let receiver = state.withLock { state -> mach_port_t? in
            defer { state.phase = .disconnected(lastAttempt: nil) }
            switch state.phase {
            case .disconnected: return nil
            case .waiting(let receiver, _, _, _), .ready(let receiver, _, _, _, _, _, _): return receiver
            }
        }
        guard let receiver else { return }
        var message = LinkMessage(kind: MokumeshKindBye)
        message.stream = stream
        _ = LinkTransport.send(message, to: receiver, timeoutMs: 10)
        mokumesh_release_send(receiver)
    }

    // MARK: - 中

    private func helloMessage(width: Int, height: Int, format: LinkFormat) -> LinkMessage {
        var message = LinkMessage(kind: MokumeshKindHello)
        message.width = UInt32(width)
        message.height = UInt32(height)
        message.format = format.rawValue
        message.stream = stream
        return message
    }

    private func drainReplies() {
        while let (message, ports) = LinkTransport.receive(on: replyPort, timeoutMs: 0) {
            guard message.version == UInt32(MOKUMESH_PROTOCOL_VERSION) else {
                LinkTransport.releaseAll(ports)
                continue
            }
            switch message.kind {
            case MokumeshKindSurfaces:
                surfaces(message, ports: ports)
            case MokumeshKindRelease:
                LinkTransport.releaseAll(ports)
                released(message)
            default:
                LinkTransport.releaseAll(ports)
            }
        }
    }

    private func surfaces(_ message: LinkMessage, ports: [mach_port_t]) {
        let count = Int(min(message.surfaceCount, UInt32(ports.count)))
        let surfaces = ports.prefix(count).compactMap { IOSurfaceLookupFromMachPort($0) }
        LinkTransport.releaseAll(ports)
        guard surfaces.count == count, count > 0 else { return }
        state.withLock { state in
            // 待っている大きさと形式への答えだけを採る。途中でまた変わっていれば捨てる
            guard case .waiting(let receiver, let w, let h, let f) = state.phase,
                UInt32(w) == message.width, UInt32(h) == message.height, f.rawValue == message.format
            else { return }
            state.phase = .ready(
                receiver: receiver, width: w, height: h, format: f, generation: message.generation,
                surfaces: surfaces, free: Set((0..<UInt32(count))))
        }
    }

    private func released(_ message: LinkMessage) {
        state.withLock { state in
            guard case .ready(let receiver, let w, let h, let f, let generation, let surfaces, var free) = state.phase,
                generation == message.generation, Int(message.slot) < surfaces.count
            else { return }
            free.insert(message.slot)
            state.phase = .ready(
                receiver: receiver, width: w, height: h, format: f, generation: generation,
                surfaces: surfaces, free: free)
        }
    }

    private func disconnect(now: Date) {
        let receiver = state.withLock { state -> mach_port_t? in
            defer { state.phase = .disconnected(lastAttempt: now) }
            switch state.phase {
            case .disconnected: return nil
            case .waiting(let receiver, _, _, _), .ready(let receiver, _, _, _, _, _, _): return receiver
            }
        }
        if let receiver { mokumesh_release_send(receiver) }
    }
}
