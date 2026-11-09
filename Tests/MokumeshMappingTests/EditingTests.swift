// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeshMapping
import Testing

@Suite("ID")
struct IdentifierTests {
    /// ID を書かない版 2 の設定 (手で書いたもの)。
    private static let withoutIDs = Data(
        """
        {
          "schemaVersion": 2, "channel": "default",
          "layers": [
            { "kind": "surface", "name": "a", "stream": "main", "visible": true,
              "input": [{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],
              "corners": [{"x":0,"y":0},{"x":10,"y":0},{"x":10,"y":10},{"x":0,"y":10}] },
            { "kind": "surface", "id": "layer-1", "name": "b", "stream": "main", "visible": true,
              "input": [{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}],
              "corners": [{"x":0,"y":0},{"x":10,"y":0},{"x":10,"y":10},{"x":0,"y":10}] },
            { "kind": "mask", "name": "m", "visible": true, "inverted": false,
              "points": [{"x":0,"y":0},{"x":10,"y":0},{"x":0,"y":10}] }
          ],
          "outputs": [
            { "display": {"name": "PJ", "id": 1},
              "regions": [{ "name": "r", "rect": {"x":0,"y":0,"width":1,"height":1},
                            "placement": {"x":0,"y":0,"width":1920,"height":1080},
                            "keystone": [{"x":0,"y":0},{"x":1,"y":0},{"x":1,"y":1},{"x":0,"y":1}] }] }
          ]
        }
        """.utf8)

    @Test("書かれていない ID は、書かれた ID と重ならない番号で決定的に振られる")
    func missing_ids_are_assigned_deterministically() throws {
        let first = try MappingConfig.decode(Self.withoutIDs)
        let second = try MappingConfig.decode(Self.withoutIDs)
        #expect(first == second)
        // 2 枚目が layer-1 を名乗っているので、1 枚目とマスクはそれを飛ばす
        #expect(first.layers.map(\.id.rawValue) == ["layer-2", "layer-1", "layer-3"])
        #expect(first.outputs.map(\.id.rawValue) == ["output-1"])
        #expect(first.outputs[0].regions.map(\.id.rawValue) == ["region-1"])
    }

    @Test("ID は書いて読み戻しても変わらない")
    func ids_round_trip() throws {
        let config = try MappingConfig.decode(Self.withoutIDs)
        let reread = try MappingConfig.decode(config.encode())
        #expect(reread.layers.map(\.id) == config.layers.map(\.id))
        #expect(reread == config)
    }

    @Test("同じ ID が 2 度あれば読まない")
    func duplicate_ids_are_rejected() throws {
        let surface = MappingConfig.Surface(name: "a", covering: .init(x: 0, y: 0, width: 10, height: 10))
        var copy = surface
        copy.name = "b"
        #expect(throws: MappingConfig.LoadError.duplicateID(surface.id.rawValue)) {
            try MappingConfig.decode(MappingConfig(layers: [.surface(surface), .surface(copy)]).encode())
        }
        let region = MappingConfig.Region(name: "r")
        let display = MappingConfig.DisplayReference(name: "PJ", id: 1)
        let twoOutputs = MappingConfig(outputs: [
            .init(display: display, regions: [region]), .init(display: display, regions: [region]),
        ])
        #expect(throws: MappingConfig.LoadError.duplicateID(region.id.rawValue)) {
            try MappingConfig.decode(twoOutputs.encode())
        }
    }

    @Test("新しく作るものには、重ならない ID が振られる")
    func new_items_get_unique_ids() {
        let a = MappingConfig.Region(name: "r")
        let b = MappingConfig.Region(name: "r")
        #expect(a.id != b.id)
    }
}

@Suite("設定への編集")
struct EditingTests {
    private func surface(_ name: String) -> MappingConfig.Layer {
        .surface(.init(id: .init(name), name: name, covering: .init(x: 0, y: 0, width: 10, height: 10)))
    }

    private func config(_ names: [String]) -> MappingConfig {
        MappingConfig(layers: names.map(surface))
    }

    private func names(_ config: MappingConfig) -> [String] { config.layers.map(\.name) }

    @Test(
        "層を並べ替える (動かした層どうしの順は保つ)",
        arguments: [
            (["c"], 0, ["c", "a", "b", "d"]),  // 一番下へ
            (["a"], 4, ["b", "c", "d", "a"]),  // 一番上へ
            (["a"], 1, ["a", "b", "c", "d"]),  // 自分の直後 = 動かない
            (["b"], 0, ["b", "a", "c", "d"]),
            (["a", "c"], 4, ["b", "d", "a", "c"]),
            (["d", "a"], 2, ["b", "a", "d", "c"]),
            (["b"], 99, ["a", "c", "d", "b"]),  // 範囲の外は端に寄せる
        ])
    func move_layers(source: [String], destination: Int, expected: [String]) {
        var edited = config(["a", "b", "c", "d"])
        edited.moveLayers(Set(source.map { .init($0) }), before: destination)
        #expect(names(edited) == expected)
    }

    @Test("無い ID を動かしても何も変わらない")
    func move_unknown_layer_is_noop() {
        var edited = config(["a", "b"])
        edited.moveLayers([.init("z")], before: 0)
        #expect(names(edited) == ["a", "b"])
    }

    @Test("層を差し込み・消す")
    func insert_and_remove_layers() {
        var edited = config(["a", "b"])
        edited.insertLayer(surface("top"))
        edited.insertLayer(surface("bottom"), at: 0)
        edited.insertLayer(surface("far"), at: 99)
        #expect(names(edited) == ["bottom", "a", "b", "top", "far"])
        let removed = edited.removeLayers([.init("a"), .init("far"), .init("z")])
        #expect(removed == 2)
        #expect(names(edited) == ["bottom", "b", "top"])
    }

    @Test("名前の変更は前後の空白を落とし、空の名前は採らない")
    func rename_layer() {
        var edited = config(["a"])
        let renamed = edited.renameLayer(.init("a"), to: "  壁  ")
        #expect(renamed)
        #expect(names(edited) == ["壁"])
        let blank = edited.renameLayer(.init("a"), to: "   ")
        let unknown = edited.renameLayer(.init("z"), to: "x")
        #expect(!blank && !unknown)
        #expect(names(edited) == ["壁"])
    }

    @Test("まだ無い名前を番号で作る")
    func unused_layer_name() {
        #expect(config([]).unusedLayerName("面") == "面 1")
        #expect(config(["面 1", "面 3"]).unusedLayerName("面") == "面 2")
    }

    @Test("出力を足すとステージの右端に置き、面が無ければ覆う面も置く")
    func append_output() throws {
        var edited = MappingConfig()
        let display = MappingConfig.DisplayReference(name: "PJ", id: 1)
        let first = edited.appendOutput(
            display: display, regionName: "PJ", size: (1920, 1080), stream: "main", surfaceName: "面 1")
        let second = edited.appendOutput(
            display: display, regionName: "PJ 2", size: (1280, 800), stream: "main", surfaceName: "面 1")
        #expect(edited.layers.count == 1)
        #expect(edited.output(second)?.regions[0].placement == .init(x: 1920, y: 0, width: 1280, height: 800))
        let region = try #require(edited.output(first)?.regions[0])
        #expect(edited.outputID(containing: region.id) == first)
        let updated = edited.updateRegion(region.id) { $0.name = "左" }
        #expect(updated)
        #expect(edited.region(region.id)?.name == "左")
        let removed = edited.removeOutputs([first])
        #expect(removed == 1)
        #expect(edited.region(region.id) == nil)
    }

    @Test("面が使う映像を、重ならずに並びの順で返す")
    func streams_in_use() {
        var edited = config(["a", "b"])
        edited.updateSurface(.init("b")) { $0.stream = "syphon:App/x" }
        edited.insertLayer(surface("c"))
        #expect(edited.streamsInUse == ["main", "syphon:App/x"])
    }
}
