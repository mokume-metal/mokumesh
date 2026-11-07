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

    public func register(into registry: PluginRegistry) {
        if let outlet { registry.add(outlet: outlet) }
    }
}
