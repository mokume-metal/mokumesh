// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshEditor
import MokumeshMapping
import SwiftUI

/// ステージのペイン。プロジェクタ配置の外形を下地に、面を重ねた絵を描く。
///
/// この段では描くだけで、クリックで面を選ぶ。面の 4 隅の編集は #24 でここに足す。
struct StagePane: View {
    let context: AppContext
    private var session: EditorSession { context.session }

    var body: some View {
        let config = session.document.config
        let selected = session.selection.layers
        PaneCanvas(
            hub: context.hub,
            model: { [document = session.document] in document.config.stageExtent },
            scene: { [document = session.document] viewport in PaneScenes.stage(document.config, viewport: viewport) }
        ) { viewport in
            ZStack(alignment: .topLeading) {
                PaneDrawing.rect(viewport.model, viewport)
                    .stroke(.gray, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                ForEach(config.outputs.flatMap(\.regions), id: \.id) { region in
                    PaneDrawing.rect(region.placement, viewport).stroke(PaneDrawing.projector.opacity(0.5), lineWidth: 1)
                }
                ForEach(config.layers, id: \.id) { layer in
                    if let surface = layer.surface {
                        let isSelected = selected.contains(surface.id)
                        PaneDrawing.polygon(surface.corners, viewport)
                            .stroke(
                                isSelected ? PaneDrawing.selected : PaneDrawing.unselected,
                                lineWidth: isSelected ? 2 : 1)
                        PaneDrawing.tag(surface.name, selected: isSelected)
                            .offset(x: PaneDrawing.at(surface.corners[0], viewport).x, y: PaneDrawing.at(surface.corners[0], viewport).y)
                    }
                }
            }
        } onTap: { point in
            if let id = HitTest.topmostSurface(at: point, in: session.document.config) {
                session.selection.select(.layer(id))
            } else {
                session.selection.clear()
            }
        }
        .overlay {
            if config.layers.isEmpty && config.outputs.isEmpty {
                PanePlaceholder(text: "面も出力もまだありません。\n階層の ＋ から足してください。")
            }
        }
    }
}
