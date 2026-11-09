// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeshEditor
import MokumeshMapping
import Testing

@Suite("出し方の決まり")
struct PresentationPolicyTests {
    private let projector = DisplayInfo(id: 7, name: "PJ", pixelWidth: 1920, pixelHeight: 1080)
    private let builtIn = DisplayInfo(id: 1, name: "内蔵", pixelWidth: 3024, pixelHeight: 1964)

    private func output(_ display: DisplayInfo, id: UInt32? = nil) -> MappingConfig.Output {
        .init(display: .init(name: display.name, id: id ?? display.id), regions: [.init(name: display.name)])
    }

    @Test("新しい出力は、操作窓の無い繋がった表示装置なら全画面、それ以外はプレビュー、--window なら窓")
    func initial_modes() {
        let policy = PresentationPolicy(controlDisplayID: 1)
        let displays = [builtIn, projector]
        #expect(policy.initialMode(for: output(projector), displays: displays) == .fullscreen)
        #expect(policy.initialMode(for: output(builtIn), displays: displays) == .preview)
        #expect(policy.initialMode(for: output(projector), displays: [builtIn]) == .preview)
        // 識別子が変わっても名前で見つける
        #expect(policy.initialMode(for: output(projector, id: 99), displays: displays) == .fullscreen)
        #expect(PresentationPolicy(windowedOnly: true).initialMode(for: output(builtIn), displays: displays) == .window)
        #expect(policy.coversControlWindow(output(builtIn), displays: displays))
        #expect(!policy.coversControlWindow(output(projector), displays: displays))
    }

    @Test("計画: プレビューは窓を開かず、全画面は見つかった表示装置へ、--window は全画面も窓にする")
    func plan_targets() {
        let a = output(projector), b = output(builtIn), c = output(DisplayInfo(id: 5, name: "無い", pixelWidth: 1, pixelHeight: 1))
        let config = MappingConfig(outputs: [a, b, c])
        let modes: [MappingConfig.OutputID: OutputMode] = [a.id: .fullscreen, b.id: .window, c.id: .fullscreen]
        let policy = PresentationPolicy()
        #expect(
            policy.plan(config: config, modes: modes, displays: [builtIn, projector])
                == [a.id: .fullscreen(displayID: 7), b.id: .window])
        #expect(policy.missingDisplays(config: config, modes: modes, displays: [builtIn, projector]).map(\.id) == [c.id])
        #expect(
            PresentationPolicy(windowedOnly: true).plan(config: config, modes: modes, displays: [])
                == [a.id: .window, b.id: .window, c.id: .window])
        #expect(policy.plan(config: config, modes: [:], displays: [builtIn, projector]).isEmpty)
        // 繋ぎ直しで識別子が変わっても、名前で見つけて全画面にする
        let renumbered = output(projector, id: 99)
        #expect(
            policy.plan(
                config: MappingConfig(outputs: [renumbered]), modes: [renumbered.id: .fullscreen],
                displays: [builtIn, projector])
                == [renumbered.id: .fullscreen(displayID: 7)])
    }
}

@Suite("座標の写し")
struct ViewportTests {
    @Test("縦横比を保って中央に収め、往復で元に戻る")
    func aspect_fit_round_trip() throws {
        // 3840×1080 のステージを 400×300 のペインへ: 幅で決まり 0.1 倍、上下に余白
        let viewport = Viewport(model: .init(x: 0, y: 0, width: 3840, height: 1080), viewWidth: 400, viewHeight: 300, inset: 8)
        #expect(abs(viewport.scale - 384.0 / 3840) < 1e-12)
        let frame = viewport.modelFrame
        #expect(abs(frame.x - 8) < 1e-9)
        #expect(abs(frame.y - (300 - 108) / 2) < 1e-9)
        let point = Point(x: 1920, y: 540)
        let view = viewport.toView(point)
        #expect(abs(view.x - 200) < 1e-9 && abs(view.y - 150) < 1e-9)
        let back = try #require(viewport.toModel(view))
        #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
        #expect(viewport.normalized(frame).width == frame.width / 400)
    }

    @Test("原点のずれたモデルの範囲も写せる。描けない大きさでは写さない")
    func offset_model_and_degenerate_view() {
        let viewport = Viewport(model: .init(x: -100, y: 50, width: 200, height: 100), viewWidth: 200, viewHeight: 100)
        #expect(viewport.toView(Point(x: -100, y: 50)) == Point(x: 0, y: 0))
        #expect(Viewport(model: .unit, viewWidth: 0, viewHeight: 100).toModel(Point(x: 0, y: 0)) == nil)
        #expect(Viewport(model: .unit, viewWidth: 10, viewHeight: 10, inset: 6).scale == 0)
    }

    @Test("一番近い点を、半径の内でだけ選ぶ")
    func nearest_point() {
        let viewport = Viewport(model: .init(x: 0, y: 0, width: 100, height: 100), viewWidth: 100, viewHeight: 100)
        let points = [Point(x: 0, y: 0), Point(x: 100, y: 0), Point(x: 90, y: 10)]
        #expect(viewport.nearest(points, to: Point(x: 95, y: 3), within: 10) == 1)
        #expect(viewport.nearest(points, to: Point(x: 91, y: 9), within: 10) == 2)
        #expect(viewport.nearest(points, to: Point(x: 50, y: 50), within: 10) == nil)
    }

    @Test("ステージの点にある一番上の見えている面を選ぶ")
    func topmost_surface() {
        var hidden = MappingConfig.Surface(id: .init("hidden"), name: "h", covering: .init(x: 0, y: 0, width: 50, height: 50))
        hidden.visible = false
        let config = MappingConfig(layers: [
            .surface(.init(id: .init("below"), name: "b", covering: .init(x: 0, y: 0, width: 100, height: 100))),
            .surface(.init(id: .init("above"), name: "a", covering: .init(x: 50, y: 50, width: 100, height: 100))),
            .surface(hidden),
        ])
        #expect(HitTest.topmostSurface(at: Point(x: 75, y: 75), in: config) == .init("above"))
        #expect(HitTest.topmostSurface(at: Point(x: 25, y: 25), in: config) == .init("below"))
        #expect(HitTest.topmostSurface(at: Point(x: 200, y: 200), in: config) == nil)
    }

    @Test("ステージの外形は、領域が無ければ面の外接矩形、何も無ければ 1920×1080")
    func stage_extent_fallback() {
        #expect(MappingConfig().stageExtent == .init(x: 0, y: 0, width: 1920, height: 1080))
        let config = MappingConfig(layers: [
            .surface(.init(name: "a", corners: [.init(x: 10, y: 20), .init(x: 110, y: 20), .init(x: 120, y: 220), .init(x: 0, y: 200)]))
        ])
        #expect(config.stageExtent == .init(x: 0, y: 20, width: 120, height: 200))
    }
}

@Suite("ペインの配置")
struct PaneLayoutTests {
    private let metrics = PaneLayout.Metrics(header: 20, divider: 2, minimum: 100)

    @Test("既定は 2×2 で、仕切りの幅を残して分ける")
    func default_grid() {
        let frames = PaneLayout().frames(width: 802, height: 602, metrics: metrics)
        #expect(frames[.input] == .init(x: 0, y: 0, width: 401, height: 301))
        #expect(frames[.stage] == .init(x: 403, y: 0, width: 399, height: 301))
        #expect(frames[.projectors] == .init(x: 0, y: 303, width: 401, height: 299))
        #expect(frames[.output] == .init(x: 403, y: 303, width: 399, height: 299))
    }

    @Test("最大化したペインだけが窓いっぱいになる")
    func maximized_fills() {
        var layout = PaneLayout()
        layout.toggleMaximized(.stage)
        #expect(layout.frames(width: 800, height: 600, metrics: metrics) == [.stage: .init(x: 0, y: 0, width: 800, height: 600)])
        layout.toggleMaximized(.stage)
        #expect(layout.frames(width: 800, height: 600, metrics: metrics).count == 4)
    }

    @Test("畳んだペインは見出しだけになり、同じ列のもう 1 つが広がる。列の両方は畳めない")
    func collapse() {
        var layout = PaneLayout()
        layout.toggleCollapsed(.projectors)
        let frames = layout.frames(width: 800, height: 600, metrics: metrics)
        #expect(frames[.projectors]?.height == 20)
        #expect(frames[.input]?.height == Double(600 - 2 - 20))
        #expect(frames[.stage]?.height == 300)
        layout.toggleCollapsed(.input)
        #expect(layout.collapsed == [.input])
        let reopened = layout.frames(width: 800, height: 600, metrics: metrics)
        #expect(reopened[.input]?.height == 20)
        #expect(reopened[.projectors]?.height == Double(600 - 2 - 20))
    }

    @Test("仕切りは最小の大きさを割らない所で止まる")
    func dividers_clamp() {
        var layout = PaneLayout()
        layout.dragColumnDivider(to: 10, width: 800, metrics: metrics)
        #expect(layout.columnWidth(width: 800, metrics: metrics) == 100)
        layout.dragRowDivider(column: 1, to: 590, height: 600, metrics: metrics)
        #expect(abs(layout.topHeight(column: 1, height: 600, metrics: metrics) - (600 - 2 - 100)) < 1e-9)
    }
}

@Suite("ペインに描くもの")
struct PaneScenesTests {
    @Test("ステージのペインは、ステージの外形を受け持つ領域 1 つを、Viewport の枠へ置く")
    func stage_scene() {
        let config = MappingConfig(
            layers: [.surface(.init(name: "a", covering: .init(x: 0, y: 0, width: 3840, height: 1080)))],
            outputs: [
                .init(display: .init(name: "PJ", id: 1), regions: [.init(name: "L")]),
                .init(display: .init(name: "PJ", id: 2), regions: [.init(name: "R", placement: .init(x: 1920, y: 0, width: 1920, height: 1080))]),
            ])
        let viewport = Viewport(model: config.stageExtent, viewWidth: 400, viewHeight: 300)
        let scene = PaneScenes.stage(config, viewport: viewport)
        #expect(scene.regions.count == 1)
        #expect(scene.regions[0].placement == .init(x: 0, y: 0, width: 3840, height: 1080))
        #expect(scene.regions[0].keystone == MappingConfig.Quad.unit)
        #expect(scene.regions[0].rect == viewport.normalized(viewport.modelFrame))
        #expect(scene.layers == config.layers)
    }

    @Test("入力のペインは映像全体を切り取らずに映し、大きさが分からなければ 16:9 で置く")
    func input_scene() {
        let model = PaneScenes.inputModel(pixelSize: PixelSize(width: 1280, height: 720))
        #expect(model == .init(x: 0, y: 0, width: 1280, height: 720))
        #expect(PaneScenes.inputModel(pixelSize: nil).width == 1920)
        let viewport = Viewport(model: model, viewWidth: 640, viewHeight: 480)
        let scene = PaneScenes.input(stream: "main", viewport: viewport)
        let surface = scene.layers.first?.surface
        #expect(surface?.stream == "main")
        #expect(surface?.input == MappingConfig.Quad.unit)
        #expect(surface?.corners == MappingConfig.Quad.corners(of: model))
    }

    @Test("出力のプレビューは、領域を表示装置の中の位置のまま縮めて置く")
    func output_scene() {
        let left = MappingConfig.Region(name: "L", rect: .init(x: 0, y: 0, width: 0.5, height: 1))
        let right = MappingConfig.Region(name: "R", rect: .init(x: 0.5, y: 0, width: 0.5, height: 1))
        let output = MappingConfig.Output(display: .init(name: "分配器", id: 3), regions: [left, right])
        let displays = [DisplayInfo(id: 3, name: "分配器", pixelWidth: 3840, pixelHeight: 1080)]
        let model = PaneScenes.outputModel(output, displays: displays)
        #expect(model == .init(x: 0, y: 0, width: 3840, height: 1080))
        // 繋がっていなければ、領域が 2 つなので 1920×1080
        #expect(PaneScenes.outputModel(output, displays: []).width == 1920)
        // 横に余白が出る大きさ (領域の位置に枠の左端が足されることを見る)
        let viewport = Viewport(model: model, viewWidth: 800, viewHeight: 100)
        let scene = PaneScenes.output(output, layers: [], viewport: viewport)
        let frame = viewport.normalized(viewport.modelFrame)
        #expect(abs(scene.regions[1].rect.x - (frame.x + frame.width / 2)) < 1e-12)
        #expect(abs(scene.regions[1].rect.width - frame.width / 2) < 1e-12)
        #expect(scene.regions[1].placement == right.placement)
    }
}
