// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshEditor
import SwiftUI

/// SwiftUI に置く `MetalCanvasView`。
///
/// 描く中身は SwiftUI の body を通さず、表示の更新ごとに `scene` を直接呼んで作る
/// (ドラッグ中でも SwiftUI の再評価を待たない)。
struct MetalCanvas: NSViewRepresentable {
    let hub: FrameHub
    let scene: (CGSize) -> RenderScene?

    func makeNSView(context: Context) -> MetalCanvasView {
        let view = MetalCanvasView(hub: hub)
        view.scene = scene
        return view
    }

    func updateNSView(_ view: MetalCanvasView, context: Context) {
        view.scene = scene
    }

    static func dismantleNSView(_ view: MetalCanvasView, coordinator: ()) {
        view.stop()
    }
}
