// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeshLink

/// 遅れの計測 (`--measure <枚数>`)。
///
/// 送り手 (`LatencyBench`) が絵の上端に描いた host time (`TimeCode`) と、その 1 枚が
/// 初めて提示された時刻の差を、来た道 (専用の受け渡し・Syphon) ごとに数える。
/// 両方の道で枚数が揃ったら、中央値と 99 パーセンタイルを出して終わる。
final class Measurement: @unchecked Sendable {
    let target: Int
    private let lock = NSLock()
    private var samples: [SourceFrame.Origin: [Double]] = [.link: [], .syphon: []]
    /// 描いてから受け手に届くまで。提示の刻みに丸められる前の、道そのものの差が出る。
    private var arrivals: [SourceFrame.Origin: [Double]] = [.link: [], .syphon: []]
    /// 数えた 1 枚。来た道と届いた時刻で見分ける — `ObjectIdentifier` は、手放した 1 枚の
    /// 番地が次の 1 枚に使い回されるので使えない。
    private var counted = Set<String>()
    private var finished = false
    private var lastProgress = Date()
    /// 符号を読めなかった・範囲の外だった枚数。
    private var rejected = 0
    private let onFinish: @Sendable (String) -> Void

    init(target: Int, onFinish: @escaping @Sendable (String) -> Void) {
        self.target = target
        self.onFinish = onFinish
    }

    /// 提示の知らせ。同じ 1 枚が何度提示されても、初めの 1 回だけを数える。
    func presented(at presentedTime: Double, frames: [SourceFrame]) {
        guard presentedTime > 0 else { return }  // 提示されずに捨てられた drawable
        var report: String?
        lock.lock()
        for frame in frames {
            guard counted.insert("\(frame.origin)-\(frame.arrivedHostTime)").inserted else { continue }
            guard let drawn = frame.drawnHostTime else {
                rejected += 1
                continue
            }
            let latency = presentedTime - HostTime.seconds(drawn)
            // 符号を読み違えた 1 枚 (送り手が別の絵を出していた等) は捨てる
            guard latency > 0, latency < 1 else {
                rejected += 1
                continue
            }
            samples[frame.origin, default: []].append(latency)
            arrivals[frame.origin, default: []].append(HostTime.interval(from: drawn, to: frame.arrivedHostTime))
        }
        if Date().timeIntervalSince(lastProgress) > 2 {
            lastProgress = Date()
            print("計測中: 専用 \(samples[.link]?.count ?? 0) 枚・Syphon \(samples[.syphon]?.count ?? 0) 枚・読めなかった \(rejected) 枚")
        }
        if !finished, samples.values.allSatisfy({ $0.count >= target }) {
            finished = true
            report = Self.report(samples, arrivals)
        }
        lock.unlock()
        if let report { onFinish(report) }
    }

    private static func report(
        _ samples: [SourceFrame.Origin: [Double]], _ arrivals: [SourceFrame.Origin: [Double]]
    ) -> String {
        func line(_ name: String, _ values: [Double]) -> String {
            let sorted = values.sorted()
            let median = sorted[sorted.count / 2] * 1000
            let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))] * 1000
            return String(format: "%@: %d 枚・中央値 %.2f ms・99 パーセンタイル %.2f ms", name, sorted.count, median, p99)
        }
        return [
            "描いてから提示されるまで:",
            line("専用の受け渡し", samples[.link] ?? []),
            line("Syphon", samples[.syphon] ?? []),
            "描いてから受け手に届くまで:",
            line("専用の受け渡し", arrivals[.link] ?? []),
            line("Syphon", arrivals[.syphon] ?? []),
        ].joined(separator: "\n")
    }
}
