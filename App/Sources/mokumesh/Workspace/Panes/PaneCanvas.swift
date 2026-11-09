// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshEditor
import MokumeshMapping
import SwiftUI

/// ペインの描く場所。Metal の絵・上に重ねる目印・クリックの当たり判定が、同じ `Viewport`
/// を通る (ADR-0003 決定 5)。
///
/// - `model`: 見せるモデルの範囲。Metal は表示の更新ごとに、目印は SwiftUI の再評価ごとに呼ぶ
/// - `scene`: Metal に描くもの
/// - `overlay`: 目印 (選んだものの輪郭など)
/// - `onTap`: クリックした点 (モデルの空間)
struct PaneCanvas<Overlay: View>: View {
    let hub: FrameHub
    var inset: Double = 16
    let model: () -> MappingConfig.Rect
    let scene: (Viewport) -> RenderScene?
    @ViewBuilder let overlay: (Viewport) -> Overlay
    var onTap: ((Point) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            let viewport = viewport(geometry.size)
            ZStack(alignment: .topLeading) {
                MetalCanvas(hub: hub) { size in scene(self.viewport(size)) }
                overlay(viewport).allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture { location in
                guard let onTap, let point = viewport.toModel(Point(x: location.x, y: location.y)) else { return }
                onTap(point)
            }
        }
    }

    private func viewport(_ size: CGSize) -> Viewport {
        Viewport(model: model(), viewWidth: size.width, viewHeight: size.height, inset: inset)
    }
}

/// 目印を描く道具。
enum PaneDrawing {
    /// モデルの点を結んだ閉じた線。
    static func polygon(_ points: [Point], _ viewport: Viewport) -> Path {
        Path { path in
            let view = points.map { viewport.toView($0) }
            guard let first = view.first else { return }
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in view.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
            path.closeSubpath()
        }
    }

    static func rect(_ rect: MappingConfig.Rect, _ viewport: Viewport) -> Path {
        polygon(MappingConfig.Quad.corners(of: rect), viewport)
    }

    /// ペインの中の矩形 (point) をそのまま。
    static func viewRect(_ rect: MappingConfig.Rect) -> Path {
        Path(CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height))
    }

    static let selected = Color.accentColor
    static let unselected = Color.white.opacity(0.55)
    static let projector = Color.cyan.opacity(0.6)
    static let keystone = Color.yellow

    /// 目印に添える名前の札。
    static func tag(_ text: String, selected: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(selected ? AnyShapeStyle(Self.selected) : AnyShapeStyle(.black.opacity(0.6)), in: .rect(cornerRadius: 3))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
    }

    /// 札を置く位置 (モデルの点を、ペインの中の左上寄せの位置へ)。
    static func at(_ point: Point, _ viewport: Viewport) -> CGPoint {
        let view = viewport.toView(point)
        return CGPoint(x: view.x + 3, y: view.y + 3)
    }
}

/// ペインに何も描くものが無いときの案内。
struct PanePlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
