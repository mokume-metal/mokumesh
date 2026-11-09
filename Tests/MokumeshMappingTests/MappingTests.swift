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
        let homography = try #require(Homography(corners: MappingConfig.Quad.unit))
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
        #expect(moved.keystone[2] == Point(x: 0.8, y: 0.9))
        #expect(Array(moved.keystone[0...1]) == Array(region.keystone[0...1]))
        #expect(moved.keystone[3] == region.keystone[3])
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
        #expect(Homography(corners: Array(MappingConfig.Quad.unit.prefix(3))) == nil)
    }
}

@Suite("設定")
struct MappingConfigTests {
    /// パッケージの根。代表例の置き場をここから引く。
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func close(_ a: Point?, _ b: Point, _ tolerance: Double = 1e-9) -> Bool {
        guard let a else { return false }
        return abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    private func display(_ id: UInt32) -> MappingConfig.DisplayReference { .init(name: "PJ \(id)", id: id) }

    @Test("代表例を読め、書いて読み戻すと同じ設定になる")
    func example_round_trips() throws {
        let data = try Data(contentsOf: Self.root.appending(path: "Schemas/examples/mapping.json"))
        let config = try MappingConfig.decode(data)
        #expect(config.outputs.count == 2)
        #expect(config.layers.count == 3)
        #expect(try MappingConfig.decode(config.encode()) == config)
    }

    @Test("分配器の構成 (表示装置 1 つに領域 3 つ) を持てる")
    func splitter_layout_round_trips() throws {
        let regions = (0..<3).map { index in
            MappingConfig.Region(
                name: "projector \(index + 1)",
                rect: .init(x: Double(index) / 3, y: 0, width: 1.0 / 3, height: 1),
                placement: .init(x: Double(index) * 1920, y: 0, width: 1920, height: 1080))
        }
        let config = MappingConfig(outputs: [.init(display: display(7), regions: regions)])
        let decoded = try MappingConfig.decode(config.encode())
        // 期待値は型を書いて外に出す。#expect の中の配列リテラルは、CI の Swift で型の推論が時間切れになった
        let expected: [Double] = [0, 1.0 / 3, 2.0 / 3]
        let actual = decoded.outputs[0].regions.map(\.rect.x)
        #expect(actual == expected)
    }

    @Test("ステージの外形は、領域の受け持つ範囲の外接矩形になる")
    func stage_bounds_cover_all_placements() {
        // 1920×1080 の 2 台を 200 画素重ねて横に並べ、3 台目を下に置く
        let config = MappingConfig(outputs: [
            .init(
                display: display(1),
                regions: [.init(name: "left", placement: .init(x: 0, y: 0, width: 1920, height: 1080))]),
            .init(
                display: display(2),
                regions: [
                    .init(name: "right", placement: .init(x: 1720, y: 0, width: 1920, height: 1080)),
                    .init(name: "floor", placement: .init(x: 500, y: 1080, width: 1280, height: 720)),
                ]),
        ])
        #expect(config.stageBounds == .init(x: 0, y: 0, width: 3640, height: 1800))
        #expect(MappingConfig().stageBounds == nil)
    }

    @Test("ステージにまたがる面は、領域ごとにその受け持つ部分が映る")
    func surface_spans_regions() throws {
        // 2 台で 3840×1080 を受け持ち、面がステージ全体を覆う。映像の左半分を切り取る
        let surface = MappingConfig.Surface(
            name: "wide", input: MappingConfig.Quad.corners(of: .init(x: 0, y: 0, width: 0.5, height: 1)),
            corners: MappingConfig.Quad.corners(of: .init(x: 0, y: 0, width: 3840, height: 1080)))
        let left = MappingConfig.Region(name: "left", placement: .init(x: 0, y: 0, width: 1920, height: 1080))
        let right = MappingConfig.Region(name: "right", placement: .init(x: 1920, y: 0, width: 1920, height: 1080))
        let leftMapping = try #require(MappingConfig.mapping(surface: surface, region: left))
        let rightMapping = try #require(MappingConfig.mapping(surface: surface, region: right))
        // 左の台の右端 = 映像の 1/4、右の台の左端も同じ点
        #expect(close(leftMapping.inputPoint(atRegion: Point(x: 1, y: 0.5)), Point(x: 0.25, y: 0.5)))
        #expect(close(rightMapping.inputPoint(atRegion: Point(x: 0, y: 0.5)), Point(x: 0.25, y: 0.5)))
        #expect(close(rightMapping.inputPoint(atRegion: Point(x: 1, y: 1)), Point(x: 0.5, y: 1)))
    }

    @Test("面の外と、台形補正で受け持つ範囲の外は描かない")
    func outside_is_not_drawn() throws {
        let surface = MappingConfig.Surface(
            name: "small", covering: .init(x: 480, y: 270, width: 960, height: 540))
        var region = MappingConfig.Region(name: "pj")
        let mapping = try #require(MappingConfig.mapping(surface: surface, region: region))
        #expect(mapping.inputPoint(atRegion: Point(x: 0.1, y: 0.1)) == nil)
        #expect(close(mapping.inputPoint(atRegion: Point(x: 0.5, y: 0.5)), Point(x: 0.5, y: 0.5)))

        // 受け持つ範囲を領域の中央の半分へ縮めると、領域の角は範囲の外になる。面が範囲より
        // 大きくても (隣の台へまたがっていても)、範囲の外は映さない
        region.keystone = MappingConfig.Quad.corners(of: .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let wide = MappingConfig.Surface(name: "wide", covering: .init(x: -1920, y: -1080, width: 5760, height: 3240))
        let shrunk = try #require(MappingConfig.mapping(surface: wide, region: region))
        #expect(shrunk.inputPoint(atRegion: Point(x: 0.1, y: 0.1)) == nil)
        #expect(close(shrunk.inputPoint(atRegion: Point(x: 0.25, y: 0.25)), Point(x: 1.0 / 3, y: 1.0 / 3)))
    }

    @Test("版 1 は版 2 に読み替わり、映る点が変わらない")
    func version1_migrates_without_changing_the_picture() throws {
        let corners: [[String: Double]] = [
            ["x": 0.12, "y": 0.08], ["x": 0.91, "y": 0.15], ["x": 0.86, "y": 0.93], ["x": 0.07, "y": 0.88],
        ]
        let region: [String: Any] = [
            "name": "wall", "stream": "main", "corners": corners,
            "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
        ]
        let second: [String: Any] = [
            "name": "floor", "stream": "syphon:App/floor", "corners": corners,
            "rect": ["x": 0, "y": 0, "width": 1, "height": 1],
        ]
        let v1: [String: Any] = [
            "schemaVersion": 1, "channel": "show",
            "outputs": [
                ["display": ["name": "EPSON PJ", "id": 3], "regions": [region]],
                ["display": ["name": "NEC PJ", "id": 4], "regions": [second]],
            ],
        ]
        let config = try MappingConfig.decode(JSONSerialization.data(withJSONObject: v1))
        #expect(config.schemaVersion == 2)
        #expect(config.channel == "show")
        #expect(config.layers.map(\.surface?.stream) == ["main", "syphon:App/floor"])

        // 版 1 では、領域の点 p に映像の点 H⁻¹(p) が映っていた
        let old = try #require(Homography(corners: corners.map { Point(x: $0["x"]!, y: $0["y"]!) }))
        for (output, layer) in zip(config.outputs, config.layers) {
            let surface = try #require(layer.surface)
            let mapping = try #require(MappingConfig.mapping(surface: surface, region: output.regions[0]))
            for p in [Point(x: 0.5, y: 0.5), Point(x: 0.2, y: 0.3), Point(x: 0.8, y: 0.85)] {
                let back = old.inverse * SIMD3(p.x, p.y, 1)
                #expect(close(mapping.inputPoint(atRegion: p), Point(x: back.x / back.z, y: back.y / back.z)))
            }
            // 4 隅の外は、版 1 と同じく映らない
            #expect(mapping.inputPoint(atRegion: Point(x: 0.02, y: 0.02)) == nil)
        }
        // 2 台は重ならずに並ぶ
        #expect(config.stageBounds == .init(x: 0, y: 0, width: 3840, height: 1080))
    }

    @Test("知らない版は読まない")
    func unknown_version_is_rejected() throws {
        var config = MappingConfig()
        config.schemaVersion = 3
        #expect(throws: MappingConfig.LoadError.unsupportedVersion(3)) {
            try MappingConfig.decode(config.encode())
        }
    }

    @Test("台形補正の 4 隅が四角形を成さない領域があれば読まない")
    func invalid_keystone_is_rejected() throws {
        var region = MappingConfig.Region(name: "broken")
        region.keystone[1] = Point(x: 1, y: 1)
        region.keystone[2] = Point(x: 1, y: 0)
        let config = MappingConfig(outputs: [.init(display: display(1), regions: [region])])
        #expect(throws: MappingConfig.LoadError.invalidCorners(region: "broken")) {
            try MappingConfig.decode(config.encode())
        }
    }

    @Test("受け持つ範囲の幅が 0 の領域は読まない")
    func empty_placement_is_rejected() throws {
        let region = MappingConfig.Region(name: "flat", placement: .init(x: 0, y: 0, width: 0, height: 1080))
        let config = MappingConfig(outputs: [.init(display: display(1), regions: [region])])
        #expect(throws: MappingConfig.LoadError.invalidPlacement(region: "flat")) {
            try MappingConfig.decode(config.encode())
        }
    }

    @Test("切り取りか置く先が四角形を成さない面は読まない")
    func invalid_surface_is_rejected() throws {
        var folded = MappingConfig.Surface(name: "folded", covering: .init(x: 0, y: 0, width: 100, height: 100))
        folded.input = [Point(x: 0, y: 0), Point(x: 1, y: 1), Point(x: 1, y: 0), Point(x: 0, y: 1)]
        #expect(throws: MappingConfig.LoadError.invalidSurface(name: "folded")) {
            try MappingConfig.decode(MappingConfig(layers: [.surface(folded)]).encode())
        }
        let flat = MappingConfig.Surface(name: "flat", covering: .init(x: 0, y: 0, width: 100, height: 0))
        #expect(throws: MappingConfig.LoadError.invalidSurface(name: "flat")) {
            try MappingConfig.decode(MappingConfig(layers: [.surface(flat)]).encode())
        }
    }

    @Test("頂点が 3 つ未満のマスクは読まず、3 つあれば読む")
    func mask_needs_three_points() throws {
        let line = MappingConfig.Mask(name: "line", points: [Point(x: 0, y: 0), Point(x: 10, y: 10)])
        #expect(throws: MappingConfig.LoadError.invalidMask(name: "line")) {
            try MappingConfig.decode(MappingConfig(layers: [.mask(line)]).encode())
        }
        var triangle = line
        triangle.points.append(Point(x: 0, y: 10))
        triangle.inverted = true
        let config = MappingConfig(layers: [.mask(triangle)])
        #expect(try MappingConfig.decode(config.encode()) == config)
    }

    @Test("面の隅と切り取りの隅を動かせ、裏返る動きは採らない")
    func surface_corners_move_and_reject_folding() throws {
        let surface = MappingConfig.Surface(name: "s", covering: .init(x: 0, y: 0, width: 100, height: 100))
        let moved = try #require(surface.movingCorner(2, to: Point(x: 120, y: 90)))
        #expect(moved.corners[2] == Point(x: 120, y: 90))
        #expect(surface.movingCorner(2, to: Point(x: -50, y: -50)) == nil)
        let cropped = try #require(surface.movingInputCorner(0, to: Point(x: 0.2, y: 0.1)))
        #expect(cropped.input[0] == Point(x: 0.2, y: 0.1))
        #expect(surface.movingInputCorner(0, to: Point(x: 1, y: 1)) == nil)
    }
}
