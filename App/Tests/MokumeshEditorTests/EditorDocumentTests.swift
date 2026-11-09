// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeshEditor
import MokumeshMapping
import Testing

/// 試しに使う面。
func testSurface(_ name: String, x: Double = 0) -> MappingConfig.Layer {
    .surface(.init(id: .init(name), name: name, covering: .init(x: x, y: 0, width: 100, height: 100)))
}

@MainActor
func testDocument(_ names: [String]) -> (EditorDocument, UndoManager) {
    let document = EditorDocument(config: MappingConfig(layers: names.map { testSurface($0) }))
    let undo = UndoManager()
    // 試験には run loop が無いので、イベントごとの group に頼らない
    undo.groupsByEvent = false
    document.undoManager = undo
    return (document, undo)
}

@MainActor
@Suite("文書")
struct EditorDocumentTests {
    private func names(_ document: EditorDocument) -> [String] { document.config.layers.map(\.name) }

    @Test("変えると取り消せ、やり直せる。取り消しの名前が付く")
    func perform_registers_undo_and_redo() {
        let (document, undo) = testDocument(["a"])
        document.perform("名前を変える") { $0.renameLayer(.init("a"), to: "b") }
        #expect(names(document) == ["b"])
        #expect(undo.undoActionName == "名前を変える")
        undo.undo()
        #expect(names(document) == ["a"])
        #expect(undo.canRedo)
        undo.redo()
        #expect(names(document) == ["b"])
        undo.undo()
        #expect(names(document) == ["a"])
    }

    @Test("続けて変えたものは、取り消し 1 回にまとまる")
    func gesture_coalesces_into_one_undo() {
        let (document, undo) = testDocument(["a"])
        document.beginGesture("動かす")
        for step in 1...5 {
            document.perform("動かす") { $0.updateSurface(.init("a")) { $0.corners[2].x = 100 + Double(step) } }
        }
        #expect(!undo.canUndo)
        document.endGesture()
        #expect(document.config.layers[0].surface?.corners[2].x == 105)
        undo.undo()
        #expect(document.config.layers[0].surface?.corners[2].x == 100)
        #expect(!undo.canUndo)
    }

    @Test("何も変わらない操作と、映せない形になる操作は採らない")
    func noop_and_invalid_edits_are_rejected() {
        let (document, undo) = testDocument(["a"])
        let revision = document.revision
        let unchanged = document.perform("何もしない") { _ in }
        // 面の 4 隅を一直線に潰す
        let invalid = document.perform("潰す") {
            $0.updateSurface(.init("a")) { $0.corners = Array(repeating: Point(x: 0, y: 0), count: 4) }
        }
        #expect(!unchanged && !invalid)
        #expect(document.revision == revision)
        #expect(!undo.canUndo)
    }

    @Test("保存すると未保存の印が消え、取り消して保存したときの形に戻ると消える")
    func dirty_tracks_saved_config() throws {
        let (document, undo) = testDocument(["a"])
        #expect(!document.isDirty)
        document.perform("名前を変える") { $0.renameLayer(.init("a"), to: "b") }
        #expect(document.isDirty)
        let url = FileManager.default.temporaryDirectory.appending(path: "mokumesh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try document.save(to: url)
        #expect(!document.isDirty)
        #expect(document.fileURL == url)
        undo.undo()
        #expect(document.isDirty)
        undo.redo()
        #expect(!document.isDirty)
    }

    @Test("読み込むと取り消しの履歴を捨て、変わったことを知らせる")
    func load_resets_history_and_notifies() throws {
        let (document, undo) = testDocument(["a"])
        var seen: [[String]] = []
        document.observeChanges { _, new in seen.append(new.layers.map(\.name)) }
        document.perform("名前を変える") { $0.renameLayer(.init("a"), to: "b") }
        let url = FileManager.default.temporaryDirectory.appending(path: "mokumesh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try MappingConfig(layers: [testSurface("loaded")]).encode().write(to: url)
        try document.load(from: url)
        #expect(names(document) == ["loaded"])
        #expect(!undo.canUndo)
        #expect(!document.isDirty)
        #expect(seen == [["b"], ["loaded"]])
    }
}
