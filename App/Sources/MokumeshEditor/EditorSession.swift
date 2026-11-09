// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshMapping
import Observation

/// 編集の状態 (ADR-0003 決定 1)。保存しない実行時の状態をまとめて持つ。
///
/// - 選択 (全ペインと inspector が共有する)
/// - 出力ごとの出し方と、そこから求める開いておくべき窓
/// - ペインの配置
/// - 外から知らされる、繋がっている表示装置と届いている映像
///
/// 文書が変わると、消えたものを選択から外し、新しい出力に出し方を決める。ビューは
/// ここの意図の関数 (`EditorSession+Intents.swift`) を呼び、文書を直接は変えない。
@MainActor
@Observable
public final class EditorSession {
    public let document: EditorDocument
    public var policy: PresentationPolicy {
        didSet { planChanged() }
    }

    public var selection = Selection() {
        didSet {
            if let stream = Self.stream(of: selection.primary, in: document.config) { lastInputStream = stream }
        }
    }
    public var paneLayout = PaneLayout()
    /// 出力ごとの、望んだ出し方。
    public private(set) var modes: [MappingConfig.OutputID: PresentationMode] = [:]
    public private(set) var displays: [DisplayInfo] = []
    /// 届いている映像 (専用の受け渡しと Syphon)。
    public private(set) var availableStreams: [String] = []
    /// 入力のペインが最後に見せた映像。選択が映像から離れても、入力のペインはこれを見せ続ける。
    private var lastInputStream: String?

    /// 開いておくべき窓が変わったかもしれないときに呼ぶ。
    @ObservationIgnored private var planHandlers: [() -> Void] = []

    public init(document: EditorDocument, policy: PresentationPolicy = .init(), displays: [DisplayInfo] = []) {
        self.document = document
        self.policy = policy
        self.displays = displays
        syncModes()
        document.observeChanges { [weak self] _, new in
            guard let self else { return }
            selection = selection.pruned(against: new)
            syncModes()
            planChanged()
        }
    }

    // MARK: - 外から知らされること

    public func setDisplays(_ displays: [DisplayInfo]) {
        guard displays != self.displays else { return }
        self.displays = displays
        planChanged()
    }

    public func setAvailableStreams(_ streams: [String]) {
        guard streams != availableStreams else { return }
        availableStreams = streams
    }

    // MARK: - 出し方

    /// 開いておくべき窓。
    public var windowPlan: [MappingConfig.OutputID: OutputWindowTarget] {
        policy.plan(config: document.config, modes: modes, displays: displays)
    }

    /// 全画面を望んだのに表示装置が見つからない出力。
    public var missingDisplays: [MappingConfig.Output] {
        policy.missingDisplays(config: document.config, modes: modes, displays: displays)
    }

    public func mode(of output: MappingConfig.OutputID) -> PresentationMode {
        modes[output] ?? .preview
    }

    public func setMode(_ mode: PresentationMode, for output: MappingConfig.OutputID) {
        guard document.config.output(output) != nil, modes[output] != mode else { return }
        modes[output] = mode
        planChanged()
    }

    /// すべての出力を同じ出し方にする (本番の起動・Esc で窓を閉じる)。
    public func setAllModes(_ mode: PresentationMode) {
        for output in document.config.outputs { modes[output.id] = mode }
        planChanged()
    }

    /// 開いておくべき窓が変わったかもしれないときに受ける。
    public func observePlan(_ handler: @escaping () -> Void) {
        planHandlers.append(handler)
    }

    private func planChanged() {
        for handler in planHandlers { handler() }
    }

    /// 新しく現れた出力に出し方を決め、消えた出力のものを捨てる。
    private func syncModes() {
        let outputs = document.config.outputs
        let ids = Set(outputs.map(\.id))
        modes = modes.filter { ids.contains($0.key) }
        for output in outputs where modes[output.id] == nil {
            modes[output.id] = policy.initialMode(for: output, displays: displays)
        }
    }

    // MARK: - 映像

    /// 入力の節に並べる映像 1 つ。
    public struct InputItem: Hashable, Sendable, Identifiable {
        public var name: String
        /// いま届いているか。
        public var isAvailable: Bool
        /// どれかの面が使っているか。
        public var isUsed: Bool
        public var id: String { name }

        public init(name: String, isAvailable: Bool, isUsed: Bool) {
            self.name = name
            self.isAvailable = isAvailable
            self.isUsed = isUsed
        }
    }

    /// 入力の節に並べる映像。届いているものを先に、面が使っているのに届いていないものを後に。
    public var inputItems: [InputItem] {
        let used = Set(document.config.streamsInUse)
        let available = availableStreams.map { InputItem(name: $0, isAvailable: true, isUsed: used.contains($0)) }
        let missing = document.config.streamsInUse.filter { !availableStreams.contains($0) }
            .map { InputItem(name: $0, isAvailable: false, isUsed: true) }
        return available + missing
    }

    /// 入力のペインが見せる映像。選んだ映像か、選んだ面の映像。どちらでもなければ、最後に見せた映像か
    /// 最初の映像。
    public var inputStream: String? {
        if let stream = Self.stream(of: selection.primary, in: document.config) { return stream }
        let known = Set(inputItems.map(\.name))
        if let lastInputStream, known.contains(lastInputStream) { return lastInputStream }
        return inputItems.first?.name
    }

    /// 取り込む映像。見せている面が使う映像と、入力のペインが見せる映像。
    public var wantedStreams: Set<String> {
        var streams = Set(document.config.layers.compactMap { $0.surface.flatMap { $0.visible ? $0.stream : nil } })
        if let inputStream { streams.insert(inputStream) }
        return streams
    }

    private static func stream(of item: ItemID?, in config: MappingConfig) -> String? {
        switch item {
        case .input(let name): name
        case .layer(let id): config.layer(id)?.surface?.stream
        default: nil
        }
    }
}
