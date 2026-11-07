// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// mokumesh の設定。較正の結果をここに持ち、JSON に書いて読み戻す。
///
/// 形は「表示装置 → 領域 → 4 隅」の 2 段である (ADR-0001 決定 6)。分配器で 1 本の出力を
/// 複数台に割るときは、表示装置 1 つに領域を並べる。形式の正典は
/// `Schemas/mapping.schema.json`。
public struct MappingConfig: Codable, Equatable, Sendable {
    /// 形式の版。形を変えたら上げる。
    public static let currentVersion = 1

    public var schemaVersion: Int
    /// 受け手のチャンネル。
    public var channel: String
    public var outputs: [Output]

    public init(channel: String = "default", outputs: [Output] = []) {
        schemaVersion = Self.currentVersion
        self.channel = channel
        self.outputs = outputs
    }

    /// 表示装置 1 つ。
    public struct Output: Codable, Equatable, Sendable {
        public var display: DisplayReference
        public var regions: [Region]

        public init(display: DisplayReference, regions: [Region]) {
            self.display = display
            self.regions = regions
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
        public var name: String
        /// 表示装置の中の矩形。表示装置の幅と高さで 0〜1 に正規化する。
        public var rect: Rect
        /// 映す映像の名前。
        public var stream: String
        /// 絵の 4 隅を写す先。左上・右上・右下・左下の順で、領域の中で 0〜1 に正規化する。
        public var corners: [Point]

        public init(name: String, rect: Rect = .unit, stream: String = "main", corners: [Point] = Region.identity) {
            self.name = name
            self.rect = rect
            self.stream = stream
            self.corners = corners
        }

        /// 歪めない 4 隅。
        public static let identity = [
            Point(x: 0, y: 0), Point(x: 1, y: 0), Point(x: 1, y: 1), Point(x: 0, y: 1),
        ]

        /// 4 隅から作った射影変換。4 隅が四角形を成さなければ `nil`。
        public var homography: Homography? { Homography(corners: corners) }

        /// 隅を 1 つ動かした領域。動かすと四角形が裏返る・潰れる・凹むなら `nil` (動かさない)。
        ///
        /// 較正の GUI はドラッグのたびにこれを通す。四角形を成さない 4 隅は射影変換を
        /// 作れず、映せなくなるためである。
        public func movingCorner(_ index: Int, to point: Point) -> Region? {
            guard corners.indices.contains(index) else { return nil }
            var moved = self
            moved.corners[index] = point
            return Homography.isConvex(moved.corners) ? moved : nil
        }
    }

    /// 0〜1 に正規化した矩形。
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
    }

    // MARK: - 読み書き

    public enum LoadError: Error, Equatable {
        /// 知らない版。
        case unsupportedVersion(Int)
        /// 4 隅が四角形を成さない領域がある。
        case invalidCorners(region: String)
    }

    /// JSON から読む。版と 4 隅を確かめる。
    public static func decode(_ data: Data) throws -> MappingConfig {
        let config = try JSONDecoder().decode(MappingConfig.self, from: data)
        guard config.schemaVersion == currentVersion else {
            throw LoadError.unsupportedVersion(config.schemaVersion)
        }
        for output in config.outputs {
            for region in output.regions where region.homography == nil {
                throw LoadError.invalidCorners(region: region.name)
            }
        }
        return config
    }

    /// JSON に書く。差分を読めるよう、鍵を並べ、字下げする。
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}
