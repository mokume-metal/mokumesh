// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import simd

/// mokumesh の設定。較正の結果をここに持ち、JSON に書いて読み戻す。
///
/// 形は ADR-0002 の「ステージ・層・プロジェクタの配置」である。
///
/// - **ステージ**: 面を置く共通の平面。座標は画素で、外形は保存せず、領域の配置
///   (`Region.placement`) の外接矩形として求める (`stageBounds`)
/// - **層** (`layers`): ステージに置く面とマスク。並びが描く順 (先が下)
/// - **出力** (`outputs`): 「表示装置 → 領域 (=プロジェクタ)」の 2 段 (ADR-0001 決定 6)。
///   領域はステージの `placement` の範囲を、`keystone` で台形補正して映す
///
/// 形式の正典は `Schemas/mapping.schema.json`。版 1 は読むときに版 2 へ読み替える。
public struct MappingConfig: Codable, Equatable, Sendable {
    /// 形式の版。形を変えたら上げる。
    public static let currentVersion = 2

    public var schemaVersion: Int
    /// 受け手のチャンネル。
    public var channel: String
    /// ステージに置く面とマスク。先のものが下になる。
    public var layers: [Layer]
    public var outputs: [Output]

    public init(channel: String = "default", layers: [Layer] = [], outputs: [Output] = []) {
        schemaVersion = Self.currentVersion
        self.channel = channel
        self.layers = layers
        self.outputs = outputs
    }

    // MARK: - 層

    /// ステージに置く 1 層。面かマスク。
    public enum Layer: Codable, Equatable, Sendable {
        case surface(Surface)
        case mask(Mask)

        public var name: String {
            get {
                switch self {
                case .surface(let surface): surface.name
                case .mask(let mask): mask.name
                }
            }
            set {
                switch self {
                case .surface(var surface):
                    surface.name = newValue
                    self = .surface(surface)
                case .mask(var mask):
                    mask.name = newValue
                    self = .mask(mask)
                }
            }
        }

        public var id: LayerID {
            get {
                switch self {
                case .surface(let surface): surface.id
                case .mask(let mask): mask.id
                }
            }
            set {
                switch self {
                case .surface(var surface):
                    surface.id = newValue
                    self = .surface(surface)
                case .mask(var mask):
                    mask.id = newValue
                    self = .mask(mask)
                }
            }
        }

        public var surface: Surface? {
            if case .surface(let surface) = self { surface } else { nil }
        }

        public var mask: Mask? {
            if case .mask(let mask) = self { mask } else { nil }
        }

        private enum CodingKeys: String, CodingKey { case kind }
        private enum Kind: String, Codable { case surface, mask }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            switch try container.decode(Kind.self, forKey: .kind) {
            case .surface: self = .surface(try Surface(from: decoder))
            case .mask: self = .mask(try Mask(from: decoder))
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .surface(let surface):
                try container.encode(Kind.surface, forKey: .kind)
                try surface.encode(to: encoder)
            case .mask(let mask):
                try container.encode(Kind.mask, forKey: .kind)
                try mask.encode(to: encoder)
            }
        }
    }

    /// 面 1 つ。映像の一部 (`input`) を切り取り、ステージの四角形 (`corners`) へ歪めて置く。
    public struct Surface: Codable, Equatable, Sendable {
        public var id: LayerID
        public var name: String
        /// 映す映像の名前。
        public var stream: String
        /// 描くか。
        public var visible: Bool
        /// 切り取る四角形。映像の中で 0〜1 に正規化し、左上・右上・右下・左下の順。
        public var input: [Point]
        /// 置く先の四角形。ステージの画素で、左上・右上・右下・左下の順。
        public var corners: [Point]

        public init(
            id: LayerID = .unique(), name: String, stream: String = "main", visible: Bool = true,
            input: [Point] = Quad.unit, corners: [Point]
        ) {
            self.id = id
            self.name = name
            self.stream = stream
            self.visible = visible
            self.input = input
            self.corners = corners
        }

        /// ステージの矩形をそのまま覆う面。
        public init(id: LayerID = .unique(), name: String, stream: String = "main", covering rect: Rect) {
            self.init(id: id, name: name, stream: stream, corners: Quad.corners(of: rect))
        }

        /// `id` は書かれていなくてよい (読んだあとで `decode` が振る)。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(LayerID.self, forKey: .id) ?? LayerID("")
            name = try container.decode(String.self, forKey: .name)
            stream = try container.decode(String.self, forKey: .stream)
            visible = try container.decode(Bool.self, forKey: .visible)
            input = try container.decode([Point].self, forKey: .input)
            corners = try container.decode([Point].self, forKey: .corners)
        }

        /// 隅を 1 つ動かした面。四角形が裏返る・潰れる・凹むなら `nil`。
        public func movingCorner(_ index: Int, to point: Point) -> Surface? {
            guard let moved = Quad.moving(corners, index, to: point) else { return nil }
            var surface = self
            surface.corners = moved
            return surface
        }

        /// 切り取りの隅を 1 つ動かした面。四角形が裏返る・潰れる・凹むなら `nil`。
        public func movingInputCorner(_ index: Int, to point: Point) -> Surface? {
            guard let moved = Quad.moving(input, index, to: point) else { return nil }
            var surface = self
            surface.input = moved
            return surface
        }
    }

    /// マスク 1 つ。ステージの多角形で、自分より下の層を、外側 (反転なら内側) で覆う。
    ///
    /// 形は版 2 で決めてあり、描くのは後の段である (ADR-0002)。
    public struct Mask: Codable, Equatable, Sendable {
        public var id: LayerID
        public var name: String
        public var visible: Bool
        /// 内側を覆う (外側を残す) か。
        public var inverted: Bool
        /// 多角形の頂点。ステージの画素。3 点以上。
        public var points: [Point]

        public init(
            id: LayerID = .unique(), name: String, visible: Bool = true, inverted: Bool = false, points: [Point]
        ) {
            self.id = id
            self.name = name
            self.visible = visible
            self.inverted = inverted
            self.points = points
        }

        /// `id` は書かれていなくてよい (読んだあとで `decode` が振る)。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(LayerID.self, forKey: .id) ?? LayerID("")
            name = try container.decode(String.self, forKey: .name)
            visible = try container.decode(Bool.self, forKey: .visible)
            inverted = try container.decode(Bool.self, forKey: .inverted)
            points = try container.decode([Point].self, forKey: .points)
        }
    }

    // MARK: - 出力

    /// 表示装置 1 つ。
    public struct Output: Codable, Equatable, Sendable {
        public var id: OutputID
        public var display: DisplayReference
        public var regions: [Region]

        public init(id: OutputID = .unique(), display: DisplayReference, regions: [Region]) {
            self.id = id
            self.display = display
            self.regions = regions
        }

        /// `id` は書かれていなくてよい (読んだあとで `decode` が振る)。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(OutputID.self, forKey: .id) ?? OutputID("")
            display = try container.decode(DisplayReference.self, forKey: .display)
            regions = try container.decode([Region].self, forKey: .regions)
        }
    }

    /// 表示装置を引く手掛かり。
    ///
    /// 識別子 (`CGDirectDisplayID`) は繋ぎ直しや再起動で変わりうるので、名前も持つ。
    /// 引くときは識別子を先に見て、見つからなければ名前で探す。
    public struct DisplayReference: Codable, Equatable, Sendable {
        public var name: String
        public var id: UInt32

        public init(name: String, id: UInt32) {
            self.name = name
            self.id = id
        }
    }

    /// 領域 1 つ = プロジェクタ 1 台。
    public struct Region: Codable, Equatable, Sendable {
        public var id: RegionID
        public var name: String
        /// 表示装置の中の矩形。表示装置の幅と高さで 0〜1 に正規化する (分配器の割り方)。
        public var rect: Rect
        /// このプロジェクタが受け持つステージの範囲。ステージの画素。
        public var placement: Rect
        /// 台形補正。受け持つ範囲の 4 隅 (左上・右上・右下・左下) を写す先で、
        /// 領域の中で 0〜1 に正規化する。
        public var keystone: [Point]

        public init(
            id: RegionID = .unique(), name: String, rect: Rect = .unit,
            placement: Rect = Rect(x: 0, y: 0, width: 1920, height: 1080), keystone: [Point] = Quad.unit
        ) {
            self.id = id
            self.name = name
            self.rect = rect
            self.placement = placement
            self.keystone = keystone
        }

        /// `id` は書かれていなくてよい (読んだあとで `decode` が振る)。
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(RegionID.self, forKey: .id) ?? RegionID("")
            name = try container.decode(String.self, forKey: .name)
            rect = try container.decode(Rect.self, forKey: .rect)
            placement = try container.decode(Rect.self, forKey: .placement)
            keystone = try container.decode([Point].self, forKey: .keystone)
        }

        /// 台形補正の隅を 1 つ動かした領域。四角形が裏返る・潰れる・凹むなら `nil` (動かさない)。
        ///
        /// 較正の GUI はドラッグのたびにこれを通す。四角形を成さない 4 隅は射影変換を
        /// 作れず、映せなくなるためである。
        public func movingCorner(_ index: Int, to point: Point) -> Region? {
            guard let moved = Quad.moving(keystone, index, to: point) else { return nil }
            var region = self
            region.keystone = moved
            return region
        }

        /// 領域の中の位置 (0〜1) を、ステージの画素へ写す行列 (同次座標)。
        /// 台形補正の外 (受け持つ範囲の外) は、写した先が `placement` の外になる。
        public var regionToStage: simd_double3x3? {
            guard let keystone = Homography(corners: keystone) else { return nil }
            return placement.fromUnit * keystone.inverse
        }
    }

    /// 矩形。単位は使う場所で決まる (`Region.rect` は 0〜1、`Region.placement` は画素)。
    public struct Rect: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        public static let unit = Rect(x: 0, y: 0, width: 1, height: 1)

        public var maxX: Double { x + width }
        public var maxY: Double { y + height }

        /// 2 つを覆う最小の矩形。
        public func union(_ other: Rect) -> Rect {
            let minX = min(x, other.x), minY = min(y, other.y)
            return Rect(x: minX, y: minY, width: max(maxX, other.maxX) - minX, height: max(maxY, other.maxY) - minY)
        }

        /// 単位正方形をこの矩形へ写す行列 (同次座標)。
        public var fromUnit: simd_double3x3 {
            simd_double3x3(columns: (SIMD3(width, 0, 0), SIMD3(0, height, 0), SIMD3(x, y, 1)))
        }
    }

    /// 4 隅の扱い。並びは左上・右上・右下・左下。
    public enum Quad {
        /// 歪めない 4 隅 (単位正方形)。
        public static let unit = [
            Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1), Point(x: 0, y: 1),
        ]

        public static func corners(of rect: Rect) -> [Point] {
            [
                Point(x: rect.x, y: rect.y), Point(x: rect.maxX, y: rect.y),
                Point(x: rect.maxX, y: rect.maxY), Point(x: rect.x, y: rect.maxY),
            ]
        }

        /// 隅を 1 つ動かした 4 隅。四角形が裏返る・潰れる・凹むなら `nil`。
        public static func moving(_ corners: [Point], _ index: Int, to point: Point) -> [Point]? {
            guard corners.indices.contains(index) else { return nil }
            var moved = corners
            moved[index] = point
            return Homography.isConvex(moved) ? moved : nil
        }
    }

    // MARK: - ステージ

    /// ステージの外形。全領域の受け持つ範囲の外接矩形。領域が無ければ `nil`。
    public var stageBounds: Rect? {
        let placements = outputs.flatMap { $0.regions.map(\.placement) }
        guard let first = placements.first else { return nil }
        return placements.dropFirst().reduce(first) { $0.union($1) }
    }

    /// 領域の中の位置から、面の切り取りの位置 (映像の中で 0〜1) へ写す行列を作る。
    public struct SurfaceMapping: Equatable, Sendable {
        /// 領域の中の位置 → 台形補正を外した、受け持つ範囲の中の位置 (0〜1)。外なら映さない。
        public var regionToPlacement: simd_double3x3
        /// 領域の中の位置 → 面の中の位置 (0〜1)。外なら描かない。
        public var regionToSurface: simd_double3x3
        /// 面の中の位置 → 映像の中の位置 (0〜1)。
        public var surfaceToInput: simd_double3x3

        /// 領域の中の位置 (0〜1) を写した先の、映像の中の位置。面の外なら `nil`。
        public func inputPoint(atRegion point: Point) -> Point? {
            func project(_ matrix: simd_double3x3, _ p: Point) -> Point {
                let projected = matrix * SIMD3(p.x, p.y, 1)
                return Point(x: projected.x / projected.z, y: projected.y / projected.z)
            }
            let inside: (Point) -> Bool = { (-1e-9...1 + 1e-9).contains($0.x) && (-1e-9...1 + 1e-9).contains($0.y) }
            guard inside(project(regionToPlacement, point)) else { return nil }
            let surface = project(regionToSurface, point)
            guard inside(surface) else { return nil }
            return project(surfaceToInput, surface)
        }
    }

    /// 領域に面を描くための行列。4 隅のどれかが四角形を成さなければ `nil`。
    public static func mapping(surface: Surface, region: Region) -> SurfaceMapping? {
        guard let keystone = Homography(corners: region.keystone),
            let placed = Homography(corners: surface.corners),
            let input = Homography(corners: surface.input)
        else { return nil }
        let regionToPlacement = keystone.inverse
        return SurfaceMapping(
            regionToPlacement: regionToPlacement,
            regionToSurface: placed.inverse * region.placement.fromUnit * regionToPlacement,
            surfaceToInput: input.matrix)
    }

    // MARK: - 読み書き

    public enum LoadError: Error, Equatable {
        /// 知らない版。
        case unsupportedVersion(Int)
        /// 台形補正の 4 隅が四角形を成さない領域がある。
        case invalidCorners(region: String)
        /// 受け持つ範囲の幅か高さが 0 以下の領域がある。
        case invalidPlacement(region: String)
        /// 切り取りか置く先の 4 隅が四角形を成さない面がある。
        case invalidSurface(name: String)
        /// 頂点が 3 つ未満のマスクがある。
        case invalidMask(name: String)
        /// 同じ ID が 2 度出てくる (層どうし・出力どうし・領域どうし)。
        case duplicateID(String)
    }

    /// JSON から読む。版 1 は版 2 へ読み替える。書かれていない ID を振り、4 隅・範囲・マスク・
    /// ID の重なりを確かめる。
    public static func decode(_ data: Data) throws -> MappingConfig {
        struct Version: Decodable { var schemaVersion: Int }
        let version = try JSONDecoder().decode(Version.self, from: data).schemaVersion
        var config: MappingConfig
        switch version {
        case 1: config = try JSONDecoder().decode(Version1.self, from: data).migrated()
        case currentVersion: config = try JSONDecoder().decode(MappingConfig.self, from: data)
        default: throw LoadError.unsupportedVersion(version)
        }
        // 重なりは、書かれていたものどうしで先に見る (振った ID は書かれたものと重ならない)
        config.assignMissingIdentifiers()
        try config.validate()
        return config
    }

    /// 映せない形と、ID の重なりを断る。
    public func validate() throws {
        if let duplicate = firstDuplicateIdentifier() { throw LoadError.duplicateID(duplicate) }
        for output in outputs {
            for region in output.regions {
                guard region.placement.width > 0, region.placement.height > 0 else {
                    throw LoadError.invalidPlacement(region: region.name)
                }
                guard Homography(corners: region.keystone) != nil else {
                    throw LoadError.invalidCorners(region: region.name)
                }
            }
        }
        for layer in layers {
            switch layer {
            case .surface(let surface):
                guard Homography(corners: surface.input) != nil, Homography(corners: surface.corners) != nil else {
                    throw LoadError.invalidSurface(name: surface.name)
                }
            case .mask(let mask):
                guard mask.points.count >= 3 else { throw LoadError.invalidMask(name: mask.name) }
            }
        }
    }

    /// JSON に書く。差分を読めるよう、鍵を並べ、字下げする。
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    // MARK: - 版 1

    /// 版 1 の形 (「表示装置 → 領域 → 映像と 4 隅」)。読むときだけ使う。
    struct Version1: Decodable {
        struct Output: Decodable {
            var display: DisplayReference
            var regions: [Region]
        }
        struct Region: Decodable {
            var name: String
            var rect: Rect
            var stream: String
            var corners: [Point]
        }
        var channel: String
        var outputs: [Output]

        /// 映る絵を変えずに版 2 へ。
        ///
        /// 版 1 の領域は、映像 1 本の全体を 4 隅へ写していた。これは版 2 の言葉では
        /// 「受け持つ範囲を覆う面 1 枚と、4 隅を台形補正にした領域」である。領域ごとに
        /// 1920×1080 の範囲を横に並べ、範囲ごとに面を 1 枚置く。
        func migrated() -> MappingConfig {
            let size = (width: 1920.0, height: 1080.0)
            var layers: [Layer] = []
            var index = 0
            let outputs = outputs.enumerated().map { number, output in
                MappingConfig.Output(
                    id: OutputID("output-\(number + 1)"), display: output.display,
                    regions: output.regions.map { old in
                        let placement = Rect(
                            x: Double(index) * size.width, y: 0, width: size.width, height: size.height)
                        index += 1
                        layers.append(
                            .surface(
                                Surface(
                                    id: LayerID("layer-\(index)"), name: old.name, stream: old.stream,
                                    covering: placement)))
                        return MappingConfig.Region(
                            id: RegionID("region-\(index)"), name: old.name, rect: old.rect, placement: placement,
                            keystone: old.corners)
                    })
            }
            return MappingConfig(channel: channel, layers: layers, outputs: outputs)
        }
    }
}
