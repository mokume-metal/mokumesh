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
    @ObservationIgnored private(set) var currentFrames: [String: LinkFrame] = [:]
    /// 受けた枚数 (操作窓に出す)。
    private(set) var framesShown = 0
    private(set) var lastMessage: String?

    @ObservationIgnored let renderer = Renderer()
    @ObservationIgnored private var outputWindows: [OutputWindow] = []
    /// 本番 (操作窓なし) で起きているか。Esc で窓を閉じない。
    @ObservationIgnored var isProduction = false
    /// 出力を表示装置ではなく普通の窓に出す (`--window`)。
    @ObservationIgnored var isWindowed = false
    /// 提示の時刻を受け取る先 (計測)。
    @ObservationIgnored var onPresented: (@Sendable (Double, [LinkFrame]) -> Void)?

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

    var streams: [String] { receiver?.streams ?? [] }

    /// 映している映像それぞれの最新の 1 枚を取る。新しい 1 枚が来たら、前の 1 枚は手放す
    /// (描いている途中のものは、描く側が持ち続けている)。
    func pullFrames() {
        guard let receiver else { return }
        let wanted = Set(config.outputs.flatMap { $0.regions.map(\.stream) })
        for stream in wanted {
            if let frame = receiver.latest(stream: stream) {
                currentFrames[stream] = frame
                framesShown += 1
            }
        }
        for stream in currentFrames.keys where !receiver.streams.contains(stream) {
            currentFrames[stream] = nil
        }
    }

    func presentedHandler() -> (@Sendable (Double, [LinkFrame]) -> Void)? { onPresented }

    // MARK: - 出力

    func regions(of output: Int) -> [MappingConfig.Region] {
        output < config.outputs.count ? config.outputs[output].regions : []
    }

    func isShowing(_ display: ConnectedDisplay) -> Bool {
        config.outputs.contains { $0.display.id == display.id }
    }

    /// 表示装置へ映すかを切り替える。映し始めるときは、表示装置全体を 1 つの領域にする。
    func setShowing(_ display: ConnectedDisplay, _ showing: Bool) {
        if showing, !isShowing(display) {
            let stream = streams.first ?? "main"
            config.outputs.append(
                MappingConfig.Output(
                    display: .init(name: display.name, id: display.id),
                    regions: [MappingConfig.Region(name: display.name, stream: stream)]))
        } else if !showing {
            config.outputs.removeAll { $0.display.id == display.id }
        }
        rebuildWindows()
    }

    func setStream(_ stream: String, output: Int, region: Int) {
        guard output < config.outputs.count, region < config.outputs[output].regions.count else { return }
        config.outputs[output].regions[region].stream = stream
    }

    /// 隅を動かす。四角形が裏返る・潰れる動きは採らない。
    func moveCorner(output: Int, region: Int, corner: Int, to point: Point) {
        guard output < config.outputs.count, region < config.outputs[output].regions.count else { return }
        guard let moved = config.outputs[output].regions[region].movingCorner(corner, to: point) else { return }
        config.outputs[output].regions[region] = moved
        outputWindows.first { $0.outputIndex == output }?.refreshOverlay()
    }

    func resetCorners() {
        for output in config.outputs.indices {
            for region in config.outputs[output].regions.indices {
                config.outputs[output].regions[region].corners = MappingConfig.Region.identity
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
