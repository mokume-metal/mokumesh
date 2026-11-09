// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 設定への編集の操作。GUI はこれらを組み合わせて設定を変える (ADR-0003 決定 4)。
///
/// どれも ID で指し、添字は外に出さない。並べ替えや削除の後でも、同じ ID は同じものを指す。
/// 見つからない ID は何もしない (`false` を返す)。
extension MappingConfig {
    // MARK: - 引く

    public func layerIndex(_ id: LayerID) -> Int? {
        layers.firstIndex { $0.id == id }
    }

    public func layer(_ id: LayerID) -> Layer? {
        layerIndex(id).map { layers[$0] }
    }

    public func outputIndex(_ id: OutputID) -> Int? {
        outputs.firstIndex { $0.id == id }
    }

    public func output(_ id: OutputID) -> Output? {
        outputIndex(id).map { outputs[$0] }
    }

    /// 領域の居場所 (出力の添字と、その中の添字)。
    public func regionLocation(_ id: RegionID) -> (output: Int, region: Int)? {
        for (outputIndex, output) in outputs.enumerated() {
            if let regionIndex = output.regions.firstIndex(where: { $0.id == id }) {
                return (outputIndex, regionIndex)
            }
        }
        return nil
    }

    public func region(_ id: RegionID) -> Region? {
        regionLocation(id).map { outputs[$0.output].regions[$0.region] }
    }

    /// 領域を持つ出力。
    public func outputID(containing region: RegionID) -> OutputID? {
        regionLocation(region).map { outputs[$0.output].id }
    }

    /// 面が使う映像 (見せていない面も含め、重ならないよう並びの順で)。
    public var streamsInUse: [String] {
        var seen = Set<String>()
        return layers.compactMap { $0.surface?.stream }.filter { seen.insert($0).inserted }
    }

    // MARK: - 層

    /// 層を差し込む。`index` を省くと一番上 (並びの末尾) に置く。
    public mutating func insertLayer(_ layer: Layer, at index: Int? = nil) {
        let index = min(max(index ?? layers.count, 0), layers.count)
        layers.insert(layer, at: index)
    }

    /// 層を消す。消したものの数を返す。
    @discardableResult
    public mutating func removeLayers(_ ids: Set<LayerID>) -> Int {
        let before = layers.count
        layers.removeAll { ids.contains($0.id) }
        return before - layers.count
    }

    /// 層を並べ替える。`source` の層を、元の並びで `destination` の前の位置へ動かす
    /// (`destination` が `layers.count` なら一番上)。動かした層どうしの順は保つ。
    public mutating func moveLayers(_ source: Set<LayerID>, before destination: Int) {
        let destination = min(max(destination, 0), layers.count)
        let moving = layers.filter { source.contains($0.id) }
        guard !moving.isEmpty else { return }
        // 差し込む先は、動かさない層のうち destination より前にあったものの数
        let insertion = layers[..<destination].filter { !source.contains($0.id) }.count
        var remaining = layers.filter { !source.contains($0.id) }
        remaining.insert(contentsOf: moving, at: insertion)
        layers = remaining
    }

    /// 層を 1 つ書き換える。見つからなければ `false`。
    @discardableResult
    public mutating func updateLayer(_ id: LayerID, _ body: (inout Layer) -> Void) -> Bool {
        guard let index = layerIndex(id) else { return false }
        body(&layers[index])
        return true
    }

    /// 面を 1 つ書き換える。見つからない・面でなければ `false`。
    @discardableResult
    public mutating func updateSurface(_ id: LayerID, _ body: (inout Surface) -> Void) -> Bool {
        guard let index = layerIndex(id), case .surface(var surface) = layers[index] else { return false }
        body(&surface)
        layers[index] = .surface(surface)
        return true
    }

    /// 層の名前を変える。前後の空白を落とし、空になる名前は採らない。
    @discardableResult
    public mutating func renameLayer(_ id: LayerID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return updateLayer(id) { $0.name = trimmed }
    }

    /// `base` に番号を付けた、まだ層に無い名前 (`面 1`・`面 2`…)。
    public func unusedLayerName(_ base: String) -> String {
        let names = Set(layers.map(\.name))
        var number = 1
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }

    // MARK: - 出力と領域

    /// 出力を書き換える。見つからなければ `false`。
    @discardableResult
    public mutating func updateOutput(_ id: OutputID, _ body: (inout Output) -> Void) -> Bool {
        guard let index = outputIndex(id) else { return false }
        body(&outputs[index])
        return true
    }

    /// 領域を書き換える。見つからなければ `false`。
    @discardableResult
    public mutating func updateRegion(_ id: RegionID, _ body: (inout Region) -> Void) -> Bool {
        guard let location = regionLocation(id) else { return false }
        body(&outputs[location.output].regions[location.region])
        return true
    }

    /// 出力を消す。消したものの数を返す。
    @discardableResult
    public mutating func removeOutputs(_ ids: Set<OutputID>) -> Int {
        let before = outputs.count
        outputs.removeAll { ids.contains($0.id) }
        return before - outputs.count
    }

    /// ステージの右端に、`size` の画素の範囲を受け持つ領域 1 つの出力を足す。
    /// 面が 1 枚も無ければ、その範囲を覆う面も置く (足してすぐ何かが映るように)。
    ///
    /// - Returns: 足した出力の ID。
    @discardableResult
    public mutating func appendOutput(
        display: DisplayReference, regionName: String, size: (width: Double, height: Double),
        stream: String, surfaceName: String
    ) -> OutputID {
        let placement = Rect(x: stageBounds?.maxX ?? 0, y: 0, width: size.width, height: size.height)
        let output = Output(display: display, regions: [Region(name: regionName, placement: placement)])
        outputs.append(output)
        if !layers.contains(where: { $0.surface != nil }) {
            insertLayer(.surface(Surface(name: surfaceName, stream: stream, covering: placement)))
        }
        return output.id
    }
}
