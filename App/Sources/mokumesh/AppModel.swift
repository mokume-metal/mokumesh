// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import MokumeshLink
import MokumeshMapping
import Observation

/// 繋がっている表示装置 1 つ。
struct ConnectedDisplay: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let screen: NSScreen

    static func all() -> [ConnectedDisplay] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            else { return nil }
            return ConnectedDisplay(id: number.uint32Value, name: screen.localizedName, screen: screen)
        }
    }

    /// 設定の手掛かりから引く。識別子を先に見て、無ければ名前で探す。
    static func find(_ reference: MappingConfig.DisplayReference, in displays: [ConnectedDisplay])
        -> ConnectedDisplay?
    {
        displays.first { $0.id == reference.id } ?? displays.first { $0.name == reference.name }
    }
}

/// アプリの状態。設定・受け手・出力の窓を持つ。
@MainActor
@Observable
final class AppModel {
    private(set) var config: MappingConfig
    /// 設定を読み書きするファイル。
    var configURL: URL?
    var isEditing = false {
        didSet { outputWindows.forEach { $0.refreshOverlay() } }
    }
    private(set) var displays = ConnectedDisplay.all()
    private(set) var receiver: LinkReceiver?
    private(set) var receiverError: String?
    /// 映像の名前ごとの、いま映している 1 枚。
    @ObservationIgnored private(set) var currentFrames: [String: SourceFrame] = [:]
    /// 受けた枚数 (操作窓に出す)。
    private(set) var framesShown = 0
    private(set) var lastMessage: String?

    @ObservationIgnored let renderer = Renderer()
    @ObservationIgnored private lazy var syphon: SyphonSources? = renderer.map { SyphonSources(device: $0.device) }
    @ObservationIgnored private var outputWindows: [OutputWindow] = []
    /// 本番 (操作窓なし) で起きているか。Esc で窓を閉じない。
    @ObservationIgnored var isProduction = false
    /// 出力を表示装置ではなく普通の窓に出す (`--window`)。
    @ObservationIgnored var isWindowed = false
    /// 計測しているか。しているときは、届いた 1 枚の上端から描いた時刻を読む。
    @ObservationIgnored var isMeasuring = false
    /// 提示の時刻を受け取る先 (計測)。
    @ObservationIgnored var onPresented: (@Sendable (Double, [SourceFrame]) -> Void)?

    init(config: MappingConfig) {
        self.config = config
        startReceiver()
    }

    // MARK: - 受け手

    func startReceiver() {
        receiver?.close()
        do {
            receiver = try LinkReceiver(channel: config.channel)
            receiverError = nil
        } catch {
            receiver = nil
            receiverError = "チャンネル \(config.channel) で受けられない (同じチャンネルの受け手が既に起きている?)"
        }
    }

    /// 映せる映像。専用の受け渡しの映像と、Syphon の送り手 (`syphon:` で始まる)。
    var streams: [String] { (receiver?.streams ?? []) + (syphon?.streams ?? []) }

    /// 映している映像それぞれの最新の 1 枚を取る。新しい 1 枚が来たら、前の 1 枚は手放す
    /// (描いている途中のものは、描く側が持ち続けている)。
    func pullFrames() {
        let wanted = Set(config.layers.compactMap { $0.surface.flatMap { $0.visible ? $0.stream : nil } })
        if let receiver, let renderer {
            for stream in wanted where !SyphonSources.isSyphon(stream) {
                guard let frame = receiver.latest(stream: stream), let texture = renderer.texture(for: frame)
                else { continue }
                let source = SourceFrame(link: frame, texture: texture)
                if isMeasuring { source.drawnHostTime = TimeCode.read(frame.surface) }
                currentFrames[stream] = source
                framesShown += 1
            }
            for stream in currentFrames.keys
            where !SyphonSources.isSyphon(stream) && !receiver.streams.contains(stream) {
                currentFrames[stream] = nil
            }
        }
        if let syphon {
            for (stream, frame) in syphon.pull(wanted) {
                if isMeasuring, let surface = frame.texture.iosurface {
                    frame.drawnHostTime = TimeCode.read(surface)
                }
                currentFrames[stream] = frame
                framesShown += 1
            }
            let alive = Set(syphon.streams)
            for stream in currentFrames.keys where SyphonSources.isSyphon(stream) && !alive.contains(stream) {
                currentFrames[stream] = nil
            }
        }
    }

    func presentedHandler() -> (@Sendable (Double, [SourceFrame]) -> Void)? { onPresented }

    // MARK: - 出力

    func regions(of output: Int) -> [MappingConfig.Region] {
        output < config.outputs.count ? config.outputs[output].regions : []
    }

    func isShowing(_ display: ConnectedDisplay) -> Bool {
        config.outputs.contains { $0.display.id == display.id }
    }

    /// 表示装置へ映すかを切り替える。映し始めるときは、表示装置全体を 1 つの領域にし、
    /// その受け持つ範囲をステージの右端に足す。面が 1 枚も無ければ、範囲を覆う面を置く。
    func setShowing(_ display: ConnectedDisplay, _ showing: Bool) {
        if showing, !isShowing(display) {
            let scale = display.screen.backingScaleFactor
            let size = (width: display.screen.frame.width * scale, height: display.screen.frame.height * scale)
            let placement = MappingConfig.Rect(
                x: config.stageBounds?.maxX ?? 0, y: 0, width: Double(size.width), height: Double(size.height))
            config.outputs.append(
                MappingConfig.Output(
                    display: .init(name: display.name, id: display.id),
                    regions: [MappingConfig.Region(name: display.name, placement: placement)]))
            if !config.layers.contains(where: { $0.surface != nil }) {
                config.layers.append(
                    .surface(.init(name: "面 1", stream: streams.first ?? "main", covering: placement)))
            }
        } else if !showing {
            config.outputs.removeAll { $0.display.id == display.id }
        }
        rebuildWindows()
    }

    /// 面の映像を替える。
    func setStream(_ stream: String, layer: Int) {
        guard config.layers.indices.contains(layer), case .surface(var surface) = config.layers[layer] else { return }
        surface.stream = stream
        config.layers[layer] = .surface(surface)
    }

    /// 領域の台形補正の隅を動かす。四角形が裏返る・潰れる動きは採らない。
    func moveCorner(output: Int, region: Int, corner: Int, to point: Point) {
        guard output < config.outputs.count, region < config.outputs[output].regions.count else { return }
        guard let moved = config.outputs[output].regions[region].movingCorner(corner, to: point) else { return }
        config.outputs[output].regions[region] = moved
        outputWindows.first { $0.outputIndex == output }?.refreshOverlay()
    }

    func resetCorners() {
        for output in config.outputs.indices {
            for region in config.outputs[output].regions.indices {
                config.outputs[output].regions[region].keystone = MappingConfig.Quad.unit
            }
        }
        outputWindows.forEach { $0.refreshOverlay() }
    }

    /// 設定に合わせて出力の窓を開き直す。見つからない表示装置は飛ばして知らせる。
    func rebuildWindows() {
        for window in outputWindows {
            window.stop()
            window.close()
        }
        outputWindows = []
        displays = ConnectedDisplay.all()
        var missing: [String] = []
        for (index, output) in config.outputs.enumerated() {
            let found = ConnectedDisplay.find(output.display, in: displays)
            guard let screen = found?.screen ?? (isWindowed ? NSScreen.main : nil) else {
                missing.append(output.display.name)
                continue
            }
            let window = OutputWindow(screen: screen, outputIndex: index, model: self, windowed: isWindowed)
            // 計測は提示の時刻を見るので、窓が他の窓の後ろに回って提示が止まらないよう前面に浮かせる
            if isMeasuring, isWindowed { window.level = .floating }
            window.orderFrontRegardless()
            outputWindows.append(window)
        }
        lastMessage = missing.isEmpty ? nil : "見つからない表示装置: \(missing.joined(separator: ", "))"
        if isProduction, !isWindowed { NSCursor.hide() }
    }

    func closeOutputsFromKeyboard() {
        guard !isProduction else { return }
        config.outputs.removeAll()
        rebuildWindows()
    }

    // MARK: - 読み書き

    func save(to url: URL) {
        do {
            try config.encode().write(to: url, options: .atomic)
            configURL = url
            lastMessage = "保存した: \(url.lastPathComponent)"
        } catch {
            lastMessage = "保存できなかった: \(error.localizedDescription)"
        }
    }

    func load(from url: URL) {
        do {
            let loaded = try MappingConfig.decode(Data(contentsOf: url))
            let channelChanged = loaded.channel != config.channel
            config = loaded
            configURL = url
            if channelChanged { startReceiver() }
            rebuildWindows()
            lastMessage = lastMessage ?? "読み込んだ: \(url.lastPathComponent)"
        } catch {
            lastMessage = "読み込めなかった: \(error)"
        }
    }

    func refreshDisplays() { displays = ConnectedDisplay.all() }
}
