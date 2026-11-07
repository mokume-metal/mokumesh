// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeshMapping

@Suite("4 点合わせ")
struct HomographyTests {
    private func close(_ a: Point, _ b: Point, _ tolerance: Double = 1e-9) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    @Test("歪めない 4 隅は、絵の座標をそのまま返す")
    func identity_corners_map_to_themselves() throws {
        let homography = try #require(Homography(corners: MappingConfig.Region.identity))
        for (u, v) in [(0.0, 0.0), (1, 0), (0.25, 0.75), (0.5, 0.5)] {
            #expect(close(homography.apply(u, v), Point(x: u, y: v)))
        }
    }

    @Test(
        "絵の 4 隅は、与えた 4 隅へ写る",
        arguments: [
            // 台形 (射影の成分を持つ)
            [Point(x: 0.12, y: 0.08), Point(x: 0.91, y: 0.15), Point(x: 0.86, y: 0.93), Point(x: 0.07, y: 0.88)],
            // 平行四辺形 (射影の成分を持たない)
            [Point(x: 0.1, y: 0.1), Point(x: 0.8, y: 0.2), Point(x: 0.9, y: 0.9), Point(x: 0.2, y: 0.8)],
            // 大きく傾けた四角形
            [Point(x: 0.4, y: 0.0), Point(x: 1.0, y: 0.3), Point(x: 0.7, y: 1.0), Point(x: 0.0, y: 0.6)],
        ])
    func unit_square_corners_land_on_given_corners(corners: [Point]) throws {
        let homography = try #require(Homography(corners: corners))
        #expect(close(homography.apply(0, 0), corners[0]))
        #expect(close(homography.apply(1, 0), corners[1]))
        #expect(close(homography.apply(1, 1), corners[2]))
        #expect(close(homography.apply(0, 1), corners[3]))
    }

    @Test("逆の行列で、写した先から絵の座標へ戻る")
    func inverse_returns_to_picture_coordinates() throws {
        let corners = [
            Point(x: 0.12, y: 0.08), Point(x: 0.91, y: 0.15), Point(x: 0.86, y: 0.93), Point(x: 0.07, y: 0.88),
        ]
        let homography = try #require(Homography(corners: corners))
        let mapped = homography.apply(0.3, 0.6)
        let back = homography.inverse * SIMD3(mapped.x, mapped.y, 1)
        #expect(close(Point(x: back.x / back.z, y: back.y / back.z), Point(x: 0.3, y: 0.6)))
    }

    @Test(
        "四角形を成さない 4 隅は断る",
        arguments: [
            // 3 点が一直線
            [Point(x: 0, y: 0), Point(x: 0.5, y: 0), Point(x: 1, y: 0), Point(x: 0, y: 1)],
            // 辺がねじれる (右上と右下が入れ替わる)
            [Point(x: 0, y: 0), Point(x: 1, y: 1), Point(x: 1, y: 0), Point(x: 0, y: 1)],
            // 裏返る (反時計回り)
            [Point(x: 0, y: 0), Point(x: 0, y: 1), Point(x: 1, y: 1), Point(x: 1, y: 0)],
            // 凹んだ四角形
            [Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 0.3, y: 0.3), Point(x: 0, y: 1)],
            // 1 点に潰れる
            [Point(x: 0.5, y: 0.5), Point(x: 0.5, y: 0.5), Point(x: 0.5, y: 0.5), Point(x: 0.5, y: 0.5)],
        ])
    func degenerate_corners_are_rejected(corners: [Point]) {
        #expect(Homography(corners: corners) == nil)
    }

    @Test("隅を動かすと、その隅だけが動く")
    func moving_corner_moves_only_that_corner() throws {
        let region = MappingConfig.Region(name: "wall")
        let moved = try #require(region.movingCorner(2, to: Point(x: 0.8, y: 0.9)))
        #expect(moved.corners[2] == Point(x: 0.8, y: 0.9))
        #expect(Array(moved.corners[0...1]) == Array(region.corners[0...1]))
        #expect(moved.corners[3] == region.corners[3])
    }

    @Test(
        "四角形が裏返る・凹む動きは採らない",
        arguments: [
            // 右下を左上の向こうへ: 裏返る
            (2, Point(x: -0.5, y: -0.5)),
            // 右下を内側へ深く: 凹む
            (2, Point(x: 0.2, y: 0.2)),
            // 右上を左上に重ねる: 潰れる
            (1, Point(x: 0, y: 0)),
        ])
    func moving_corner_rejects_folding(index: Int, point: Point) {
        #expect(MappingConfig.Region(name: "wall").movingCorner(index, to: point) == nil)
    }

    @Test("隅が 4 つでなければ断る")
    func wrong_corner_count_is_rejected() {
        #expect(Homography(corners: Array(MappingConfig.Region.identity.prefix(3))) == nil)
    }
}

@Suite("設定")
struct MappingConfigTests {
    /// パッケージの根。代表例の置き場をここから引く。
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test("代表例を読め、書いて読み戻すと同じ設定になる")
    func example_round_trips() throws {
        let data = try Data(contentsOf: Self.root.appending(path: "Schemas/examples/mapping.json"))
        let config = try MappingConfig.decode(data)
        #expect(config.outputs.count == 1)
        #expect(config.outputs[0].regions[0].stream == "main")
        #expect(try MappingConfig.decode(config.encode()) == config)
    }

    @Test("分配器の構成 (表示装置 1 つに領域 3 つ) を持てる")
    func splitter_layout_round_trips() throws {
        let regions = (0..<3).map { index in
            MappingConfig.Region(
                name: "projector \(index + 1)",
                rect: .init(x: Double(index) / 3, y: 0, width: 1.0 / 3, height: 1))
        }
        let config = MappingConfig(
            outputs: [.init(display: .init(name: "TripleHead", id: 7), regions: regions)])
        let decoded = try MappingConfig.decode(config.encode())
        // 期待値は型を書いて外に出す。#expect の中の配列リテラルは、CI の Swift で型の推論が時間切れになった
        let expected: [Double] = [0, 1.0 / 3, 2.0 / 3]
        let actual = decoded.outputs[0].regions.map(\.rect.x)
        #expect(actual == expected)
    }

    @Test("知らない版は読まない")
    func unknown_version_is_rejected() throws {
        var config = MappingConfig()
        config.schemaVersion = 2
        #expect(throws: MappingConfig.LoadError.unsupportedVersion(2)) {
            try MappingConfig.decode(config.encode())
        }
    }

    @Test("4 隅が四角形を成さない領域があれば読まない")
    func invalid_corners_are_rejected() throws {
        var region = MappingConfig.Region(name: "broken")
        region.corners[1] = Point(x: 1, y: 1)
        region.corners[2] = Point(x: 1, y: 0)
        let config = MappingConfig(outputs: [.init(display: .init(name: "x", id: 1), regions: [region])])
        #expect(throws: MappingConfig.LoadError.invalidCorners(region: "broken")) {
            try MappingConfig.decode(config.encode())
        }
    }
}
