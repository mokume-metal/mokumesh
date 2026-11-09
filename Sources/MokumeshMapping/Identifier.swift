// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

extension MappingConfig {
    /// 設定の中の 1 つを、並べ替えても変わらずに指す名札 (ADR-0003 決定 3)。
    ///
    /// 種類 (`Kind`) で型を分け、層の ID を領域の ID として渡すような取り違えをコンパイラに止めさせる。
    /// JSON には文字列 1 つで書く。
    public struct Identifier<Kind>: Hashable, Sendable, Codable, CustomStringConvertible {
        public var rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        /// 重ならない新しい ID。GUI で新しく作るものに振る。
        public static func unique() -> Self { Self(UUID().uuidString) }

        public var description: String { rawValue }

        public init(from decoder: any Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }

    public enum LayerKind {}
    public enum OutputKind {}
    public enum RegionKind {}

    /// 層 (面かマスク) の ID。
    public typealias LayerID = Identifier<LayerKind>
    /// 出力 (表示装置 1 つ) の ID。
    public typealias OutputID = Identifier<OutputKind>
    /// 領域 (プロジェクタ 1 台) の ID。
    public typealias RegionID = Identifier<RegionKind>
}

extension MappingConfig {
    /// 書かれていなかった ID (空の文字列) を、決定的に振る。
    ///
    /// 同じファイルを読めば同じ ID になるよう乱数は使わず、`layer-1` のように既にある ID と
    /// 重ならない番号を振る。手で書いた設定や、版 1 から読み替えた設定がここを通る。
    mutating func assignMissingIdentifiers() {
        func fill<Kind>(_ ids: [Identifier<Kind>], prefix: String) -> [Identifier<Kind>] {
            var used = Set(ids.map(\.rawValue).filter { !$0.isEmpty })
            var next = 1
            return ids.map { id in
                guard id.rawValue.isEmpty else { return id }
                while used.contains("\(prefix)-\(next)") { next += 1 }
                let assigned = "\(prefix)-\(next)"
                used.insert(assigned)
                return Identifier(assigned)
            }
        }
        let layerIDs = fill(layers.map(\.id), prefix: "layer")
        for index in layers.indices { layers[index].id = layerIDs[index] }
        let outputIDs = fill(outputs.map(\.id), prefix: "output")
        for index in outputs.indices { outputs[index].id = outputIDs[index] }
        var regionIDs = fill(outputs.flatMap { $0.regions.map(\.id) }, prefix: "region")[...]
        for output in outputs.indices {
            for region in outputs[output].regions.indices {
                outputs[output].regions[region].id = regionIDs.removeFirst()
            }
        }
    }

    /// 同じ ID が 2 度出てくれば、その ID を返す。
    func firstDuplicateIdentifier() -> String? {
        func duplicate(_ values: [String]) -> String? {
            var seen = Set<String>()
            return values.first { !seen.insert($0).inserted }
        }
        return duplicate(layers.map(\.id.rawValue))
            ?? duplicate(outputs.map(\.id.rawValue))
            ?? duplicate(outputs.flatMap { $0.regions.map(\.id.rawValue) })
    }
}
