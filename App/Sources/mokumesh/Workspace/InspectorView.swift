// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshEditor
import MokumeshMapping
import SwiftUI

/// inspector (操作窓の右端)。選んだもの 1 つの数値を出す。
///
/// 選んだものの種類ごとに項を分ける。新しい種類 (マスク・グループなど) は、ここに項を 1 つ足す。
struct InspectorView: View {
    let context: AppContext
    private var session: EditorSession { context.session }

    var body: some View {
        let config = session.document.config
        Group {
            switch session.selection.single {
            case .layer(let id):
                if let layer = config.layer(id) {
                    LayerInspector(context: context, layer: layer)
                }
            case .output(let id):
                if let output = config.output(id) {
                    OutputInspector(context: context, output: output)
                }
            case .region(let id):
                if let region = config.region(id) {
                    RegionInspector(context: context, region: region)
                }
            case .input(let name):
                InputInspector(context: context, name: name)
            case nil:
                PanePlaceholder(
                    text: session.selection.isEmpty ? "何も選んでいません" : "\(session.selection.items.count) 項目を選んでいます")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // 選び直したら、打ちかけの名前を持ち越さない
        .id(session.selection.single)
    }
}

// MARK: - 面とマスク

private struct LayerInspector: View {
    let context: AppContext
    let layer: MappingConfig.Layer

    private var session: EditorSession { context.session }

    var body: some View {
        Form {
            Section(layer.surface != nil ? "面" : "マスク") {
                CommitTextField(title: "名前", value: layer.name) { session.renameLayer(layer.id, to: $0) }
                Toggle(
                    "見せる",
                    isOn: Binding(
                        get: { layer.surface?.visible ?? layer.mask?.visible ?? true },
                        set: { session.setVisible($0, for: layer.id) }))
            }
            if let surface = layer.surface {
                Section("映像") {
                    Picker(
                        "映像",
                        selection: Binding(get: { surface.stream }, set: { session.setStream($0, for: surface.id) })
                    ) {
                        ForEach(streamChoices(surface.stream), id: \.self) { Text($0).tag($0) }
                    }
                }
                Section("切り取り (映像の中で 0〜1)") { QuadRows(points: surface.input, digits: 3) }
                Section("置く先 (ステージの画素)") { QuadRows(points: surface.corners, digits: 1) }
            }
            if let mask = layer.mask {
                Section("形") {
                    LabeledContent("頂点", value: "\(mask.points.count)")
                    LabeledContent("反転", value: mask.inverted ? "内側を覆う" : "外側を覆う")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func streamChoices(_ current: String) -> [String] {
        var names = session.inputItems.map(\.name)
        if !names.contains(current) { names.append(current) }
        return names
    }
}

// MARK: - 出力と領域

private struct OutputInspector: View {
    let context: AppContext
    let output: MappingConfig.Output

    private var session: EditorSession { context.session }

    var body: some View {
        let connected = DisplayInfo.find(output.display, in: session.displays)
        Form {
            Section("出力") {
                LabeledContent("表示装置", value: output.display.name)
                LabeledContent("繋がり", value: connected.map { "\(Int($0.pixelWidth))×\(Int($0.pixelHeight))" } ?? "見つからない")
                Picker(
                    "出し方",
                    selection: Binding(
                        get: { session.mode(of: output.id) }, set: { context.requestMode($0, for: output.id) })
                ) {
                    ForEach(OutputMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Picker(
                    "全画面の先",
                    selection: Binding(
                        get: { connected?.id ?? 0 },
                        set: { id in
                            if let display = session.displays.first(where: { $0.id == id }) {
                                session.setDisplay(display, for: output.id)
                            }
                        })
                ) {
                    if connected == nil { Text("\(output.display.name) (見つからない)").tag(UInt32(0)) }
                    ForEach(session.displays) { Text($0.name).tag($0.id) }
                }
            }
            Section("プロジェクタ") {
                ForEach(output.regions, id: \.id) { region in
                    LabeledContent(region.name, value: "\(Int(region.placement.width))×\(Int(region.placement.height))")
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RegionInspector: View {
    let context: AppContext
    let region: MappingConfig.Region

    private var session: EditorSession { context.session }

    var body: some View {
        let output = session.document.config.outputID(containing: region.id).flatMap(session.document.config.output)
        Form {
            Section("プロジェクタ") {
                CommitTextField(title: "名前", value: region.name) { session.renameRegion(region.id, to: $0) }
                if let output { LabeledContent("表示装置", value: output.display.name) }
            }
            Section("受け持つ範囲 (ステージの画素)") { RectRows(rect: region.placement, digits: 0) }
            Section("表示装置の中の位置 (0〜1)") { RectRows(rect: region.rect, digits: 3) }
            Section("台形補正 (領域の中で 0〜1)") {
                QuadRows(points: region.keystone, digits: 3)
                Button("台形補正を戻す") { session.resetKeystone(region.id) }
                    .disabled(region.keystone == MappingConfig.Quad.unit)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 映像

private struct InputInspector: View {
    let context: AppContext
    let name: String

    private var session: EditorSession { context.session }

    var body: some View {
        let item = session.inputItems.first { $0.name == name }
        let users = session.document.config.layers.compactMap(\.surface).filter { $0.stream == name }
        Form {
            Section("映像") {
                LabeledContent("名前") { Text(name).textSelection(.enabled) }
                LabeledContent("来た道", value: SyphonSources.isSyphon(name) ? "Syphon" : "専用の受け渡し")
                LabeledContent("状態", value: item?.isAvailable == true ? "届いている" : "届いていない")
                if let size = session.streamSizes[name] {
                    LabeledContent("大きさ", value: "\(Int(size.width))×\(Int(size.height))")
                }
            }
            Section("使っている面") {
                if users.isEmpty { Text("なし").foregroundStyle(.secondary) }
                ForEach(users, id: \.id) { surface in
                    Button(surface.name) { session.selection.select(.layer(surface.id)) }.buttonStyle(.link)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 部品

/// 確定 (return・別の欄へ移る) したときにだけ値を送る欄。打つたびに取り消しを積まない。
private struct CommitTextField: View {
    let title: String
    let value: String
    let commit: (String) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $draft)
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, new in if !focused { draft = new } }
            .onSubmit { send() }
            .onChange(of: focused) { _, now in if !now { send() } }
    }

    private func send() {
        guard draft != value else { return }
        commit(draft)
        draft = value
    }
}

private struct QuadRows: View {
    let points: [Point]
    let digits: Int
    private static let names = ["左上", "右上", "右下", "左下"]

    var body: some View {
        ForEach(Array(points.enumerated()), id: \.offset) { index, point in
            LabeledContent(Self.names.indices.contains(index) ? Self.names[index] : "\(index + 1)") {
                Text("\(point.x, format: .number.precision(.fractionLength(digits)))  \(point.y, format: .number.precision(.fractionLength(digits)))")
                    .monospacedDigit()
            }
        }
    }
}

private struct RectRows: View {
    let rect: MappingConfig.Rect
    let digits: Int

    var body: some View {
        LabeledContent("位置") {
            Text("\(rect.x, format: .number.precision(.fractionLength(digits)))  \(rect.y, format: .number.precision(.fractionLength(digits)))")
                .monospacedDigit()
        }
        LabeledContent("大きさ") {
            Text("\(rect.width, format: .number.precision(.fractionLength(digits)))  \(rect.height, format: .number.precision(.fractionLength(digits)))")
                .monospacedDigit()
        }
    }
}
