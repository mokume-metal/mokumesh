// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshEditor
import MokumeshMapping
import SwiftUI

/// 階層 (操作窓の左端)。入力・面・プロジェクタの 3 節を 1 本の木に並べる。
///
/// 選んだものは `EditorSession.selection` に入り、全ペインと inspector がそれを見る。
/// 面の節は上に重なる層を先に見せる (`HierarchyOrder`)。
struct HierarchyView: View {
    let context: AppContext
    @State private var renaming: MappingConfig.LayerID?
    @State private var draftName = ""
    @FocusState private var renameFocused: Bool

    private var session: EditorSession { context.session }

    var body: some View {
        let config = session.document.config
        List(selection: Binding(get: { session.selection.items }, set: { session.selection.set($0) })) {
            Section("入力") {
                if session.inputItems.isEmpty {
                    Text("届いている映像なし").foregroundStyle(.secondary)
                }
                ForEach(session.inputItems) { item in
                    inputRow(item).tag(ItemID.input(item.name))
                }
            }
            Section("面") {
                ForEach(HierarchyOrder.displayed(config.layers), id: \.id) { layer in
                    layerRow(layer).tag(ItemID.layer(layer.id))
                }
                .onMove { session.moveLayers(displayOffsets: $0, toDisplayOffset: $1) }
            }
            Section("プロジェクタ") {
                ForEach(config.outputs, id: \.id) { output in
                    outputRow(output).tag(ItemID.output(output.id))
                    ForEach(output.regions, id: \.id) { region in
                        regionRow(region).tag(ItemID.region(region.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onDeleteCommand { session.deleteSelection() }
        .contextMenu(forSelectionType: ItemID.self) { items in
            contextMenu(items)
        } primaryAction: { items in
            if items.count == 1, case .layer(let id) = items.first { beginRenaming(id) }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }

    // MARK: - 行

    private func inputRow(_ item: EditorSession.InputItem) -> some View {
        Label {
            Text(item.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: item.isAvailable ? "film" : "film.fill").symbolRenderingMode(.hierarchical)
        }
        .foregroundStyle(item.isAvailable ? .primary : .secondary)
        .help(item.isAvailable ? item.name : "\(item.name) (届いていない)")
    }

    @ViewBuilder
    private func layerRow(_ layer: MappingConfig.Layer) -> some View {
        let visible = layer.surface?.visible ?? layer.mask?.visible ?? true
        HStack(spacing: 6) {
            Image(systemName: layer.surface != nil ? "square.on.square" : "square.dashed")
                .foregroundStyle(.secondary)
            if renaming == layer.id {
                TextField("名前", text: $draftName)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit { commitRenaming() }
                    .onExitCommand { renaming = nil }
                    .onChange(of: renameFocused) { _, focused in if !focused { commitRenaming() } }
            } else {
                Text(layer.name).lineLimit(1)
                if let stream = layer.surface?.stream {
                    Text(stream).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Button {
                session.setVisible(!visible, for: layer.id)
            } label: {
                Image(systemName: visible ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(visible ? .secondary : .tertiary)
            .help(visible ? "隠す" : "見せる")
        }
        .opacity(visible ? 1 : 0.6)
    }

    private func outputRow(_ output: MappingConfig.Output) -> some View {
        let mode = session.mode(of: output.id)
        let missing = session.missingDisplays.contains { $0.id == output.id }
        return HStack(spacing: 6) {
            Label(output.display.name, systemImage: "display").lineLimit(1)
            Spacer(minLength: 4)
            if missing {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    .help("表示装置 \(output.display.name) が見つからない")
            }
            Text(mode.label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func regionRow(_ region: MappingConfig.Region) -> some View {
        HStack(spacing: 6) {
            Label(region.name, systemImage: "videoprojector").lineLimit(1)
            Spacer(minLength: 4)
            Text("\(Int(region.placement.width))×\(Int(region.placement.height))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .padding(.leading, 18)
    }

    // MARK: - 操作

    @ViewBuilder
    private func contextMenu(_ items: Set<ItemID>) -> some View {
        if items.count == 1, case .layer(let id) = items.first {
            Button("名前を変える") { beginRenaming(id) }
        }
        if items.contains(where: { if case .layer = $0 { true } else if case .output = $0 { true } else { false } }) {
            Button("消す", role: .destructive) {
                session.selection.set(items)
                session.deleteSelection()
            }
        }
        if items.isEmpty {
            Button("面を足す") { session.addSurface() }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 2) {
            Menu {
                Button("面を足す") { session.addSurface() }
                Divider()
                Section("出力を足す") {
                    ForEach(session.displays) { display in
                        Button("\(display.name)  (\(Int(display.pixelWidth))×\(Int(display.pixelHeight)))") {
                            session.addOutput(display: display)
                        }
                    }
                    Button("表示装置なし (窓で確かめる)") { session.addOutput(display: nil) }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("面か出力を足す")
            Button {
                session.deleteSelection()
            } label: {
                Image(systemName: "minus")
            }
            .buttonStyle(.borderless)
            .disabled(!session.canDeleteSelection)
            .help("選んだ面か出力を消す")
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func beginRenaming(_ id: MappingConfig.LayerID) {
        guard let layer = session.document.config.layer(id) else { return }
        draftName = layer.name
        renaming = id
        renameFocused = true
    }

    /// 名前の変更は確定したときに 1 回だけ文書へ送る (打つたびに取り消しを積まない)。
    private func commitRenaming() {
        guard let id = renaming else { return }
        renaming = nil
        session.renameLayer(id, to: draftName)
    }
}

extension OutputMode {
    var label: String {
        switch self {
        case .preview: "プレビューのみ"
        case .window: "別窓"
        case .fullscreen: "全画面"
        }
    }
}
