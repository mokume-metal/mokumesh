// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal
import MokumeshLink
import MokumeshSender
import Syphon
import mokume

// 専用の受け渡しと Syphon を、同じ絵・同じ物差しで並べて測るための送り手。
//
//   swift run --package-path App LatencyBench [秒数]
//
// 1920×1080 の絵を、窓を出さずに 60fps で描き、同じ 1 枚を 2 つの道へ同時に送る:
//   - 専用の受け渡し (映像の名前 "bench")
//   - Syphon (サーバーの名前 "LatencyBench")
// 絵の上端には、draw() を呼んだ瞬間の host time を 64 個のマスで描く (TimeCode)。
// 受け手 (mokumesh --measure) はそれを読み、提示の時刻との差を道ごとに数える。
// 終わると、送り手の側の GPU の時間 (受け手の面へ写す / Syphon の面へ写す) を出す。

/// Syphon へ送る出口。mokume-syphon と同じ道 (publishFrameTexture) を、GPU の時間を測れるよう
/// 自分の command buffer で通す。
final class SyphonBenchOutlet: Outlet {
    private var server: SyphonMetalServer?
    private var queue: (any MTLCommandQueue)?
    private let lock = NSLock()
    nonisolated(unsafe) private var gpuSeconds: Double = 0
    nonisolated(unsafe) private var gpuSamples = 0

    func open() throws {}

    func receive(_ frame: OutputFrame) {
        autoreleasepool {
            let texture = frame.texture
            if server == nil {
                server = SyphonMetalServer(name: "LatencyBench", device: texture.device, options: nil)
                queue = texture.device.makeCommandQueue()
            }
            guard let server, let commands = queue?.makeCommandBuffer() else { return }
            server.publishFrameTexture(
                texture, on: commands,
                imageRegion: NSRect(x: 0, y: 0, width: texture.width, height: texture.height), flipped: false)
            commands.addCompletedHandler { [self] buffer in
                lock.lock()
                gpuSeconds += buffer.gpuEndTime - buffer.gpuStartTime
                gpuSamples += 1
                lock.unlock()
            }
            commands.commit()
        }
    }

    func close() {
        server?.stop()
        server = nil
    }

    var gpu: (seconds: Double, samples: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (gpuSeconds, gpuSamples)
    }
}

struct SyphonBenchPlugin: Plugin {
    let outlet = SyphonBenchOutlet()
    func register(into registry: PluginRegistry) { registry.add(outlet: outlet) }
}

final class BenchSketch: Sketch {
    nonisolated(unsafe) static var declared: [any Plugin] = []
    var plugins: [any Plugin] { Self.declared }
    var settings: SketchSettings { SketchSettings(width: 1920, height: 1080, title: "latency bench") }

    func draw() {
        let drawn = HostTime.now()
        background(.display(red: 0.1, green: 0.1, blue: 0.12))
        noStroke()
        // 動いていることが目で分かるもの
        fill(.display(red: 0.9, green: 0.5, blue: 0.2))
        let x = Float(frameCount % 240) / 240 * width
        circle(x, height / 2, 200)
        // 上端の時刻の符号
        for bit in 0..<TimeCode.bits {
            let on = (drawn >> UInt64(bit)) & 1 == 1
            fill(on ? .display(red: 1, green: 1, blue: 1) : .display(red: 0, green: 0, blue: 0))
            rect(Float(bit * TimeCode.cellWidth), 0, Float(TimeCode.cellWidth), Float(TimeCode.cellHeight))
        }
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 30
let mokumesh = MokumeshPlugin(sending: "bench")
let syphon = SyphonBenchPlugin()
BenchSketch.declared = [mokumesh, syphon]

let runtime: SketchRuntime
do {
    runtime = try SketchRuntime(sketch: BenchSketch(), gpu: try RenderDevice())
} catch {
    print("スケッチを起こせなかった: \(error)")
    exit(1)
}
print("1920×1080・60fps で \(Int(seconds)) 秒送ります (専用: bench / Syphon: LatencyBench)")
let interval = 1.0 / 60
var next = Date()
let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline {
    do { try runtime.advance() } catch { print("描けなかった: \(error)") }
    next = next.addingTimeInterval(interval)
    // Syphon の公示は run loop で配られるので、待つ間も回す
    RunLoop.current.run(until: next)
}
runtime.closePlugins()

let link = mokumesh.statistics
let syphonGPU = syphon.outlet.gpu
func perFrame(_ seconds: Double, _ samples: Int) -> String {
    samples == 0 ? "-" : String(format: "%.3f ms", seconds / Double(samples) * 1000)
}
print("送り手の GPU の時間 (1 枚あたり): 専用 \(perFrame(link.gpuSeconds, link.gpuSamples)) / Syphon \(perFrame(syphonGPU.seconds, syphonGPU.samples))")
print("専用: 届けた \(link.framesPublished) 枚・面が空かず送れなかった \(link.framesDropped) 枚・面の組を作り直した \(link.regenerations) 回")
