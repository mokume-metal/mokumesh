// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshLink
import mokume

/// 描いた絵を mokumesh へ渡す束。
///
/// ```swift
/// import mokume
/// import MokumeshSender
///
/// @main
/// final class MySketch: Sketch {
///     let mokumesh = MokumeshPlugin(sending: "main")
///     var plugins: [any Plugin] { [mokumesh] }
///
///     func draw() {
///         background(.display(red: 0.06, green: 0.07, blue: 0.09))
///         circle(width / 2, height / 2, 200)
///     }
/// }
/// ```
///
/// mokumesh が起きていなくてもスケッチは止まらない。受け手が現れたら、そこから渡し始める。
///
/// ## 渡す絵
///
/// mokume の出口が受け取る 1 枚 (`OutputFrame.texture`) をそのまま渡す。形式は
/// 8 bit の RGBA (Display P3・sRGB の曲線・straight alpha) で、mokumesh の
/// ``LinkFormat/rgba8DisplayP3`` に当たる。
public struct MokumeshPlugin: Plugin {
    /// 映像の名前。mokumesh はこの名前で映像を区別する。
    public let stream: String
    /// 受け手のチャンネル。同じ Mac で受け手を複数動かすときに分ける。
    public let channel: String

    /// 実際に渡す出口。**束を作った時点で作る** — 束の写しが増えても出口は 1 つにする。
    let outlet: MokumeshOutlet?

    /// - Parameters:
    ///   - stream: 映像の名前。
    ///   - channel: 受け手のチャンネル。
    public init(sending stream: String = "main", channel: String = LinkChannel.defaultName) {
        self.stream = stream
        self.channel = channel
        outlet = try? MokumeshOutlet(channel: channel, stream: stream)
    }

    /// 送り出しの統計。
    public struct Statistics: Sendable, Equatable {
        /// 受け手へ届けた枚数。
        public var framesPublished: Int
        /// 空いている面が無く、送れなかった枚数 (受け手が読み終えていない)。
        public var framesDropped: Int
        /// 受け手の面へ写す GPU の時間の合計 (秒) と、その回数。
        public var gpuSeconds: Double
        public var gpuSamples: Int
        /// 面が空かないまま続き、受け手に面の組を作り直してもらった回数。
        public var regenerations: Int
    }

    /// いままでの送り出しの統計。受け手が居ない間は数えない。
    public var statistics: Statistics {
        guard let outlet else { return Statistics(framesPublished: 0, framesDropped: 0, gpuSeconds: 0, gpuSamples: 0, regenerations: 0) }
        let counters = outlet.link.counters
        let gpu = outlet.statistics.gpu
        return Statistics(
            framesPublished: counters.framesPublished, framesDropped: counters.framesDropped,
            gpuSeconds: gpu.seconds, gpuSamples: gpu.samples, regenerations: counters.regenerations)
    }

    public func register(into registry: PluginRegistry) {
        if let outlet { registry.add(outlet: outlet) }
    }
}
