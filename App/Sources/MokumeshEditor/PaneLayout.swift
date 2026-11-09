// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshMapping

/// 操作窓の中央に並べるペイン。
public enum PaneKind: String, CaseIterable, Hashable, Sendable, Identifiable {
    case input
    case stage
    case projectors
    case output

    public var id: Self { self }

    public var title: String {
        switch self {
        case .input: "入力"
        case .stage: "ステージ"
        case .projectors: "プロジェクタ配置"
        case .output: "出力"
        }
    }
}

/// 中央の 2×2 のペインの配置。比率・最大化・畳みを持ち、ペインの枠を純粋に求める。
///
/// 列は左 (入力 / プロジェクタ配置) と右 (ステージ / 出力) で、上の列から下の列へ流れる
/// (入力を切り取り → ステージに置き / 台を並べ → 出力に映る)。行の比率は列ごとに持つので、
/// 片方の列だけ畳める。
public struct PaneLayout: Equatable, Sendable {
    /// 列ごとの上と下のペイン。
    public static let columns: [[PaneKind]] = [[.input, .projectors], [.stage, .output]]

    /// 左の列の幅の割合。
    public var columnSplit: Double = 0.5
    /// 列ごとの、上のペインの高さの割合。
    public var rowSplits: [Double] = [0.5, 0.5]
    /// 1 つを窓いっぱいに広げているとき、そのペイン。
    public var maximized: PaneKind?
    /// 見出しだけに畳んだペイン。
    public var collapsed: Set<PaneKind> = []

    /// 寸法の決まり (point)。
    public struct Metrics: Equatable, Sendable {
        public var header: Double
        public var divider: Double
        /// 畳んでいないペインの、見出しを含めた最小の高さと幅。
        public var minimum: Double

        public init(header: Double = 26, divider: Double = 1, minimum: Double = 120) {
            self.header = header
            self.divider = divider
            self.minimum = minimum
        }
    }

    public init() {}

    // MARK: - 枠

    /// ペインごとの枠 (ペインの集まりの左上が原点)。最大化しているときは、そのペインだけを返す。
    public func frames(width: Double, height: Double, metrics: Metrics = .init()) -> [PaneKind: MappingConfig.Rect] {
        if let maximized { return [maximized: .init(x: 0, y: 0, width: width, height: height)] }
        let left = columnWidth(width: width, metrics: metrics)
        let right = max(width - left - metrics.divider, 0)
        var frames: [PaneKind: MappingConfig.Rect] = [:]
        for (column, panes) in Self.columns.enumerated() {
            let x = column == 0 ? 0 : left + metrics.divider
            let columnWidth = column == 0 ? left : right
            let top = topHeight(column: column, height: height, metrics: metrics)
            frames[panes[0]] = .init(x: x, y: 0, width: columnWidth, height: top)
            let bottomY = top + metrics.divider
            let bottom = collapsed.contains(panes[1]) ? min(metrics.header, max(height - bottomY, 0)) : max(height - bottomY, 0)
            frames[panes[1]] = .init(x: x, y: bottomY, width: columnWidth, height: bottom)
        }
        return frames
    }

    /// 左の列の幅 (point)。両方の列が最小の幅を割らないよう寄せる。
    public func columnWidth(width: Double, metrics: Metrics = .init()) -> Double {
        clamp(width * columnSplit, lower: metrics.minimum, upper: width - metrics.divider - metrics.minimum)
    }

    /// 列の上のペインの高さ (point)。畳んだペインは見出しの高さになる。
    public func topHeight(column: Int, height: Double, metrics: Metrics = .init()) -> Double {
        let panes = Self.columns[column]
        let available = height - metrics.divider
        switch (collapsed.contains(panes[0]), collapsed.contains(panes[1])) {
        case (true, _): return min(metrics.header, max(available, 0))
        case (false, true): return max(available - metrics.header, 0)
        case (false, false):
            return clamp(height * rowSplits[column], lower: metrics.minimum, upper: available - metrics.minimum)
        }
    }

    // MARK: - 変える

    /// 列の仕切りを `x` へ動かす。
    public mutating func dragColumnDivider(to x: Double, width: Double, metrics: Metrics = .init()) {
        guard width > 0 else { return }
        columnSplit = clamp(x, lower: metrics.minimum, upper: width - metrics.divider - metrics.minimum) / width
    }

    /// 列の中の仕切りを `y` へ動かす。畳んでいれば開く。
    public mutating func dragRowDivider(column: Int, to y: Double, height: Double, metrics: Metrics = .init()) {
        guard height > 0, Self.columns.indices.contains(column) else { return }
        for pane in Self.columns[column] { collapsed.remove(pane) }
        rowSplits[column] = clamp(y, lower: metrics.minimum, upper: height - metrics.divider - metrics.minimum) / height
    }

    public mutating func toggleMaximized(_ pane: PaneKind) {
        maximized = maximized == pane ? nil : pane
    }

    /// 畳む・開く。同じ列のもう 1 つが畳まれていれば、そちらは開く (列が空にならないように)。
    public mutating func toggleCollapsed(_ pane: PaneKind) {
        if collapsed.contains(pane) {
            collapsed.remove(pane)
            return
        }
        if let column = Self.columns.first(where: { $0.contains(pane) }) {
            for other in column where other != pane { collapsed.remove(other) }
        }
        collapsed.insert(pane)
        if maximized == pane { maximized = nil }
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        // 窓が最小の 2 つ分より狭いときは、半分ずつに寄せる
        guard lower <= upper else { return (lower + upper) / 2 }
        return min(max(value, lower), upper)
    }
}
