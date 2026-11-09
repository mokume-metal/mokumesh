// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshEditor
import MokumeshMapping
import SwiftUI

/// 入力のペイン。選んだ映像 (か、選んだ面の映像) を縦横比を保って描き、その映像を使う面の
/// 切り取り (入力の 4 隅) を重ねる。
///
/// この段では描くだけで、クリックで面を選ぶ。切り取りの編集は #24 でここに足す。
struct InputPane: View {
    let context: AppContext
    private var session: EditorSession { context.session }

    var body: some View {
        if let stream = session.inputStream {
            canvas(stream: stream)
        } else {
            PanePlaceholder(text: "映像がまだ届いていません。\n送り手 (mokume のスケッチや Syphon の送り手) を起こしてください。")
        }
    }

    private func canvas(stream: String) -> some View {
        let config = session.document.config
        let size = session.streamSizes[stream]
        let selected = session.selection.layers
        let surfaces = config.layers.compactMap(\.surface).filter { $0.stream == stream }
        return PaneCanvas(
            hub: context.hub,
            model: { [session = session] in PaneScenes.inputModel(pixelSize: session.streamSizes[stream]) },
            scene: { viewport in PaneScenes.input(stream: stream, viewport: viewport) }
        ) { viewport in
            ZStack(alignment: .topLeading) {
                PaneDrawing.viewRect(viewport.modelFrame).stroke(.gray, lineWidth: 1)
                ForEach(surfaces, id: \.id) { surface in
                    let isSelected = selected.contains(surface.id)
                    let corners = Self.inputCorners(surface, model: viewport.model)
                    PaneDrawing.polygon(corners, viewport)
                        .stroke(isSelected ? PaneDrawing.selected : PaneDrawing.unselected, lineWidth: isSelected ? 2 : 1)
                    PaneDrawing.tag(surface.name, selected: isSelected)
                        .offset(x: PaneDrawing.at(corners[0], viewport).x, y: PaneDrawing.at(corners[0], viewport).y)
                }
                PaneDrawing.tag(size.map { "\(stream)  \(Int($0.width))×\(Int($0.height))" } ?? stream, selected: false)
                    .padding(6)
            }
        } onTap: { point in
            let model = PaneScenes.inputModel(pixelSize: session.streamSizes[stream])
            let hit = surfaces.last { HitTest.contains(Self.inputCorners($0, model: model), point) }
            if let hit {
                session.selection.select(.layer(hit.id))
            } else {
                session.selection.select(.input(stream))
            }
        }
    }

    /// 面の切り取り (映像の中で 0〜1) を、ペインのモデルの空間 (映像の画素) へ。
    private static func inputCorners(_ surface: MappingConfig.Surface, model: MappingConfig.Rect) -> [Point] {
        surface.input.map { Point(x: model.x + $0.x * model.width, y: model.y + $0.y * model.height) }
    }
}
