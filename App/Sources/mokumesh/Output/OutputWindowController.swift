// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeshEditor
import MokumeshMapping

/// 望んだ出し方に合わせて、出力の窓を開け閉めする (ADR-0003 決定 7)。
///
/// `EditorSession.windowPlan` (開いておくべき窓の組) と、いま開いている窓を比べ、違うものだけを
/// 閉じて開く。全部を閉じて開き直さないので、出し方を変えていない出力の窓は動かない。
@MainActor
final class OutputWindowController: NSObject, NSWindowDelegate {
    private unowned let context: AppContext
    private var windows: [MappingConfig.OutputID: OutputWindow] = [:]
    /// 提示の時刻を受け取る先 (計測)。出力の窓にだけ渡す。
    var presented: (@Sendable (Double, [SourceFrame]) -> Void)?
    /// 計測のときは、窓が他の窓の後ろに回って提示が止まらないよう前面に浮かせる。
    var floatsWindows = false

    init(context: AppContext) {
        self.context = context
        super.init()
    }

    /// いま開いている出力の窓 (計測の終わりと試験のため)。
    var openOutputs: Set<MappingConfig.OutputID> { Set(windows.keys) }

    func reconcile() {
        let plan = context.session.windowPlan
        for (id, window) in windows where plan[id] != window.target {
            close(id)
        }
        let config = context.document.config
        for (index, output) in config.outputs.enumerated() {
            guard windows[output.id] == nil, let target = plan[output.id], let screen = screen(for: target) else {
                windows[output.id]?.refreshTitle(config)
                continue
            }
            let window = OutputWindow(
                outputID: output.id, target: target, screen: screen, index: index, context: context
            ) { [weak self] in
                self?.escape(from: output.id)
            }
            window.delegate = self
            window.presented = presented
            if floatsWindows, case .window = target { window.level = .floating }
            window.orderFrontRegardless()
            windows[output.id] = window
        }
        if context.isProduction, windows.values.contains(where: { if case .fullscreen = $0.target { true } else { false } })
        {
            NSCursor.hide()
        }
    }

    func closeAll() {
        for id in Array(windows.keys) { close(id) }
    }

    private func close(_ id: MappingConfig.OutputID) {
        guard let window = windows.removeValue(forKey: id) else { return }
        window.delegate = nil
        window.stop()
        window.close()
    }

    private func screen(for target: OutputWindowTarget) -> NSScreen? {
        switch target {
        case .window: NSScreen.main ?? NSScreen.screens.first
        case .fullscreen(let displayID): context.displays.screen(for: displayID)
        }
    }

    /// Esc: 本番では何もしない。操作窓があるときは、その出力をプレビューだけに戻す
    /// (設定は消さない)。
    private func escape(from id: MappingConfig.OutputID) {
        guard !context.isProduction else { return }
        context.session.setMode(.preview, for: id)
    }

    // MARK: - NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        context.undoManager
    }

    /// 人が窓を閉じたら、その出力はプレビューだけにする (望んだ出し方と窓を食い違わせない)。
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? OutputWindow, windows[window.outputID] === window else { return }
        windows[window.outputID] = nil
        window.stop()
        if !context.isProduction { context.session.setMode(.preview, for: window.outputID) }
    }
}
