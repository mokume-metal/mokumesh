// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshSender
import mokume

/// mokumesh へ絵を渡す例。`swift run SendExample` で窓を開き、同時に mokumesh へ渡す。
///
/// 横向きのグラデーション (段差が見えやすい) と、毎フレーム右へ進む縦の帯を描く。
/// 帯の位置でフレームが欠けたかどうかが目で分かる。
@main
final class SendExample: Sketch {
    let mokumesh = MokumeshPlugin(sending: "main")
    var plugins: [any Plugin] { [mokumesh] }

    var settings: SketchSettings {
        SketchSettings(width: 1280, height: 720, title: "mokumesh send example")
    }

    func draw() {
        background(.display(red: 0, green: 0, blue: 0))
        noStroke()
        let steps = 64
        let band = width / Float(steps)
        for index in 0..<steps {
            let level = Float(index) / Float(steps - 1)
            let red: Float = level
            let green: Float = level * 0.8
            let blue: Float = 1 - level
            fill(.display(red: red, green: green, blue: blue))
            rect(Float(index) * band, 0, band + 1, height * 0.75)
        }
        fill(.display(red: 1, green: 1, blue: 1))
        let x = Float(frameCount % 120) / 120 * width
        rect(x, height * 0.75, width / 120, height * 0.25)
    }
}
