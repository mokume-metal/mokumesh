// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeshMapping

/// ビューが送る意図。文書の変更 (`EditorDocument.perform`) と選択の更新を組み合わせる。
///
/// 階層・inspector・メニュー・各ペインは同じ意図をここから呼ぶので、同じ操作がどこから来ても
/// 同じ結果になる。新しい操作はここに足す。
extension EditorSession {
    // MARK: - 面

    /// 面を 1 枚足す。選んでいる層の真上 (無ければ一番上) に、ステージの外形を覆う形で置き、選ぶ。
    @discardableResult
    public func addSurface() -> MappingConfig.LayerID? {
        let config = document.config
        let surface = MappingConfig.Surface(
            name: config.unusedLayerName("面"), stream: inputStream ?? "main", covering: config.stageExtent)
        let index = HierarchyOrder.insertionIndex(in: config, above: selection.layers)
        guard document.perform("面を足す", { $0.insertLayer(.surface(surface), at: index) }) else { return nil }
        selection.select(.layer(surface.id))
        return surface.id
    }

    /// 消せるものを選んでいるか (層・出力)。
    public var canDeleteSelection: Bool {
        selection.items.contains {
            switch $0 {
            case .layer, .output: true
            case .region, .input: false
            }
        }
    }

    /// 選んでいる層と出力を消す。
    public func deleteSelection() {
        let layers = selection.layers
        let outputs = Set(selection.items.compactMap { if case .output(let id) = $0 { id } else { nil } })
        guard !layers.isEmpty || !outputs.isEmpty else { return }
        let name = outputs.isEmpty ? "面を消す" : (layers.isEmpty ? "出力を消す" : "消す")
        document.perform(name) {
            $0.removeLayers(layers)
            $0.removeOutputs(outputs)
        }
    }

    public func renameLayer(_ id: MappingConfig.LayerID, to name: String) {
        document.perform("名前を変える") { $0.renameLayer(id, to: name) }
    }

    /// 階層の並び (上の層が先) での並べ替え。
    public func moveLayers(displayOffsets: IndexSet, toDisplayOffset destination: Int) {
        document.perform("並べ替える") {
            HierarchyOrder.move(&$0, displayOffsets: displayOffsets, toDisplayOffset: destination)
        }
    }

    public func setStream(_ stream: String, for layer: MappingConfig.LayerID) {
        document.perform("映像を変える") { $0.updateSurface(layer) { $0.stream = stream } }
    }

    public func setVisible(_ visible: Bool, for layer: MappingConfig.LayerID) {
        document.perform(visible ? "見せる" : "隠す") {
            $0.updateLayer(layer) { layer in
                switch layer {
                case .surface(var surface):
                    surface.visible = visible
                    layer = .surface(surface)
                case .mask(var mask):
                    mask.visible = visible
                    layer = .mask(mask)
                }
            }
        }
    }

    // MARK: - 出力と領域

    /// 出力を足して選ぶ。表示装置を渡せばその全体を 1 台のプロジェクタにし、渡さなければ
    /// 表示装置の無い 1920×1080 の出力にする (窓で確かめる)。
    @discardableResult
    public func addOutput(display: DisplayInfo?) -> MappingConfig.OutputID? {
        let config = document.config
        let reference: MappingConfig.DisplayReference
        let size: (width: Double, height: Double)
        if let display {
            reference = display.reference
            size = (display.pixelWidth, display.pixelHeight)
        } else {
            let names = Set(config.outputs.map(\.display.name))
            var number = config.outputs.count + 1
            while names.contains("出力 \(number)") { number += 1 }
            // 識別子 0 はどの表示装置にも当たらない
            reference = .init(name: "出力 \(number)", id: 0)
            size = (1920, 1080)
        }
        var added: MappingConfig.OutputID?
        let surfaceName = config.unusedLayerName("面")
        let stream = inputStream ?? "main"
        document.perform("出力を足す") {
            added = $0.appendOutput(
                display: reference, regionName: reference.name, size: size, stream: stream, surfaceName: surfaceName)
        }
        if let added { selection.select(.output(added)) }
        return added
    }

    /// 全画面に出す先の表示装置を選び直す (設定の参照を変える)。
    public func setDisplay(_ display: DisplayInfo, for output: MappingConfig.OutputID) {
        document.perform("表示装置を変える") { $0.updateOutput(output) { $0.display = display.reference } }
    }

    public func renameRegion(_ id: MappingConfig.RegionID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        document.perform("名前を変える") { $0.updateRegion(id) { $0.name = trimmed } }
    }

    /// 領域の台形補正を外す。
    public func resetKeystone(_ id: MappingConfig.RegionID) {
        document.perform("台形補正を戻す") { $0.updateRegion(id) { $0.keystone = MappingConfig.Quad.unit } }
    }

    /// 出力の窓の上で、台形補正の隅を動かす。続けて動かすときは `document.beginGesture` で挟む。
    public func moveKeystoneCorner(_ id: MappingConfig.RegionID, corner: Int, to point: Point) {
        document.perform("台形補正を動かす") { config in
            config.updateRegion(id) { region in
                if let moved = region.movingCorner(corner, to: point) { region = moved }
            }
        }
    }
}
