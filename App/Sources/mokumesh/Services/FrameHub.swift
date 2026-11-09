// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeshLink
import MokumeshEditor
import QuartzCore

/// 届いた絵を 1 か所で取り込む (ADR-0003 決定 6)。
///
/// 描く場所 (出力の窓・各ペイン) はそれぞれ表示に合わせて起きるが、取り込むのは表示の
/// 更新ごとに高々 1 回で、どの描く場所も同じ最新の 1 枚を描く。欲しい映像は `wanted` が
/// 1 か所で決める — 描く場所ごとに違う集合で取り込むと、Syphon は欲しい映像から外れた
/// 送り手を切るので、毎回繋ぎ直すことになる。
///
/// 映像の一覧は 1 秒ごとに比べ、変わったときだけ `onStreamsChanged` で知らせる
/// (毎フレーム知らせると、操作窓が毎フレーム描き直される)。
@MainActor
final class FrameHub {
    let renderer: Renderer?
    private lazy var syphon: SyphonSources? = renderer.map { SyphonSources(device: $0.device) }
    private(set) var receiver: LinkReceiver?
    /// 受け手を起こせなかったときの訳。
    private(set) var receiverError: String?

    /// 映像の名前ごとの、いま映している 1 枚。
    private(set) var frames: [String: SourceFrame] = [:]
    /// 取り込む映像。
    var wanted: () -> Set<String> = { [] }
    /// 計測のとき、届いた 1 枚の上端から描いた時刻を読む。
    var isMeasuring = false
    /// 映像の一覧が変わった。
    var onStreamsChanged: ([String]) -> Void = { _ in }
    /// 映像の絵の大きさが変わった (初めて届いた・送り手が大きさを変えた・届かなくなった)。
    var onSizeChanged: (String, PixelSize?) -> Void = { _, _ in }
    private var sizes: [String: PixelSize] = [:]

    /// 最後に取り込んだ表示の時刻。同じ更新の中で 2 度は取り込まない。
    private var lastPull: CFTimeInterval = -.infinity
    private var lastStreams: [String] = []
    private var streamTimer: Timer?

    init(renderer: Renderer?) {
        self.renderer = renderer
    }

    // MARK: - 受け手

    /// チャンネルで受け始める (既に受けていれば閉じて受け直す)。
    func startReceiver(channel: String) {
        receiver?.close()
        do {
            receiver = try LinkReceiver(channel: channel)
            receiverError = nil
        } catch {
            receiver = nil
            receiverError = "チャンネル \(channel) で受けられない (同じチャンネルの受け手が既に起きている?)"
        }
        publishStreams()
    }

    /// 映像の一覧を 1 秒ごとに見る。
    func watchStreams() {
        streamTimer?.invalidate()
        streamTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publishStreams() }
        }
        publishStreams()
    }

    /// 映せる映像。専用の受け渡しの映像と、Syphon の送り手 (`syphon:` で始まる)。
    var streams: [String] { (receiver?.streams ?? []).sorted() + (syphon?.streams ?? []) }

    private func publishStreams() {
        let streams = streams
        guard streams != lastStreams else { return }
        lastStreams = streams
        onStreamsChanged(streams)
    }

    // MARK: - 取り込み

    /// 描く前に呼ぶ。`time` (表示の時刻) が前に取り込んだ時刻と同じ更新の中なら、取り込まずに
    /// 前の 1 枚を返す。
    func framesForDrawing(at time: CFTimeInterval) -> [String: SourceFrame] {
        // 同じ表示の更新で起きた描く場所どうしは、ほぼ同じ時刻を持つ。120Hz でも 1 更新は 8ms ある
        if time - lastPull > 0.002 || time < lastPull {
            lastPull = time
            pull()
        }
        return frames
    }

    /// 欲しい映像それぞれの最新の 1 枚を取る。新しい 1 枚が来たら、前の 1 枚は手放す
    /// (描いている途中のものは、描く側が持ち続けている)。
    private func pull() {
        let wanted = wanted()
        if let receiver, let renderer {
            for stream in wanted where !SyphonSources.isSyphon(stream) {
                guard let frame = receiver.latest(stream: stream), let texture = renderer.texture(for: frame)
                else { continue }
                let source = SourceFrame(link: frame, texture: texture)
                if isMeasuring { source.drawnHostTime = TimeCode.read(frame.surface) }
                frames[stream] = source
            }
            let alive = Set(receiver.streams)
            for stream in frames.keys where !SyphonSources.isSyphon(stream) && !alive.contains(stream) {
                frames[stream] = nil
            }
        }
        if let syphon {
            for (stream, frame) in syphon.pull(wanted) {
                if isMeasuring, let surface = frame.texture.iosurface {
                    frame.drawnHostTime = TimeCode.read(surface)
                }
                frames[stream] = frame
            }
            let alive = Set(syphon.streams)
            for stream in frames.keys where SyphonSources.isSyphon(stream) && !alive.contains(stream) {
                frames[stream] = nil
            }
        }
        publishSizes()
    }

    /// 取り込んだ絵の大きさを比べ、変わったものだけを知らせる。
    private func publishSizes() {
        for (stream, frame) in frames {
            let size = PixelSize(width: Double(frame.texture.width), height: Double(frame.texture.height))
            if sizes[stream] != size {
                sizes[stream] = size
                onSizeChanged(stream, size)
            }
        }
        for stream in sizes.keys where frames[stream] == nil {
            sizes[stream] = nil
            onSizeChanged(stream, nil)
        }
    }
}
