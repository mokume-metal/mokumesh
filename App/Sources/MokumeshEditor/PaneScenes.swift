// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshMapping

/// 1 つの描く場所に描くもの。出力の窓と同じ描き方 (`Renderer.draw`) に渡す形。
public struct RenderScene: Equatable, Sendable {
    /// 描く場所の中の領域 (`rect` は描く場所の幅と高さで 0〜1)。
    public var regions: [MappingConfig.Region]
    public var layers: [MappingConfig.Layer]

    public init(regions: [MappingConfig.Region], layers: [MappingConfig.Layer]) {
        self.regions = regions
        self.layers = layers
    }
}

/// ペインに描くものを「仮想の領域」で組む (ADR-0003 決定 6)。
///
/// ペインは出力の窓と同じ `Renderer` で描く。違いは領域だけで、ペインの見せたい範囲を
/// 受け持つ領域を 1 つ (出力のプレビューは出力の領域の数だけ) 作り、`Viewport` が決めた
/// 枠に置く。
public enum PaneScenes {
    /// ステージのペイン: ステージの外形 (`viewport.model`) を、台形補正なしで映す。
    public static func stage(_ config: MappingConfig, viewport: Viewport) -> RenderScene {
        RenderScene(
            regions: [
                .init(id: .init("stage"), name: "stage", rect: viewport.normalized(viewport.modelFrame), placement: viewport.model)
            ],
            layers: config.layers)
    }

    /// 入力のペインで見せるモデルの範囲 (映像の画素)。大きさが分からなければ 16:9。
    public static func inputModel(pixelSize: PixelSize?) -> MappingConfig.Rect {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return .init(x: 0, y: 0, width: 1920, height: 1080)
        }
        return .init(x: 0, y: 0, width: pixelSize.width, height: pixelSize.height)
    }

    /// 入力のペイン: 映像全体を切り取らずに、映像の画素の範囲 (`viewport.model`) へ映す。
    public static func input(stream: String, viewport: Viewport) -> RenderScene {
        let surface = MappingConfig.Surface(id: .init("input"), name: "input", stream: stream, covering: viewport.model)
        return RenderScene(
            regions: [
                .init(id: .init("input"), name: "input", rect: viewport.normalized(viewport.modelFrame), placement: viewport.model)
            ],
            layers: [.surface(surface)])
    }

    /// 出力のプレビューで見せるモデルの範囲 (表示装置の画素)。
    ///
    /// 表示装置が繋がっていればその大きさ、無ければ領域が 1 つならその受け持つ範囲の大きさ、
    /// それ以外は 1920×1080 (表示装置全体の縦横比が分からない)。
    public static func outputModel(_ output: MappingConfig.Output, displays: [DisplayInfo]) -> MappingConfig.Rect {
        if let display = DisplayInfo.find(output.display, in: displays) {
            return .init(x: 0, y: 0, width: display.pixelWidth, height: display.pixelHeight)
        }
        if output.regions.count == 1, let placement = output.regions.first?.placement {
            return .init(x: 0, y: 0, width: placement.width, height: placement.height)
        }
        return .init(x: 0, y: 0, width: 1920, height: 1080)
    }

    /// 出力のプレビュー: 出力の窓に映るものを、表示装置の範囲 (`viewport.model`) ごと縮めて映す。
    public static func output(_ output: MappingConfig.Output, layers: [MappingConfig.Layer], viewport: Viewport)
        -> RenderScene
    {
        RenderScene(
            regions: output.regions.map { region in
                var placed = region
                placed.rect = viewport.normalized(regionFrame(region, viewport: viewport))
                return placed
            },
            layers: layers)
    }

    /// 領域が出力のプレビューの中で占める枠 (point)。
    public static func regionFrame(_ region: MappingConfig.Region, viewport: Viewport) -> MappingConfig.Rect {
        let frame = viewport.modelFrame
        return .init(
            x: frame.x + region.rect.x * frame.width, y: frame.y + region.rect.y * frame.height,
            width: region.rect.width * frame.width, height: region.rect.height * frame.height)
    }
}
