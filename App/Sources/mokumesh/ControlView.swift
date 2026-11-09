// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// 操作窓。表示装置を選び、編集を切り替え、設定を保存・読み込みする。
struct ControlView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section("受け手") {
                LabeledContent("チャンネル", value: model.config.channel)
                if let error = model.receiverError {
                    Text(error).foregroundStyle(.red)
                }
                LabeledContent("届いている映像", value: model.streams.isEmpty ? "なし" : model.streams.joined(separator: ", "))
                LabeledContent("映した枚数", value: "\(model.framesShown)")
            }
            Section("表示装置") {
                ForEach(model.displays) { display in
                    Toggle(
                        isOn: Binding(
                            get: { model.isShowing(display) },
                            set: { model.setShowing(display, $0) })
                    ) {
                        Text("\(display.name)  (\(Int(display.screen.frame.width))×\(Int(display.screen.frame.height)))")
                    }
                }
                Button("表示装置を読み直す") { model.refreshDisplays() }
            }
            Section("面の映像") {
                ForEach(Array(model.config.layers.enumerated()), id: \.offset) { index, layer in
                    if let surface = layer.surface {
                        Picker(
                            surface.name,
                            selection: Binding(
                                get: { surface.stream },
                                set: { model.setStream($0, layer: index) })
                        ) {
                            ForEach(Array(Set(model.streams + [surface.stream])).sorted(), id: \.self) {
                                Text($0).tag($0)
                            }
                        }
                    }
                }
            }
            Section("編集") {
                Toggle("台形補正の 4 隅を動かす (出力の窓でドラッグ・矢印キーで 1 画素・shift で 10 画素)", isOn: $model.isEditing)
                Button("4 隅を戻す") { model.resetCorners() }
            }
            Section("設定") {
                if let url = model.configURL {
                    Text(url.path).font(.caption).textSelection(.enabled)
                }
                HStack {
                    Button("読み込む…") { open() }
                    Button("保存") { save(asking: model.configURL == nil) }
                    Button("別名で保存…") { save(asking: true) }
                }
                if let message = model.lastMessage {
                    Text(message).font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 520)
    }

    private func open() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { model.load(from: url) }
    }

    private func save(asking: Bool) {
        if !asking, let url = model.configURL {
            model.save(to: url)
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "mapping.json"
        if panel.runModal() == .OK, let url = panel.url { model.save(to: url) }
    }
}
