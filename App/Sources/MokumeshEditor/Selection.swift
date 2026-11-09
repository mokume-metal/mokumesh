// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshMapping

/// 階層とペインで選べるもの 1 つ。設定の中のものは ID で指す (ADR-0003 決定 3)。
public enum ItemID: Hashable, Sendable {
    /// 映像 (名前)。設定には無く、届いているものか面が使っているもの。
    case input(String)
    case layer(MappingConfig.LayerID)
    case output(MappingConfig.OutputID)
    case region(MappingConfig.RegionID)
}

/// 選んでいるもの。全ペインと inspector がこれ 1 つを見る。
///
/// 複数を持てるが、inspector が詳しく出すのは 1 つのとき (`single`) だけである。
public struct Selection: Equatable, Sendable {
    public private(set) var items: Set<ItemID> = []
    /// 最後に選んだもの。複数のうち、ペインが前に出すもの。
    public private(set) var primary: ItemID?

    public init() {}

    public init(_ item: ItemID) {
        items = [item]
        primary = item
    }

    /// 1 つだけ選んでいれば、それ。
    public var single: ItemID? { items.count == 1 ? items.first : nil }

    public var isEmpty: Bool { items.isEmpty }

    public func contains(_ item: ItemID) -> Bool { items.contains(item) }

    /// 選んでいる層。
    public var layers: Set<MappingConfig.LayerID> {
        Set(items.compactMap { if case .layer(let id) = $0 { id } else { nil } })
    }

    /// 選び直す。`primary` は渡したものに含まれていればそれ、無ければ `items` から 1 つ。
    public mutating func set(_ items: Set<ItemID>, primary: ItemID? = nil) {
        self.items = items
        if let primary, items.contains(primary) {
            self.primary = primary
        } else if let current = self.primary, items.contains(current) {
            // そのまま
        } else {
            self.primary = items.first
        }
    }

    public mutating func select(_ item: ItemID) { set([item], primary: item) }

    public mutating func clear() { set([]) }

    /// 設定から消えたものを外す。映像は一瞬届かなくなることがある (Syphon の送り手の
    /// 再起動など) ので外さない。
    public func pruned(against config: MappingConfig) -> Selection {
        var copy = self
        copy.set(
            items.filter { item in
                switch item {
                case .input: true
                case .layer(let id): config.layer(id) != nil
                case .output(let id): config.output(id) != nil
                case .region(let id): config.region(id) != nil
                }
            })
        return copy
    }
}
