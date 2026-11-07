// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeshLink

// 受け手の確かめ。`swift run ReceiveProbe [秒数]` で受け手を立て、届いた枚数・欠けた番号・
// 送り手が受け取ってから届くまでの時間を 1 秒ごとに出す。窓は出さない。
//
// 別のプロセスの送り手 (`swift run SendExample`) と組み合わせ、プロセスをまたいで
// 番号が欠けずに進むことを見るためにある。

let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) ?? 10
let receiver: LinkReceiver
do {
    receiver = try LinkReceiver()
} catch {
    print("受け手を立てられなかった: \(error)")
    exit(1)
}
print("チャンネル \(receiver.channel) で待っています (\(Int(seconds)) 秒)")

var lastFrame: Int?
var received = 0
var skipped = 0
var latencies: [Double] = []
let deadline = Date().addingTimeInterval(seconds)
var nextReport = Date().addingTimeInterval(1)

while Date() < deadline {
    if let frame = receiver.latest() {
        if let lastFrame, frame.frame > lastFrame + 1 { skipped += frame.frame - lastFrame - 1 }
        lastFrame = frame.frame
        received += 1
        latencies.append(HostTime.interval(from: frame.handedHostTime, to: frame.arrivedHostTime))
        frame.release()
    }
    if Date() >= nextReport {
        let sorted = latencies.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2] * 1000
        print(
            String(
                format: "%@ 受けた %d 枚・取りこぼし %d 枚・最新 #%d・受け取りから到着まで中央値 %.2f ms",
                receiver.streams.joined(separator: ","), received, skipped, lastFrame ?? -1, median))
        nextReport = nextReport.addingTimeInterval(1)
    }
    Thread.sleep(forTimeInterval: 0.001)
}
let counters = receiver.counters
print("到着 \(counters.framesArrived)・追い越し \(counters.framesSuperseded)・面 \(counters.surfacesMade)・捨てた通 \(counters.messagesDropped)")
receiver.close()
