// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeshMapping
import QuartzCore

/// 表示装置 1 つを覆う、縁の無い出力の窓。
///
/// 表示に合わせて起き (`NSView.displayLink`)、その時点の最新の絵を領域ごとに歪めて描く。
/// 編集のときは 4 隅の目印と輪郭を上に重ね、ドラッグと矢印のキーで隅を動かせる。
@MainActor
final class OutputWindow: NSWindow {
    let outputIndex: Int
    private let mapView: MapView

    /// - Parameter windowed: 表示装置を覆わず、普通の窓に出す (`--window`)。プロジェクタの無い
    ///   手元で歪めを確かめるためにある。窓の大きさが表示装置の代わりになる。
    init(screen: NSScreen, outputIndex: Int, model: AppModel, windowed: Bool = false) {
        self.outputIndex = outputIndex
        mapView = MapView(outputIndex: outputIndex, model: model)
        if windowed {
            let size = NSSize(width: 960, height: 540)
            super.init(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered,
                defer: false)
            title = "mokumesh 出力 \(outputIndex + 1) (\(screen.localizedName) の代わり)"
            setFrameOrigin(
                NSPoint(
                    x: screen.visibleFrame.midX - size.width / 2 + CGFloat(outputIndex) * 40,
                    y: screen.visibleFrame.midY - size.height / 2 - CGFloat(outputIndex) * 40))
        } else {
            super.init(
                contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            setFrame(screen.frame, display: false)
            // メニューバーより上に置く。プロジェクタの画面にメニューバーが出ていても隠れる
            level = .mainMenu + 1
            collectionBehavior = [.canJoinAllSpaces, .fullScreenNone, .stationary]
        }
        backgroundColor = .black
        isReleasedWhenClosed = false
        hasShadow = false
        contentView = mapView
    }

    override var canBecomeKey: Bool { true }

    func refreshOverlay() { mapView.refreshOverlay() }

    func stop() { mapView.stop() }
}

/// 出力の窓の中身。Metal の層に描き、編集の目印を別の層に重ねる。
@MainActor
final class MapView: NSView {
    private let outputIndex: Int
    private unowned let model: AppModel
    private let metalLayer = CAMetalLayer()
    private let overlay = CALayer()
    private var displayLink: CADisplayLink?
    /// ドラッグ中・矢印で動かす隅 (領域の番号と隅の番号)。
    private var selected: (region: Int, corner: Int)?

    init(outputIndex: Int, model: AppModel) {
        self.outputIndex = outputIndex
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        if let renderer = model.renderer {
            metalLayer.device = renderer.device
        }
        metalLayer.pixelFormat = Renderer.drawablePixelFormat
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
        layer?.addSublayer(metalLayer)
        layer?.addSublayer(overlay)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, displayLink == nil else { return }
        let link = displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        overlay.frame = bounds
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
        refreshOverlay()
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let renderer = model.renderer, bounds.width > 0 else { return }
        model.pullFrames()
        renderer.draw(
            regions: model.regions(of: outputIndex), frames: model.currentFrames, into: metalLayer,
            presented: model.presentedHandler())
    }

    // MARK: - 編集の目印

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
            x: (xInDisplay - region.rect.x) / region.rect.width,
            y: (yInDisplay - region.rect.y) / region.rect.height)
    }

    func refreshOverlay() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        overlay.sublayers = nil
        guard model.isEditing else { return }
        for (regionIndex, region) in model.regions(of: outputIndex).enumerated() {
            let points = region.corners.map { viewPoint($0, in: region) }
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
                    rect: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size),
                    transform: nil)
                let isSelected = selected.map { $0 == (regionIndex, cornerIndex) } ?? false
                handle.fillColor = (isSelected ? NSColor.systemRed : NSColor.systemYellow).withAlphaComponent(0.6).cgColor
                handle.strokeColor = NSColor.white.cgColor
                overlay.addSublayer(handle)
            }
        }
    }

    // MARK: - 操作

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard model.isEditing else { return }
        let location = convert(event.locationInWindow, from: nil)
        var nearest: (region: Int, corner: Int, distance: CGFloat)?
        for (regionIndex, region) in model.regions(of: outputIndex).enumerated() {
            for (cornerIndex, corner) in region.corners.enumerated() {
                let point = viewPoint(corner, in: region)
                let distance = hypot(point.x - location.x, point.y - location.y)
                if distance < 32, distance < (nearest?.distance ?? .infinity) {
                    nearest = (regionIndex, cornerIndex, distance)
                }
            }
        }
        selected = nearest.map { ($0.region, $0.corner) }
        refreshOverlay()
    }

    override func mouseDragged(with event: NSEvent) {
        guard model.isEditing, let selected else { return }
        let regions = model.regions(of: outputIndex)
        guard selected.region < regions.count else { return }
        let location = convert(event.locationInWindow, from: nil)
        model.moveCorner(
            output: outputIndex, region: selected.region, corner: selected.corner,
            to: regionPoint(location, in: regions[selected.region]))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            model.closeOutputsFromKeyboard()
            return
        }
        guard model.isEditing, let selected else { return super.keyDown(with: event) }
        let regions = model.regions(of: outputIndex)
        guard selected.region < regions.count else { return }
        let region = regions[selected.region]
        // 1 回で 1 画素 (shift で 10 画素) 動かす
        let scale = window?.backingScaleFactor ?? 2
        let step = (event.modifierFlags.contains(.shift) ? 10 : 1) / scale
        let dx = step / (bounds.width * region.rect.width)
        let dy = step / (bounds.height * region.rect.height)
        var corner = region.corners[selected.corner]
        switch event.keyCode {
        case 123: corner.x -= dx
        case 124: corner.x += dx
        case 125: corner.y += dy
        case 126: corner.y -= dy
        default: return super.keyDown(with: event)
        }
        model.moveCorner(output: outputIndex, region: selected.region, corner: selected.corner, to: corner)
    }
}
