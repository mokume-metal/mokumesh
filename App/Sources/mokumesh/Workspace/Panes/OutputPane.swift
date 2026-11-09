// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeshEditor
import MokumeshMapping
import SwiftUI

/// 出力のペイン。出力ごとに、出力の窓に映るもののプレビューを描き、出し方 (プレビューのみ /
/// 別窓 / 全画面) と全画面の先の表示装置を切り替える。
struct OutputPane: View {
    let context: AppContext
    /// 選択が出力を指していないときに見せる出力 (タブで選んだもの)。
    @State private var fallback: MappingConfig.OutputID?

    private var session: EditorSession { context.session }

    /// 見せる出力。選んでいる出力か、選んでいる領域の出力。どちらでもなければタブで選んだもの。
    private var current: MappingConfig.Output? {
        let config = session.document.config
        switch session.selection.primary {
        case .output(let id): if let output = config.output(id) { return output }
        case .region(let id):
            if let output = config.outputID(containing: id).flatMap(config.output) { return output }
        default: break
        }
        return fallback.flatMap(config.output) ?? config.outputs.first
    }

    var body: some View {
        if let output = current {
            VStack(spacing: 0) {
                controls(output)
                Divider()
                preview(output)
            }
        } else {
            PanePlaceholder(text: "出力がまだありません。\n階層の ＋ から出力を足してください。")
        }
    }

    // MARK: - 切り替え

    private func controls(_ output: MappingConfig.Output) -> some View {
        let config = session.document.config
        return HStack(spacing: 8) {
            if config.outputs.count > 1 {
                Picker(
                    "出力",
                    selection: Binding(
                        get: { output.id },
                        set: { id in
                            fallback = id
                            session.selection.select(.output(id))
                        })
                ) {
                    ForEach(config.outputs, id: \.id) { Text($0.display.name).tag($0.id) }
                }
                .labelsHidden()
                .fixedSize()
            }
            Picker(
                "出し方",
                selection: Binding(
                    get: { session.mode(of: output.id) },
                    set: { context.requestMode($0, for: output.id) })
            ) {
                ForEach(OutputMode.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if session.mode(of: output.id) == .fullscreen {
                DisplayPicker(context: context, output: output)
            }
            Spacer(minLength: 0)
            Toggle(
                "4 隅",
                isOn: Binding(get: { session.showsKeystoneHandles }, set: { session.showsKeystoneHandles = $0 })
            )
            .toggleStyle(.button)
            .help("出力の窓に台形補正の 4 隅を出し、ドラッグと矢印キー (shift で 10 画素) で動かす")
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }

    // MARK: - プレビュー

    private func preview(_ output: MappingConfig.Output) -> some View {
        let id = output.id
        let selection = session.selection
        return PaneCanvas(
            hub: context.hub,
            model: { [session = session] in
                session.document.config.output(id).map { PaneScenes.outputModel($0, displays: session.displays) }
                    ?? .unit
            },
            scene: { [document = session.document] viewport in
                document.config.output(id).map { PaneScenes.output($0, layers: document.config.layers, viewport: viewport) }
            }
        ) { viewport in
            ZStack(alignment: .topLeading) {
                PaneDrawing.viewRect(viewport.modelFrame).stroke(.gray, lineWidth: 1)
                ForEach(output.regions, id: \.id) { region in
                    let frame = PaneScenes.regionFrame(region, viewport: viewport)
                    let isSelected = selection.contains(.region(region.id))
                    PaneDrawing.viewRect(frame)
                        .stroke(
                            isSelected ? PaneDrawing.selected : PaneDrawing.projector,
                            style: StrokeStyle(lineWidth: isSelected ? 2 : 1, dash: [4, 3]))
                    if session.showsKeystoneHandles {
                        Path { path in
                            let points = region.keystone.map {
                                CGPoint(x: frame.x + $0.x * frame.width, y: frame.y + $0.y * frame.height)
                            }
                            path.addLines(points + [points[0]])
                        }
                        .stroke(PaneDrawing.keystone, lineWidth: 1)
                    }
                    PaneDrawing.tag(region.name, selected: isSelected).offset(x: frame.x + 3, y: frame.y + 3)
                }
            }
        } onTap: { point in
            // プレビューのモデルの空間は表示装置の画素。領域の rect (0〜1) と比べる
            let model = PaneScenes.outputModel(output, displays: session.displays)
            let unit = Point(x: point.x / model.width, y: point.y / model.height)
            if let region = output.regions.last(where: {
                HitTest.contains(MappingConfig.Quad.corners(of: $0.rect), unit)
            }) {
                session.selection.select(.region(region.id))
            } else {
                session.selection.select(.output(id))
            }
        }
    }
}

/// 全画面に出す先の表示装置を選ぶ。設定の参照が繋がっていなければ、その名前も並べる。
private struct DisplayPicker: View {
    let context: AppContext
    let output: MappingConfig.Output

    var body: some View {
        let displays = context.session.displays
        let connected = DisplayInfo.find(output.display, in: displays)
        Menu {
            ForEach(displays) { display in
                Button {
                    context.session.setDisplay(display, for: output.id)
                } label: {
                    if display.id == connected?.id {
                        Label(display.name, systemImage: "checkmark")
                    } else {
                        Text(display.name)
                    }
                }
            }
        } label: {
            Label(
                connected?.name ?? "\(output.display.name) (見つからない)",
                systemImage: connected == nil ? "exclamationmark.triangle" : "display")
        }
        .fixedSize()
        .help("全画面に出す表示装置")
    }
}

extension AppContext {
    /// 出力の出し方を変える。全画面にすると操作窓を覆うときは、確かめてから変える。
    func requestMode(_ mode: OutputMode, for id: MappingConfig.OutputID) {
        if mode == .fullscreen, let output = document.config.output(id),
            session.policy.coversControlWindow(output, displays: session.displays)
        {
            let alert = NSAlert()
            alert.messageText = "操作窓のある表示装置を全画面で覆います"
            alert.informativeText = "出力の窓が操作窓の上に重なります。出力の窓で Esc を押すと、プレビューのみに戻ります。"
            alert.addButton(withTitle: "全画面にする")
            alert.addButton(withTitle: "キャンセル")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        session.setMode(mode, for: id)
    }
}
