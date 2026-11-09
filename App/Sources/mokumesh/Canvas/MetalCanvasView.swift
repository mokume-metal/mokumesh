// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeshEditor
import QuartzCore

/// Metal で描く場所 1 つ。出力の窓も各ペインもこれで描く (ADR-0003 決定 6)。
///
/// 表示に合わせて起き (`NSView.displayLink`)、`FrameHub` から最新の絵を受け、`scene` が
/// 返すものを `Renderer` で描く。窓から外れたら起きるのをやめ、見えていない・大きさが 0 の
/// ときは描かない (隠れた窓で drawable を待つと main thread が止まる)。
@MainActor
final class MetalCanvasView: NSView {
    private let hub: FrameHub
    private let metalLayer = CAMetalLayer()
    private var displayLink: CADisplayLink?

    /// 描く中身。描く直前に、いまの大きさ (point) で呼ぶ。
    var scene: (CGSize) -> RenderScene? = { _ in nil }
    /// 提示の時刻を受け取る先 (計測)。出力の窓にだけ渡す。ペインの提示を計測に混ぜない。
    var presented: (@Sendable (Double, [SourceFrame]) -> Void)?

    init(hub: FrameHub) {
        self.hub = hub
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        if let renderer = hub.renderer { metalLayer.device = renderer.device }
        metalLayer.pixelFormat = Renderer.drawablePixelFormat
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.allowsNextDrawableTimeout = true
        layer?.addSublayer(metalLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // displayLink は target を強く持つので、窓から外れたら必ず止める
        if window == nil {
            stop()
        } else if displayLink == nil {
            let link = displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
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
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let renderer = hub.renderer, bounds.width > 0, bounds.height > 0,
            let window, window.occlusionState.contains(.visible)
        else { return }
        let frames = hub.framesForDrawing(at: link.timestamp)
        guard let scene = scene(bounds.size) else { return }
        renderer.draw(
            regions: scene.regions, layers: scene.layers, frames: frames, into: metalLayer, presented: presented)
    }
}
