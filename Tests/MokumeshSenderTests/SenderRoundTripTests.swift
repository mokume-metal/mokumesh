// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import IOSurface
import MokumeshLink
import Testing
import mokume

@testable import MokumeshSender

/// 送り手の部品が、mokume の出口の絵をそのまま受け手へ渡すことを見る。
///
/// 受け手のアプリを立ち上げずに済ませるため、同じプロセスの中に受け手を立てる。
@Suite(
    "mokume からの送り出し",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .serialized
)
struct SenderRoundTripTests {

    /// 一面を 1 色で塗り、円を 1 つ描くスケッチ。**受けた絵と突き合わせる相手**になる。
    final class FlatSketch: Sketch {
        var settings: SketchSettings {
            SketchSettings(width: 64, height: 48, title: "mokumesh round trip")
        }
        var plugins: [any Plugin] { Self.declared }
        nonisolated(unsafe) static var declared: [any Plugin] = []

        func draw() {
            background(.display(red: 0.2, green: 0.6, blue: 0.9))
            fill(.display(red: 1, green: 0.3, blue: 0.1))
            circle(width / 2, height / 2, 20)
        }
    }

    /// 受け手に 1 枚届くまでフレームを進める。**回数ではなく、届いたことで待つ**
    /// (出口へ絵が渡るのは描いてから 1〜2 フレーム後で、その数は mokume の都合で動く)。
    private func advanceUntilArrived(
        _ runtime: SketchRuntime, _ receiver: LinkReceiver, upTo limit: Int = 120
    ) throws -> LinkFrame? {
        for _ in 0..<limit {
            try runtime.advance()
            // 送り手は blit の完了の知らせで送る。GPU が終わるのを少し待つ
            let deadline = Date().addingTimeInterval(0.05)
            while Date() < deadline {
                if let frame = receiver.latest() { return frame }
                Thread.sleep(forTimeInterval: 0.001)
            }
        }
        return nil
    }

    private func bytes(of surface: IOSurfaceRef) -> [UInt8] {
        IOSurfaceLock(surface, .readOnly, nil)
        defer { IOSurfaceUnlock(surface, .readOnly, nil) }
        let width = IOSurfaceGetWidth(surface)
        let height = IOSurfaceGetHeight(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let base = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt8.self)
        var result: [UInt8] = []
        result.reserveCapacity(width * height * 4)
        for row in 0..<height {
            result.append(contentsOf: UnsafeBufferPointer(start: base + row * rowBytes, count: width * 4))
        }
        return result
    }

    @Test("受け手に届いた絵が、組み込みの出口が出す絵と一致する")
    func received_frame_matches_builtin_outlet() throws {
        let channel = "test-\(UUID().uuidString)"
        let receiver = try LinkReceiver(channel: channel)
        defer { receiver.close() }
        FlatSketch.declared = [MokumeshPlugin(sending: "main", channel: channel)]
        defer { FlatSketch.declared = [] }

        let runtime = try SketchRuntime(sketch: FlatSketch(), gpu: try RenderDevice())
        defer { runtime.closePlugins() }

        let frame = try #require(try advanceUntilArrived(runtime, receiver), "120 フレーム進めても届かない")
        defer { frame.release() }
        let expected = try runtime.target.encodeForDisplay()

        #expect(frame.width == expected.width)
        #expect(frame.height == expected.height)
        #expect(frame.format == .rgba8DisplayP3)
        let arrived = bytes(of: frame.surface)
        let differing = zip(arrived, expected.bytes).filter { $0 != $1 }.count
        // バイト列そのものを #expect に渡さない (食い違うと数万個の数字が流れる)
        #expect(
            arrived.count == expected.bytes.count && differing == 0,
            "受けた絵が組み込みの出口の絵と違う: \(differing) バイトが不一致")
    }

    @Test("長く回しても、発行口と面の texture を作り直さず、番号が順に進む")
    func long_run_reuses_resources() throws {
        let channel = "test-\(UUID().uuidString)"
        let receiver = try LinkReceiver(channel: channel)
        defer { receiver.close() }
        let plugin = MokumeshPlugin(sending: "main", channel: channel)
        FlatSketch.declared = [plugin]
        defer { FlatSketch.declared = [] }

        let runtime = try SketchRuntime(sketch: FlatSketch(), gpu: try RenderDevice())
        defer { runtime.closePlugins() }

        var numbers: [Int] = []
        for _ in 0..<300 {
            try runtime.advance()
            if let frame = receiver.latest() {
                numbers.append(frame.frame)
                frame.release()
            }
        }
        // 最後の知らせを待つ
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline, receiver.counters.framesArrived < 250 {
            Thread.sleep(forTimeInterval: 0.005)
        }

        let outlet = try #require(plugin.outlet)
        #expect(outlet.queuesMade == 1, "フレームごとに発行口を作り直している")
        #expect(outlet.texturesMade == LinkReceiver.surfaceCount, "面を包み直している")
        #expect(outlet.failure == nil, "転んだ: \(outlet.failure ?? "")")
        #expect(numbers == numbers.sorted(), "番号が逆に進んだ")
        #expect(Set(numbers).count == numbers.count, "同じ番号を 2 度受けた")
        #expect(numbers.count > 200, "300 フレームのうち \(numbers.count) 枚しか受けていない")
    }
}
