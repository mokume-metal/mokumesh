// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import IOSurface
import MokumeshLinkC

/// 送り手から届いた 1 枚。**読み終えたら ``release()`` を呼ぶ。**
///
/// 呼ぶまで、送り手はこの面に次の絵を書かない。呼ばずに捨てても `deinit` で返すが、
/// GPU で読んでいる途中に返すと、送り手が次の絵で上書きしうる。GPU で読むなら、
/// その投入が終わってから返す。
public final class LinkFrame: Sendable {
    /// 映像の名前。
    public let stream: String
    /// 絵が載っている面。大きさは ``width`` × ``height``。
    // IOSurface はスレッドをまたいで渡してよい (中身の読み書きは受け渡しの約束が順序を決める)
    nonisolated(unsafe) public let surface: IOSurfaceRef
    public let width: Int
    public let height: Int
    public let format: LinkFormat
    /// 送り手のフレーム番号。
    public let frame: Int
    /// 送り手の時刻 (秒)。
    public let time: Double
    /// 送り手が絵を受け取った瞬間の host time。
    public let handedHostTime: UInt64
    /// 送り手の面への書き込みが終わった瞬間の host time。
    public let readyHostTime: UInt64
    /// 受け手がこの通を受けた瞬間の host time。
    public let arrivedHostTime: UInt64

    private let returnSlot: Locked<(@Sendable () -> Void)?>

    init(
        stream: String, surface: IOSurfaceRef, width: Int, height: Int, format: LinkFormat,
        message: LinkMessage, arrivedHostTime: UInt64, returnSlot: @escaping @Sendable () -> Void
    ) {
        self.stream = stream
        self.surface = surface
        self.width = width
        self.height = height
        self.format = format
        self.frame = Int(message.frame)
        self.time = message.time
        self.handedHostTime = message.handedHostTime
        self.readyHostTime = message.readyHostTime
        self.arrivedHostTime = arrivedHostTime
        self.returnSlot = Locked(returnSlot)
    }

    /// 読み終えた面を送り手へ返す。2 度目以降は何もしない。
    public func release() {
        let action = returnSlot.withLock { slot -> (@Sendable () -> Void)? in
            defer { slot = nil }
            return slot
        }
        action?()
    }

    deinit { release() }
}

/// 受け手。チャンネルの名前を bootstrap に登録し、送り手からの絵を待つ。
///
/// 面は受け手が用意する (ADR-0001 決定 3 の改訂)。送り手が HELLO で大きさと形式を
/// 名乗るたびに、面を 3 枚作り直して渡す。届いた通は専用のスレッドで受け、
/// 最新の 1 枚だけを ``latest(stream:)`` が渡す。取られないまま次の 1 枚に追い越された
/// 面は、その場で送り手へ返す。
public final class LinkReceiver: Sendable {
    /// 面の枚数。書いている 1 枚・届いて待っている 1 枚・映している 1 枚。
    public static let surfaceCount = 3

    /// 数えたもの。検査と計測のためにある。
    public struct Counters: Sendable, Equatable {
        /// 届いた FRAME の数。
        public var framesArrived = 0
        /// 取られる前に次の 1 枚に追い越された数。
        public var framesSuperseded = 0
        /// 面を作った回数 (HELLO を受けて面の組を作るたびに 3 増える)。
        public var surfacesMade = 0
        /// 捨てた通の数 (版や形が違う・古い世代)。
        public var messagesDropped = 0
        /// BYE を送らずに居なくなった送り手の数。
        public var sendersLost = 0
    }

    public let channel: String

    private struct Session {
        var senderPort: mach_port_t
        var generation: UInt32
        var width: Int
        var height: Int
        var format: LinkFormat
        var surfaces: [IOSurfaceRef]
        /// 届いてまだ取られていない 1 枚 (slot と通)。
        var pending: (slot: UInt32, message: LinkMessage, arrived: UInt64)?
    }

    private struct State {
        var sessions: [String: Session] = [:]
        var nextGeneration: UInt32 = 1
        var counters = Counters()
        var closed = false
    }

    private let port: mach_port_t
    private let state = Locked(State())

    /// チャンネルの名前を登録して受け始める。
    ///
    /// - Throws: 同じチャンネルの受け手が既に居ると ``LinkError/checkInFailed(channel:code:)``。
    public init(channel: String = LinkChannel.defaultName) throws(LinkError) {
        self.channel = channel
        var receive = mach_port_t(MACH_PORT_NULL)
        let result = mokumesh_check_in(LinkChannel.serviceName(channel), &receive)
        guard result == KERN_SUCCESS else {
            throw .checkInFailed(channel: channel, code: result)
        }
        port = receive
        let thread = Thread { [self] in self.run() }
        thread.name = "mokumesh.link.receive"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// 受けるのをやめる。名前の登録も外れ、送り手は次の送りで受け手が居ないことを知る。
    public func close() {
        let sessions = state.withLock { state -> [Session] in
            guard !state.closed else { return [] }
            state.closed = true
            defer { state.sessions = [:] }
            return Array(state.sessions.values)
        }
        for session in sessions { mokumesh_release_send(session.senderPort) }
        // 受け口を壊すと、待っているスレッドの mach_msg がエラーで戻って抜ける
        mokumesh_destroy_receive(port)
    }

    deinit { close() }

    /// いま繋がっている映像の名前。
    public var streams: [String] {
        state.withLock { Array($0.sessions.keys).sorted() }
    }

    public var counters: Counters { state.withLock { $0.counters } }

    /// まだ取っていない最新の 1 枚を取る。新しい 1 枚が無ければ `nil`。
    ///
    /// `stream` を省くと、名前の順で最初の映像から取る。
    public func latest(stream: String? = nil) -> LinkFrame? {
        state.withLock { state -> LinkFrame? in
            let key = stream ?? state.sessions.keys.sorted().first
            guard let key, var session = state.sessions[key], let pending = session.pending else {
                return nil
            }
            session.pending = nil
            state.sessions[key] = session
            let generation = session.generation
            let slot = pending.slot
            return LinkFrame(
                stream: key, surface: session.surfaces[Int(slot)], width: session.width,
                height: session.height, format: session.format, message: pending.message,
                arrivedHostTime: pending.arrived
            ) { [weak self] in
                self?.returnSlot(stream: key, generation: generation, slot: slot)
            }
        }
    }

    // MARK: - 受けるスレッド

    private func run() {
        while true {
            guard let (message, ports) = LinkTransport.receive(on: port, timeoutMs: nil)
            else {
                // 受け口が壊された (close) か、形の違う通を捨てた
                if state.withLock({ $0.closed }) { return }
                state.withLock { $0.counters.messagesDropped += 1 }
                continue
            }
            handle(message, ports: ports)
        }
    }

    private func handle(_ message: LinkMessage, ports: [mach_port_t]) {
        guard message.version == UInt32(MOKUMESH_PROTOCOL_VERSION) else {
            LinkTransport.releaseAll(ports)
            state.withLock { $0.counters.messagesDropped += 1 }
            return
        }
        switch message.kind {
        case MokumeshKindHello:
            hello(message, senderPort: ports[0])
            LinkTransport.releaseAll(Array(ports.dropFirst()))
        case MokumeshKindFrame:
            LinkTransport.releaseAll(ports)
            frame(message)
        case MokumeshKindSenderGone:
            let gone = state.withLock { state -> [Session] in
                let keys = state.sessions.filter { $0.value.senderPort == ports[0] }.map(\.key)
                return keys.compactMap { state.sessions.removeValue(forKey: $0) }
            }
            for session in gone { mokumesh_release_send(session.senderPort) }
            // 知らせが持ってきた参照
            mokumesh_release_send(ports[0])
            state.withLock { $0.counters.sendersLost += 1 }
        case MokumeshKindBye:
            LinkTransport.releaseAll(ports)
            let gone = state.withLock { $0.sessions.removeValue(forKey: message.stream) }
            if let gone { mokumesh_release_send(gone.senderPort) }
        default:
            LinkTransport.releaseAll(ports)
            state.withLock { $0.counters.messagesDropped += 1 }
        }
    }

    private func hello(_ message: LinkMessage, senderPort: mach_port_t) {
        guard senderPort != MACH_PORT_NULL, let format = LinkFormat(rawValue: message.format),
            message.width > 0, message.height > 0
        else {
            mokumesh_release_send(senderPort)
            state.withLock { $0.counters.messagesDropped += 1 }
            return
        }
        let width = Int(message.width)
        let height = Int(message.height)
        let surfaces = (0..<Self.surfaceCount).compactMap { _ in
            makeSurface(width: width, height: height, format: format)
        }
        guard surfaces.count == Self.surfaceCount else {
            mokumesh_release_send(senderPort)
            return
        }
        let (generation, replaced) = state.withLock { state -> (UInt32, Session?) in
            let generation = state.nextGeneration
            state.nextGeneration &+= 1
            state.counters.surfacesMade += surfaces.count
            let replaced = state.sessions.updateValue(
                Session(
                    senderPort: senderPort, generation: generation, width: width, height: height,
                    format: format, surfaces: surfaces, pending: nil),
                forKey: message.stream)
            return (generation, replaced)
        }
        // 同じ送り手の HELLO でも、通ごとに送り手の受け口への参照が 1 つ増えている。
        // 前の session が持っていた分を手放す
        if let replaced { mokumesh_release_send(replaced.senderPort) }
        // BYE を送らずに落ちた送り手を知るため
        _ = mokumesh_request_dead_name(senderPort, port)

        var reply = LinkMessage(kind: MokumeshKindSurfaces)
        reply.generation = generation
        reply.width = message.width
        reply.height = message.height
        reply.format = message.format
        reply.surfaceCount = UInt32(surfaces.count)
        reply.stream = message.stream
        var ports = LinkPorts()
        for (index, surface) in surfaces.enumerated() {
            ports.names[index] = IOSurfaceCreateMachPort(surface)
            ports.dispositions[index] = mach_msg_type_name_t(MACH_MSG_TYPE_MOVE_SEND)
        }
        if LinkTransport.send(reply, to: senderPort, ports: ports) != KERN_SUCCESS {
            dropSession(message.stream, generation: generation)
        }
    }

    private func frame(_ message: LinkMessage) {
        let arrived = HostTime.now()
        let superseded = state.withLock { state -> (port: mach_port_t, slot: UInt32)? in
            guard var session = state.sessions[message.stream],
                session.generation == message.generation,
                Int(message.slot) < session.surfaces.count
            else {
                state.counters.messagesDropped += 1
                return nil
            }
            state.counters.framesArrived += 1
            let previous = session.pending
            session.pending = (message.slot, message, arrived)
            state.sessions[message.stream] = session
            guard let previous else { return nil }
            state.counters.framesSuperseded += 1
            return (session.senderPort, previous.slot)
        }
        if let superseded {
            Self.sendRelease(to: superseded.port, generation: message.generation, slot: superseded.slot)
        }
    }

    private func dropSession(_ stream: String, generation: UInt32) {
        let gone = state.withLock { state -> Session? in
            guard state.sessions[stream]?.generation == generation else { return nil }
            return state.sessions.removeValue(forKey: stream)
        }
        if let gone { mokumesh_release_send(gone.senderPort) }
    }

    /// 取られた 1 枚を送り手へ返す。その間に送り手が入れ替わっていれば返さない
    /// (古い世代の面は、送り手がもう持っていない)。
    private func returnSlot(stream: String, generation: UInt32, slot: UInt32) {
        let port = state.withLock { state -> mach_port_t? in
            guard let session = state.sessions[stream], session.generation == generation else {
                return nil
            }
            return session.senderPort
        }
        if let port { Self.sendRelease(to: port, generation: generation, slot: slot) }
    }

    private static func sendRelease(to port: mach_port_t, generation: UInt32, slot: UInt32) {
        var message = LinkMessage(kind: MokumeshKindRelease)
        message.generation = generation
        message.slot = slot
        // 送り手が居なくなっていれば失敗するだけ。session は次の HELLO か BYE で片付く
        _ = LinkTransport.send(message, to: port, timeoutMs: 10)
    }
}
