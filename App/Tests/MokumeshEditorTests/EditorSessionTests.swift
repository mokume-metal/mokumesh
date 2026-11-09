// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeshEditor
import MokumeshMapping
import Testing

@MainActor
@Suite("編集の状態")
struct EditorSessionTests {
    private let projector = DisplayInfo(id: 7, name: "PJ", pixelWidth: 1920, pixelHeight: 1080)
    private let builtIn = DisplayInfo(id: 1, name: "内蔵", pixelWidth: 3024, pixelHeight: 1964)

    @Test("消したものは選択から外れ、映像は外れない")
    func selection_is_pruned_after_edits() {
        let (document, _) = testDocument(["a", "b"])
        let session = EditorSession(document: document)
        session.selection.set([.layer(.init("a")), .layer(.init("b")), .input("gone")], primary: .layer(.init("a")))
        document.perform("消す") { $0.removeLayers([.init("a")]) }
        #expect(session.selection.items == [.layer(.init("b")), .input("gone")])
        #expect(session.selection.primary != .layer(.init("a")))
    }

    @Test("面を足すと、選んだ層の真上に置いて選ぶ。取り消すと選択からも消える")
    func add_surface_goes_above_selection() throws {
        let (document, undo) = testDocument(["a", "b", "c"])
        let session = EditorSession(document: document)
        session.selection.select(.layer(.init("a")))
        let added = try #require(session.addSurface())
        #expect(document.config.layers.map(\.id) == [.init("a"), added, .init("b"), .init("c")])
        #expect(document.config.layers[1].name == "面 1")
        #expect(session.selection.single == .layer(added))
        undo.undo()
        #expect(document.config.layers.count == 3)
        #expect(session.selection.isEmpty)
    }

    @Test("階層の並び (上が先) で並べ替えると、設定の並びは逆から読んだ位置になる")
    func move_in_display_order() {
        // 設定 a b c d (a が一番下) → 階層の表示は d c b a
        let (document, _) = testDocument(["a", "b", "c", "d"])
        let session = EditorSession(document: document)
        // 表示で a (3 番目) を一番上 (0 の前) へ = 設定の一番上 (末尾)
        session.moveLayers(displayOffsets: [3], toDisplayOffset: 0)
        #expect(document.config.layers.map(\.name) == ["b", "c", "d", "a"])
        // 表示 a d c b で、d (1 番目) を一番下 (4 の前) へ = 設定の先頭
        session.moveLayers(displayOffsets: [1], toDisplayOffset: 4)
        #expect(document.config.layers.map(\.name) == ["d", "b", "c", "a"])
        // 表示 a c b d で、b (2) を c の上 (1 の前) へ
        session.moveLayers(displayOffsets: [2], toDisplayOffset: 1)
        #expect(document.config.layers.map(\.name) == ["d", "c", "b", "a"])
    }

    @Test("選んだ層と出力を消し、取り消すと戻る")
    func delete_selection_and_undo() throws {
        let (document, undo) = testDocument(["a", "b"])
        let session = EditorSession(document: document)
        let output = try #require(session.addOutput(display: nil))
        session.selection.set([.layer(.init("a")), .output(output)])
        #expect(session.canDeleteSelection)
        session.deleteSelection()
        #expect(document.config.layers.map(\.name) == ["b"])
        #expect(document.config.outputs.isEmpty)
        undo.undo()
        #expect(document.config.layers.map(\.name) == ["a", "b"])
        #expect(document.config.output(output) != nil)
    }

    @Test("表示装置の無い出力は、番号の名前と 1920×1080 で足す")
    func add_virtual_output() throws {
        let (document, _) = testDocument([])
        let session = EditorSession(document: document)
        let first = try #require(session.addOutput(display: nil))
        let second = try #require(session.addOutput(display: nil))
        #expect(document.config.output(first)?.display.name == "出力 1")
        #expect(document.config.output(second)?.display.name == "出力 2")
        #expect(document.config.output(second)?.regions[0].placement == .init(x: 1920, y: 0, width: 1920, height: 1080))
        // 面が無かったので 1 枚置かれる
        #expect(document.config.layers.count == 1)
        #expect(session.selection.single == .output(second))
    }

    @Test("入力のペインは、選んだ映像か選んだ面の映像を見せ、選択が離れても最後のものを見せ続ける")
    func input_stream_follows_selection() {
        let (document, _) = testDocument(["a"])
        let session = EditorSession(document: document)
        session.setAvailableStreams(["main", "syphon:App/x"])
        #expect(session.inputStream == "main")
        session.selection.select(.input("syphon:App/x"))
        #expect(session.inputStream == "syphon:App/x")
        session.selection.clear()
        #expect(session.inputStream == "syphon:App/x")
        session.selection.select(.layer(.init("a")))
        #expect(session.inputStream == "main")
        #expect(session.wantedStreams == ["main"])
    }

    @Test("面が使うのに届いていない映像も、入力の節に後ろから並ぶ")
    func input_items_include_missing_streams() {
        let (document, _) = testDocument(["a"])
        let session = EditorSession(document: document)
        session.setAvailableStreams(["syphon:App/x"])
        #expect(
            session.inputItems == [
                .init(name: "syphon:App/x", isAvailable: true, isUsed: false),
                .init(name: "main", isAvailable: false, isUsed: true),
            ])
    }

    @Test("表示装置が外れても望んだ出し方は残り、繋ぎ直すと窓が戻る")
    func desired_mode_survives_disconnect() throws {
        let (document, _) = testDocument([])
        let session = EditorSession(document: document, displays: [builtIn, projector])
        var plans = 0
        session.observePlan { plans += 1 }
        let output = try #require(session.addOutput(display: projector))
        #expect(session.mode(of: output) == .fullscreen)
        #expect(session.windowPlan == [output: .fullscreen(displayID: 7)])
        session.setDisplays([builtIn])
        #expect(session.windowPlan.isEmpty)
        #expect(session.missingDisplays.map(\.id) == [output])
        #expect(session.mode(of: output) == .fullscreen)
        session.setDisplays([builtIn, projector])
        #expect(session.windowPlan == [output: .fullscreen(displayID: 7)])
        #expect(plans >= 3)
    }

    @Test("出力を消すと、その出し方も捨てる")
    func removing_output_drops_mode() throws {
        let (document, _) = testDocument([])
        let session = EditorSession(document: document)
        let output = try #require(session.addOutput(display: nil))
        session.setMode(.window, for: output)
        #expect(session.windowPlan == [output: .window])
        document.perform("消す") { $0.removeOutputs([output]) }
        #expect(session.windowPlan.isEmpty)
        #expect(session.mode(of: output) == .preview)
    }
}
