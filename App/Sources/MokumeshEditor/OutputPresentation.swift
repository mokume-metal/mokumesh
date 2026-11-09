// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshMapping

/// 繋がっている表示装置 1 つ。AppKit (`NSScreen`) を抜いた値で、編集の論理はこれだけを見る。
public struct DisplayInfo: Hashable, Sendable, Identifiable {
    /// `CGDirectDisplayID`。
    public var id: UInt32
    public var name: String
    /// 画素の幅と高さ。
    public var pixelWidth: Double
    public var pixelHeight: Double

    public init(id: UInt32, name: String, pixelWidth: Double, pixelHeight: Double) {
        self.id = id
        self.name = name
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public var reference: MappingConfig.DisplayReference { .init(name: name, id: id) }

    /// 設定の手掛かりから引く。識別子を先に見て、無ければ名前で探す (識別子は繋ぎ直しで変わりうる)。
    public static func find(_ reference: MappingConfig.DisplayReference, in displays: [DisplayInfo]) -> DisplayInfo? {
        displays.first { $0.id == reference.id } ?? displays.first { $0.name == reference.name }
    }
}

/// 出力 1 つの出し方 (ADR-0003 決定 7)。保存しない実行時の状態。
///
/// 全画面の先は設定の `Output.display` を正とし、ここには持たない。
public enum PresentationMode: String, CaseIterable, Hashable, Sendable {
    /// 操作窓のプレビューだけ。
    case preview
    /// 普通の窓に出す (表示装置の代わり。プロジェクタの無い手元で確かめる)。
    case window
    /// 設定の表示装置を全画面で覆う。
    case fullscreen
}

/// 開いておくべき出力の窓 1 つの形。
public enum OutputWindowTarget: Hashable, Sendable {
    case window
    case fullscreen(displayID: UInt32)
}

/// 出力の出し方の決まりと、望んだ出し方から開くべき窓を出す計画。
public struct PresentationPolicy: Sendable {
    /// 全画面を使わず、窓だけで出す (`--window`)。
    public var windowedOnly: Bool
    /// 操作窓が載っている表示装置。そこを全画面で覆うと操作窓が隠れる。
    public var controlDisplayID: UInt32?

    public init(windowedOnly: Bool = false, controlDisplayID: UInt32? = nil) {
        self.windowedOnly = windowedOnly
        self.controlDisplayID = controlDisplayID
    }

    /// 出力を新しく見たとき (読み込み・追加) の出し方。
    ///
    /// `--window` なら窓。参照先の表示装置が繋がっていて、操作窓の載っていない表示装置なら
    /// 全画面 (プロジェクタへそのまま映す)。それ以外はプレビューだけ。
    public func initialMode(for output: MappingConfig.Output, displays: [DisplayInfo]) -> PresentationMode {
        if windowedOnly { return .window }
        guard let display = DisplayInfo.find(output.display, in: displays) else { return .preview }
        return display.id == controlDisplayID ? .preview : .fullscreen
    }

    /// 全画面にすると操作窓を覆ってしまうか (確かめてから切り替える目安)。
    public func coversControlWindow(_ output: MappingConfig.Output, displays: [DisplayInfo]) -> Bool {
        guard let controlDisplayID else { return false }
        return DisplayInfo.find(output.display, in: displays)?.id == controlDisplayID
    }

    /// 望んだ出し方と、いま繋がっている表示装置から、開いておくべき窓の組を出す。
    ///
    /// 全画面の先が繋がっていない出力は窓を開かない (望んだ出し方は変えないので、
    /// 繋ぎ直せば次の計画で開く)。`--window` のときは全画面を窓に読み替える。
    public func plan(
        config: MappingConfig, modes: [MappingConfig.OutputID: PresentationMode], displays: [DisplayInfo]
    ) -> [MappingConfig.OutputID: OutputWindowTarget] {
        var targets: [MappingConfig.OutputID: OutputWindowTarget] = [:]
        for output in config.outputs {
            switch modes[output.id] ?? .preview {
            case .preview:
                continue
            case .window:
                targets[output.id] = .window
            case .fullscreen:
                if windowedOnly {
                    targets[output.id] = .window
                } else if let display = DisplayInfo.find(output.display, in: displays) {
                    targets[output.id] = .fullscreen(displayID: display.id)
                }
            }
        }
        return targets
    }

    /// 全画面を望んだのに、表示装置が見つからず映せていない出力。
    public func missingDisplays(
        config: MappingConfig, modes: [MappingConfig.OutputID: PresentationMode], displays: [DisplayInfo]
    ) -> [MappingConfig.Output] {
        guard !windowedOnly else { return [] }
        return config.outputs.filter {
            modes[$0.id] == .fullscreen && DisplayInfo.find($0.display, in: displays) == nil
        }
    }
}
