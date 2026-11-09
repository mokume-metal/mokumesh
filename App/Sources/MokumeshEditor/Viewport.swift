// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshMapping

/// ペインが見るモデルの空間と、ペインの点の往復 (ADR-0003 決定 5)。
///
/// モデルの空間はペインごとに違う (ステージの画素・映像の 0〜1・領域の 0〜1)。どれも
/// 左上が原点で y が下向きなので、ペイン (SwiftUI の座標・左上原点) とは拡大と平行移動だけで
/// 写し合う。縦横比を保ってペインに収め (aspect-fit)、余白を残す。
///
/// Metal に描く範囲 (`modelFrame`) と、上に重ねる目印、クリックの当たり判定が、同じこの値を通る。
public struct Viewport: Equatable, Sendable {
    /// 見せるモデルの範囲。
    public var model: MappingConfig.Rect
    /// ペインの大きさ (point)。
    public var viewWidth: Double
    public var viewHeight: Double
    /// 周りに残す余白 (point)。
    public var inset: Double

    public init(model: MappingConfig.Rect, viewWidth: Double, viewHeight: Double, inset: Double = 0) {
        self.model = model
        self.viewWidth = viewWidth
        self.viewHeight = viewHeight
        self.inset = inset
    }

    /// モデルの 1 単位が何 point か。描けない大きさなら 0。
    public var scale: Double {
        guard model.width > 0, model.height > 0 else { return 0 }
        let available = (width: viewWidth - 2 * inset, height: viewHeight - 2 * inset)
        guard available.width > 0, available.height > 0 else { return 0 }
        return min(available.width / model.width, available.height / model.height)
    }

    /// モデルの範囲が収まる、ペインの中の矩形 (point)。
    public var modelFrame: MappingConfig.Rect {
        let width = model.width * scale, height = model.height * scale
        return .init(x: (viewWidth - width) / 2, y: (viewHeight - height) / 2, width: width, height: height)
    }

    public func toView(_ point: Point) -> Point {
        let frame = modelFrame
        return Point(x: frame.x + (point.x - model.x) * scale, y: frame.y + (point.y - model.y) * scale)
    }

    /// ペインの点をモデルへ。描けない大きさなら `nil`。
    public func toModel(_ point: Point) -> Point? {
        guard scale > 0 else { return nil }
        let frame = modelFrame
        return Point(x: model.x + (point.x - frame.x) / scale, y: model.y + (point.y - frame.y) / scale)
    }

    /// ペインの中の矩形 (`modelFrame` など) を、ペイン全体に対する 0〜1 へ。Metal の仮想の領域の
    /// `rect` に渡す形。
    public func normalized(_ rect: MappingConfig.Rect) -> MappingConfig.Rect {
        guard viewWidth > 0, viewHeight > 0 else { return .unit }
        return .init(
            x: rect.x / viewWidth, y: rect.y / viewHeight, width: rect.width / viewWidth,
            height: rect.height / viewHeight)
    }

    /// ペインの点から `radius` (point) の内で一番近い点の添字。点はモデルの空間で渡す。
    public func nearest(_ points: [Point], to viewPoint: Point, within radius: Double) -> Int? {
        var best: (index: Int, distance: Double)?
        for (index, point) in points.enumerated() {
            let view = toView(point)
            let distance = ((view.x - viewPoint.x) * (view.x - viewPoint.x) + (view.y - viewPoint.y) * (view.y - viewPoint.y))
                .squareRoot()
            if distance <= radius, distance < (best?.distance ?? .infinity) { best = (index, distance) }
        }
        return best?.index
    }
}

/// クリックの当たり判定 (ペインに依らない部分)。
public enum HitTest {
    /// 多角形の内側か (偶奇の規則)。辺の上はどちらに転んでもよい。
    public static func contains(_ polygon: [Point], _ point: Point) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon[polygon.count - 1]
        for current in polygon {
            if (current.y > point.y) != (previous.y > point.y) {
                let x = (previous.x - current.x) * (point.y - current.y) / (previous.y - current.y) + current.x
                if point.x < x { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    /// ステージの点にある、一番上に見えている面。
    public static func topmostSurface(at point: Point, in config: MappingConfig) -> MappingConfig.LayerID? {
        for layer in config.layers.reversed() {
            if let surface = layer.surface, surface.visible, contains(surface.corners, point) { return surface.id }
        }
        return nil
    }
}

extension MappingConfig {
    /// ステージのペインで見せる範囲。領域があればその外接矩形、無ければ面の外接矩形、
    /// どちらも無ければ 1920×1080。
    public var stageExtent: Rect {
        if let stageBounds { return stageBounds }
        let points = layers.flatMap { $0.surface?.corners ?? $0.mask?.points ?? [] }
        guard let first = points.first else { return Rect(x: 0, y: 0, width: 1920, height: 1080) }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in points {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return Rect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }
}
