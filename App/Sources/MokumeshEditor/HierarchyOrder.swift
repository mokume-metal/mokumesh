// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeshMapping

/// 階層の「面」の節の並び。
///
/// 設定の `layers` は描く順 (先が下) だが、階層は Photoshop や Unity と同じく上に重なる層を
/// 先に見せる。表示の並びと設定の並びの変換をここ 1 か所に置き、並べ替えの取り違えを防ぐ。
public enum HierarchyOrder {
    /// 階層に見せる順 (上の層が先)。
    public static func displayed(_ layers: [MappingConfig.Layer]) -> [MappingConfig.Layer] {
        layers.reversed()
    }

    /// 階層での並べ替え (SwiftUI の `onMove` の引数: 表示の並びの添字と、差し込む先の表示の添字)
    /// を、設定の並べ替えに直す。
    public static func move(
        _ config: inout MappingConfig, displayOffsets: IndexSet, toDisplayOffset destination: Int
    ) {
        let displayed = displayed(config.layers)
        let ids = Set(displayOffsets.compactMap { displayed.indices.contains($0) ? displayed[$0].id : nil })
        // 表示の d 番目の前 = その層の真上 = 設定では (count - d) 番目の前
        config.moveLayers(ids, before: config.layers.count - min(max(destination, 0), displayed.count))
    }

    /// 新しい層を差し込む設定の添字。選んでいる層があればその真上 (一番上のもの)、無ければ一番上。
    public static func insertionIndex(in config: MappingConfig, above selected: Set<MappingConfig.LayerID>) -> Int {
        let indices = selected.compactMap(config.layerIndex)
        return (indices.max().map { $0 + 1 }) ?? config.layers.count
    }
}
