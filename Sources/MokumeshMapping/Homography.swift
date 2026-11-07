// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 平面上の点。座標の単位は使う側が決める (mokumesh では領域の中で 0〜1 に正規化した位置)。
public struct Point: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 4 点合わせの射影変換。
///
/// 絵の単位正方形 (左上 (0,0)・右上 (1,0)・右下 (1,1)・左下 (0,1)) を、4 隅の点へ写す。
/// 4 隅は同じ順 (左上・右上・右下・左下) で与える。
public struct Homography: Equatable, Sendable {
    /// 同次座標の 3×3 行列。列優先 (simd の並び)。`matrix * (u, v, 1)` が写した先の同次座標。
    public let matrix: simd_double3x3

    /// 4 隅から作る。4 隅が凸な四角形を成さない (3 点が一直線・ねじれ・裏返り) と `nil`。
    ///
    /// 解き方は、正方形から四角形への写像を閉じた形で書く方法 (Heckbert 1989) で、
    /// 一般の 8 元連立方程式を解かない。
    public init?(corners: [Point]) {
        guard corners.count == 4, Self.isConvex(corners) else { return nil }
        let (p0, p1, p2, p3) = (corners[0], corners[1], corners[2], corners[3])
        let sx = p0.x - p1.x + p2.x - p3.x
        let sy = p0.y - p1.y + p2.y - p3.y
        let a, b, c, d, e, f, g, h: Double
        if abs(sx) < 1e-12 && abs(sy) < 1e-12 {
            // 平行四辺形: 射影の成分は無い
            a = p1.x - p0.x; b = p2.x - p1.x; c = p0.x
            d = p1.y - p0.y; e = p2.y - p1.y; f = p0.y
            g = 0; h = 0
        } else {
            let dx1 = p1.x - p2.x, dx2 = p3.x - p2.x
            let dy1 = p1.y - p2.y, dy2 = p3.y - p2.y
            let denominator = dx1 * dy2 - dx2 * dy1
            guard abs(denominator) > 1e-12 else { return nil }
            g = (sx * dy2 - dx2 * sy) / denominator
            h = (dx1 * sy - sx * dy1) / denominator
            a = p1.x - p0.x + g * p1.x; b = p3.x - p0.x + h * p3.x; c = p0.x
            d = p1.y - p0.y + g * p1.y; e = p3.y - p0.y + h * p3.y; f = p0.y
        }
        // 行列の列: u に掛かる列・v に掛かる列・定数の列
        matrix = simd_double3x3(
            columns: (SIMD3(a, d, g), SIMD3(b, e, h), SIMD3(c, f, 1)))
    }

    /// 絵の座標 (u, v) を写した先の点。
    public func apply(_ u: Double, _ v: Double) -> Point {
        let projected = matrix * SIMD3(u, v, 1)
        return Point(x: projected.x / projected.z, y: projected.y / projected.z)
    }

    /// 写した先の点から、絵の座標へ戻す行列。
    public var inverse: simd_double3x3 { matrix.inverse }

    /// 4 隅が、裏返らない凸な四角形を成すか。
    ///
    /// 各辺の外積の符号が 4 つとも同じで、かつ 0 から十分に離れていること。
    /// 3 点が一直線に並ぶ・辺がねじれる・裏返る (隅の順が逆になる) のを断る。
    public static func isConvex(_ corners: [Point]) -> Bool {
        guard corners.count == 4 else { return false }
        var signs: [Double] = []
        for index in 0..<4 {
            let a = corners[index], b = corners[(index + 1) % 4], c = corners[(index + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            signs.append(cross)
        }
        let scale = corners.map { max(abs($0.x), abs($0.y)) }.max() ?? 1
        let epsilon = 1e-9 * max(scale * scale, 1)
        // 画面の座標は y が下向きなので、左上→右上→右下→左下は時計回りで外積は正になる
        return signs.allSatisfy { $0 > epsilon }
    }
}
