// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import IOSurface
import MokumeshLinkC
import Testing

@testable import MokumeshLink

/// 受け渡しの約束を、GPU なしで確かめる。面への書き込みは CPU で行う。
///
/// 送り手と受け手を同じプロセスに立てる。bootstrap の名前はチャンネルごとに分けるので、
/// 検査ごとに使い捨てのチャンネルを作る。
@Suite("受け渡しの約束", .serialized)
struct LinkTests {

    // MARK: - 助け

    private static func channel() -> String { "test-\(UUID().uuidString)" }

    /// 条件が満ちるまで待つ。**待つ側が期限を持つ** — 越えたら false を返す。
    private static func waitUntil(seconds: Double = 2, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.001)
        }
        return condition()
    }

    /// 送り手が面を受け取るまで prepare を回す。
    private static func connect(_ sender: LinkSender, width: Int = 8, height: Int = 4) -> Bool {
        waitUntil {
            sender.prepare(width: width, height: height, format: .rgba8DisplayP3, now: .distantFuture)
            return sender.isReady
        }
    }

    private static func fill(_ surface: IOSurfaceRef, with value: UInt32) {
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        for row in 0..<IOSurfaceGetHeight(surface) {
            let pixels = (base + row * rowBytes).assumingMemoryBound(to: UInt32.self)
            for column in 0..<IOSurfaceGetWidth(surface) { pixels[column] = value }
        }
    }

    private static func firstPixel(_ surface: IOSurfaceRef) -> UInt32 {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        return IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self).pointee
    }

    // MARK: - メッセージ

    @Test("メッセージの中身は C の構造体を通しても変わらない")
    func message_round_trips_through_payload() {
        var message = LinkMessage(kind: MokumeshKindFrame)
        message.generation = 7
        message.slot = 2
        message.width = 1920
        message.height = 1080
        message.format = LinkFormat.rgba8DisplayP3.rawValue
        message.frame = 123_456
        message.time = 12.5
        message.handedHostTime = 111
        message.readyHostTime = 222
        message.stream = "front"

        let decoded = LinkMessage(message.payload)
        #expect(decoded.kind == MokumeshKindFrame)
        #expect(decoded.generation == 7)
        #expect(decoded.slot == 2)
        #expect(decoded.width == 1920 && decoded.height == 1080)
        #expect(decoded.frame == 123_456)
        #expect(decoded.time == 12.5)
        #expect(decoded.handedHostTime == 111 && decoded.readyHostTime == 222)
        #expect(decoded.stream == "front")
    }

    @Test("長すぎる映像の名前は、UTF-8 の文字の途中で切らずに縮める")
    func long_stream_name_is_truncated_on_character_boundary() {
        var message = LinkMessage(kind: MokumeshKindHello)
        // 3 バイトの文字を 30 個 = 90 バイト。入るのは 63 バイトまで
        message.stream = String(repeating: "面", count: 30)
        let decoded = LinkMessage(message.payload)
        #expect(decoded.stream == String(repeating: "面", count: 21))
    }

    // MARK: - 繋がる・届く

    @Test("送り手が名乗ると受け手が面を 3 枚渡し、書いた絵と番号が届く")
    func frame_arrives_with_pixels_and_number() throws {
        let channel = Self.channel()
        let receiver = try LinkReceiver(channel: channel)
        defer { receiver.close() }
        let sender = try LinkSender(channel: channel, stream: "front")
        defer { sender.close() }

        #expect(Self.connect(sender), "面が届かない")
        #expect(receiver.streams == ["front"])
        #expect(receiver.counters.surfacesMade == LinkReceiver.surfaceCount)

        let slot = try #require(sender.acquire())
        Self.fill(slot.surface, with: 0xCAFE_F00D)
        sender.publish(slot, frame: 42, time: 0.7, handedHostTime: HostTime.now())

        var frame: LinkFrame?
        #expect(Self.waitUntil { frame = receiver.latest(); return frame != nil }, "絵が届かない")
        let arrived = try #require(frame)
        #expect(arrived.frame == 42)
        #expect(arrived.time == 0.7)
        #expect(arrived.width == 8 && arrived.height == 4)
        #expect(arrived.stream == "front")
        #expect(Self.firstPixel(arrived.surface) == 0xCAFE_F00D)
        #expect(arrived.readyHostTime >= arrived.handedHostTime)
        #expect(arrived.arrivedHostTime >= arrived.readyHostTime)
        #expect(receiver.latest() == nil, "同じ 1 枚を 2 度渡した")
    }

    @Test("読み終えた面を返すと、送り手はその面をまた借りられる")
    func released_slot_becomes_free_again() throws {
        let channel = Self.channel()
        let receiver = try LinkReceiver(channel: channel)
        defer { receiver.close() }
        let sender = try LinkSender(channel: channel)
        defer { sender.close() }
        #expect(Self.connect(sender))

        // 3 枚とも借りると、4 枚目は無い (落としたフレームとして数える)
        let slots = (0..<3).compactMap { _ in sender.acquire() }
        #expect(slots.count == 3)
        #expect(sender.acquire() == nil)
        #expect(sender.counters.framesDropped == 1)

        sender.publish(slots[0], frame: 1, time: 0, handedHostTime: HostTime.now())
        var frame: LinkFrame?
        #expect(Self.waitUntil { frame = receiver.latest(); return frame != nil })
        frame?.release()

        var again: LinkSender.Slot?
        #expect(
            Self.waitUntil {
                sender.prepare(width: 8, height: 4, format: .rgba8DisplayP3)
                again = sender.acquire()
                return again != nil
            }, "返した面が空かない")
        #expect(again?.index == slots[0].index)
    }

    @Test("取られる前に次の 1 枚が届くと、古い 1 枚はその場で送り手へ返る")
    func superseded_frame_is_returned_to_sender() throws {
        let channel = Self.channel()
        let receiver = try LinkReceiver(channel: channel)
        defer { receiver.close() }
        let sender = try LinkSender(channel: channel)
        defer { sender.close() }
        #expect(Self.connect(sender))

        let first = try #require(sender.acquire())
        let second = try #require(sender.acquire())
        sender.publish(first, frame: 1, time: 0, handedHostTime: HostTime.now())
        sender.publish(second, frame: 2, time: 0, handedHostTime: HostTime.now())
        #expect(Self.waitUntil { receiver.counters.framesArrived == 2 })

        let latest = try #require(receiver.latest())
        #expect(latest.frame == 2, "最新ではない 1 枚を渡した")
        #expect(receiver.counters.framesSuperseded == 1)

        // 追い越された 1 枚は返っている: 残り 1 枚と合わせて 2 枚借りられる
        var reacquired = 0
        #expect(
            Self.waitUntil {
                sender.prepare(width: 8, height: 4, format: .rgba8DisplayP3)
                if sender.acquire() != nil { reacquired += 1 }
                return reacquired == 2
            })
        latest.release()
    }

    // MARK: - 変わる・居なくなる

    @Test("大きさが変わると面の組を作り直し、古い組への知らせは捨てる")
    func resize_makes_a_new_generation() throws {
        let channel = Self.channel()
        let receiver = try LinkReceiver(channel: channel)
        defer { receiver.close() }
        let sender = try LinkSender(channel: channel)
        defer { sender.close() }
        #expect(Self.connect(sender, width: 8, height: 4))
        let old = try #require(sender.acquire())

        #expect(Self.connect(sender, width: 16, height: 8))
        #expect(receiver.counters.surfacesMade == LinkReceiver.surfaceCount * 2)
        let new = try #require(sender.acquire())
        #expect(new.generation != old.generation)
        #expect(IOSurfaceGetWidth(new.surface) == 16)

        // 古い組の面への知らせは、送り手がもう送らない
        sender.publish(old, frame: 1, time: 0, handedHostTime: HostTime.now())
        sender.publish(new, frame: 2, time: 0, handedHostTime: HostTime.now())
        var frame: LinkFrame?
        #expect(Self.waitUntil { frame = receiver.latest(); return frame != nil })
        #expect(frame?.frame == 2)
        #expect(frame?.width == 16)
    }

    @Test("受け手が居なければ、送り手は何も送らずに待ち、現れたら繋がる")
    func sender_waits_for_receiver() throws {
        let channel = Self.channel()
        let sender = try LinkSender(channel: channel)
        defer { sender.close() }

        sender.prepare(width: 8, height: 4, format: .rgba8DisplayP3)
        #expect(!sender.isReady)
        #expect(sender.acquire() == nil)
        #expect(sender.counters.connections == 0)

        let receiver = try LinkReceiver(channel: channel)
        defer { receiver.close() }
        #expect(Self.connect(sender), "受け手が現れても繋がらない")
        #expect(sender.counters.connections == 1)
    }

    @Test("受け手が入れ替わると、送り手は繋ぎ直す")
    func sender_reconnects_after_receiver_restarts() throws {
        let channel = Self.channel()
        let sender = try LinkSender(channel: channel)
        defer { sender.close() }

        let first = try LinkReceiver(channel: channel)
        #expect(Self.connect(sender))
        first.close()

        let second = try LinkReceiver(channel: channel)
        defer { second.close() }
        // 送れなかったことで居なくなったと知り、引き直す
        let slot = try #require(sender.acquire())
        sender.publish(slot, frame: 1, time: 0, handedHostTime: HostTime.now())
        #expect(!sender.isReady)
        #expect(Self.connect(sender), "新しい受け手へ繋がらない")
        #expect(sender.counters.connections == 2)

        let next = try #require(sender.acquire())
        sender.publish(next, frame: 2, time: 0, handedHostTime: HostTime.now())
        var frame: LinkFrame?
        #expect(Self.waitUntil { frame = second.latest(); return frame != nil })
        #expect(frame?.frame == 2)
    }

    @Test("同じチャンネルに 2 つ目の受け手は立てられない")
    func second_receiver_on_same_channel_fails() throws {
        let channel = Self.channel()
        let receiver = try LinkReceiver(channel: channel)
        defer { receiver.close() }
        #expect(throws: LinkError.self) { try LinkReceiver(channel: channel) }
    }

    @Test("送り手が BYE を送らずに居なくなっても、受け手は映像を畳む")
    func lost_sender_removes_stream() throws {
        let channel = Self.channel()
        let receiver = try LinkReceiver(channel: channel)
        defer { receiver.close() }
        let sender = try LinkSender(channel: channel, stream: "front")
        #expect(Self.connect(sender))
        #expect(receiver.streams == ["front"])
        sender.destroyWithoutGoodbye()
        #expect(Self.waitUntil { receiver.streams.isEmpty }, "落ちた送り手の映像が残っている")
        #expect(receiver.counters.sendersLost == 1)
    }

    @Test("送り手が BYE を送ると、受け手の映像の一覧から消える")
    func bye_removes_stream() throws {
        let channel = Self.channel()
        let receiver = try LinkReceiver(channel: channel)
        defer { receiver.close() }
        let sender = try LinkSender(channel: channel, stream: "front")
        #expect(Self.connect(sender))
        #expect(receiver.streams == ["front"])
        sender.close()
        #expect(Self.waitUntil { receiver.streams.isEmpty })
    }
}
