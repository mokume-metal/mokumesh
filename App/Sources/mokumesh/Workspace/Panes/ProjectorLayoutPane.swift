// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshEditor
import MokumeshMapping
import SwiftUI

/// プロジェクタ配置のペイン。各プロジェクタ (領域) が受け持つステージの範囲を、解像度どおりの
/// 矩形として並べて見せる。外接矩形がステージの形になる。
///
/// この段では描くだけで、クリックで領域を選ぶ。並べ替え・のりしろ・台形補正は #23 でここに足す。
struct ProjectorLayoutPane: View {
    let context: AppContext
    private var session: EditorSession { context.session }

    var body: some View {
        let config = session.document.config
        let selection = session.selection
        PaneCanvas(
            hub: context.hub,
            model: { [document = session.document] in document.config.stageExtent },
            scene: { [document = session.document] viewport in PaneScenes.stage(document.config, viewport: viewport) }
        ) { viewport in
            ZStack(alignment: .topLeading) {
                PaneDrawing.rect(viewport.model, viewport)
                    .stroke(.gray, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                PaneDrawing.tag(
                    "ステージ \(Int(viewport.model.width))×\(Int(viewport.model.height))", selected: false
                )
                .offset(x: viewport.modelFrame.x, y: max(viewport.modelFrame.y - 18, 0))
                ForEach(config.outputs, id: \.id) { output in
                    ForEach(output.regions, id: \.id) { region in
                        let isSelected =
                            selection.contains(.region(region.id)) || selection.contains(.output(output.id))
                        PaneDrawing.rect(region.placement, viewport)
                            .fill(PaneDrawing.projector.opacity(isSelected ? 0.18 : 0.06))
                        PaneDrawing.rect(region.placement, viewport)
                            .stroke(isSelected ? PaneDrawing.selected : PaneDrawing.projector, lineWidth: isSelected ? 2 : 1)
                        let label =
                            "\(region.name) · \(output.display.name) · \(Int(region.placement.width))×\(Int(region.placement.height))"
                        PaneDrawing.tag(label, selected: isSelected)
                            .offset(
                                x: PaneDrawing.at(Point(x: region.placement.x, y: region.placement.y), viewport).x,
                                y: PaneDrawing.at(Point(x: region.placement.x, y: region.placement.y), viewport).y)
                    }
                }
            }
        } onTap: { point in
            let regions = session.document.config.outputs.flatMap(\.regions)
            if let region = regions.last(where: { HitTest.contains(MappingConfig.Quad.corners(of: $0.placement), point) }) {
                session.selection.select(.region(region.id))
            } else {
                session.selection.clear()
            }
        }
        .overlay {
            if config.outputs.isEmpty {
                PanePlaceholder(text: "プロジェクタがまだありません。\n階層の ＋ から出力を足してください。")
            }
        }
    }
}
