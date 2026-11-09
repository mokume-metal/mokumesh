// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeshEditor
import MokumeshMapping
import QuartzCore

/// 出力 1 つを映す窓。表示装置を覆う縁の無い窓か、普通の窓 (表示装置の代わり)。
///
/// 窓は出力の ID に結ぶ (ADR-0003 決定 3)。出力を並べ替えたり消したりしても、別の出力を
/// 指さない。
@MainActor
final class OutputWindow: NSWindow {
    let outputID: MappingConfig.OutputID
    let target: OutputWindowTarget
    private let content: OutputContentView

    /// - Parameter screen: 全画面ならその表示装置、窓なら置く表示装置。
    init(
        outputID: MappingConfig.OutputID, target: OutputWindowTarget, screen: NSScreen, index: Int, context: AppContext,
        onEscape: @escaping () -> Void
    ) {
        self.outputID = outputID
        self.target = target
        content = OutputContentView(outputID: outputID, context: context, onEscape: onEscape)
        switch target {
        case .window:
            let size = NSSize(width: 960, height: 540)
            super.init(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            setFrameOrigin(
                NSPoint(
                    x: screen.visibleFrame.midX - size.width / 2 + CGFloat(index) * 40,
                    y: screen.visibleFrame.midY - size.height / 2 - CGFloat(index) * 40))
        case .fullscreen:
            super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            setFrame(screen.frame, display: false)
            // メニューバーより上に置く。プロジェクタの画面にメニューバーが出ていても隠れる
            level = .mainMenu + 1
            collectionBehavior = [.canJoinAllSpaces, .fullScreenNone, .stationary]
        }
        backgroundColor = .black
        isReleasedWhenClosed = false
        hasShadow = false
        contentView = content
        // Esc と矢印キーを中身で受ける
        makeFirstResponder(content)
        refreshTitle(context.document.config)
    }

    override var canBecomeKey: Bool { true }

    var presented: (@Sendable (Double, [SourceFrame]) -> Void)? {
        get { content.canvas.presented }
        set { content.canvas.presented = newValue }
    }

    func refreshTitle(_ config: MappingConfig) {
        guard case .window = target, let output = config.output(outputID) else { return }
        title = "mokumesh 出力: \(output.display.name)"
    }

    func stop() { content.canvas.stop() }
}

/// 出力の窓の中身。Metal の層に描き、台形補正の目印を別の層に重ねる。
@MainActor
private final class OutputContentView: NSView {
    let canvas: MetalCanvasView
    private let outputID: MappingConfig.OutputID
    private unowned let context: AppContext
    private let onEscape: () -> Void
    private let overlay = CALayer()
    /// ドラッグ中・矢印で動かす隅。
    private var selected: (region: MappingConfig.RegionID, corner: Int)?
    /// 目印を描いたときの状態。変わったときだけ描き直す。
    private var drawnState: (revision: Int, showsHandles: Bool, size: CGSize, selected: String)?

    private var session: EditorSession { context.session }
    private var regions: [MappingConfig.Region] { context.document.config.output(outputID)?.regions ?? [] }

    init(outputID: MappingConfig.OutputID, context: AppContext, onEscape: @escaping () -> Void) {
        self.outputID = outputID
        self.context = context
        self.onEscape = onEscape
        canvas = MetalCanvasView(hub: context.hub)
        super.init(frame: .zero)
        wantsLayer = true
        addSubview(canvas)
        layer?.addSublayer(overlay)
        canvas.scene = { [weak self] _ in
            guard let self, let output = context.document.config.output(outputID) else { return nil }
            self.refreshOverlayIfNeeded()
            return RenderScene(regions: output.regions, layers: context.document.config.layers)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override func layout() {
        super.layout()
        canvas.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        overlay.frame = bounds
        overlay.zPosition = 1
        CATransaction.commit()
        refreshOverlayIfNeeded()
    }

    // MARK: - 目印

    /// 領域の正規化した位置を、窓の座標 (左下原点の point) へ。
    private func viewPoint(_ point: Point, in region: MappingConfig.Region) -> CGPoint {
        let x = (region.rect.x + point.x * region.rect.width) * bounds.width
        let yFromTop = (region.rect.y + point.y * region.rect.height) * bounds.height
        return CGPoint(x: x, y: bounds.height - yFromTop)
    }

    /// 窓の座標を、領域の中の正規化した位置へ。
    private func regionPoint(_ point: CGPoint, in region: MappingConfig.Region) -> Point {
        let xInDisplay = point.x / bounds.width
        let yInDisplay = (bounds.height - point.y) / bounds.height
        return Point(
            x: (xInDisplay - region.rect.x) / region.rect.width, y: (yInDisplay - region.rect.y) / region.rect.height)
    }

    private func refreshOverlayIfNeeded() {
        let state = (
            revision: context.document.revision, showsHandles: session.showsKeystoneHandles, size: bounds.size,
            selected: selected.map { "\($0.region)-\($0.corner)" } ?? ""
        )
        if let drawnState, drawnState == state { return }
        drawnState = state
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        overlay.sublayers = nil
        guard state.showsHandles else { return }
        for region in regions {
            let points = region.keystone.map { viewPoint($0, in: region) }
            let outline = CAShapeLayer()
            let path = CGMutablePath()
            path.addLines(between: points + [points[0]])
            outline.path = path
            outline.strokeColor = NSColor.systemYellow.cgColor
            outline.fillColor = nil
            outline.lineWidth = 1
            overlay.addSublayer(outline)
            for (cornerIndex, point) in points.enumerated() {
                let handle = CAShapeLayer()
                let size: CGFloat = 14
                handle.path = CGPath(
                    rect: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size), transform: nil)
                let isSelected = selected.map { $0.region == region.id && $0.corner == cornerIndex } ?? false
                handle.fillColor = (isSelected ? NSColor.systemRed : NSColor.systemYellow).withAlphaComponent(0.6).cgColor
                handle.strokeColor = NSColor.white.cgColor
                overlay.addSublayer(handle)
            }
        }
    }

    // MARK: - 操作

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard session.showsKeystoneHandles else { return }
        let location = convert(event.locationInWindow, from: nil)
        var nearest: (region: MappingConfig.RegionID, corner: Int, distance: CGFloat)?
        for region in regions {
            for (cornerIndex, corner) in region.keystone.enumerated() {
                let point = viewPoint(corner, in: region)
                let distance = hypot(point.x - location.x, point.y - location.y)
                if distance < 32, distance < (nearest?.distance ?? .infinity) {
                    nearest = (region.id, cornerIndex, distance)
                }
            }
        }
        selected = nearest.map { ($0.region, $0.corner) }
        if let selected {
            session.selection.select(.region(selected.region))
            context.document.beginGesture("台形補正を動かす")
        }
        refreshOverlayIfNeeded()
    }

    override func mouseDragged(with event: NSEvent) {
        guard session.showsKeystoneHandles, let selected,
            let region = context.document.config.region(selected.region)
        else { return }
        let location = convert(event.locationInWindow, from: nil)
        session.moveKeystoneCorner(selected.region, corner: selected.corner, to: regionPoint(location, in: region))
    }

    override func mouseUp(with event: NSEvent) {
        context.document.endGesture()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            onEscape()
            return
        }
        guard session.showsKeystoneHandles, let selected, let region = context.document.config.region(selected.region)
        else { return super.keyDown(with: event) }
        // 1 回で 1 画素 (shift で 10 画素) 動かす
        let scale = window?.backingScaleFactor ?? 2
        let step = (event.modifierFlags.contains(.shift) ? 10 : 1) / scale
        let dx = step / (bounds.width * region.rect.width)
        let dy = step / (bounds.height * region.rect.height)
        var corner = region.keystone[selected.corner]
        switch event.keyCode {
        case 123: corner.x -= dx
        case 124: corner.x += dx
        case 125: corner.y += dy
        case 126: corner.y -= dy
        default: return super.keyDown(with: event)
        }
        session.moveKeystoneCorner(selected.region, corner: selected.corner, to: corner)
    }
}
