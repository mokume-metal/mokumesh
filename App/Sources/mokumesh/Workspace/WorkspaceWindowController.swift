// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeshEditor
import SwiftUI

/// 操作窓。階層・中央のペイン・inspector を `NSSplitViewController` の 3 項目に並べる
/// (ADR-0003 決定 8)。
///
/// メニューの項目 (面を足す・消す・ペインの最大化など) は responder chain でここに届く。
@MainActor
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    private unowned let context: AppContext
    private var session: EditorSession { context.session }

    init(context: AppContext) {
        self.context = context
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 960, height: 600)
        window.tabbingMode = .disallowed

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: Self.host(HierarchyView(context: context)))
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 380
        let content = NSSplitViewItem(viewController: Self.host(WorkspaceContentView(context: context)))
        content.minimumThickness = 480
        let inspector = NSSplitViewItem(inspectorWithViewController: Self.host(InspectorView(context: context)))
        inspector.minimumThickness = 240
        inspector.maximumThickness = 420
        split.splitViewItems = [sidebar, content, inspector]
        // 仕切りの位置を次の起動へ残す
        split.splitView.autosaveName = "mokumesh.workspace.split"
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1440, height: 900))
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("mokumesh.workspace") { window.center() }
        window.setFrameAutosaveName("mokumesh.workspace")
        context.document.observeChanges { [weak self] _, _ in self?.refreshTitle() }
        refreshTitle()
        updateControlDisplay()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) は使わない") }

    /// SwiftUI の中身を包む。中身の大きさで窓の大きさを縛らせない。
    private static func host(_ view: some View) -> NSViewController {
        let controller = NSHostingController(rootView: view)
        controller.sizingOptions = []
        return controller
    }

    /// 窓の題にファイル名と未保存の印を出す。
    func refreshTitle() {
        guard let window else { return }
        let url = context.document.fileURL
        window.title = url?.lastPathComponent ?? "名称未設定"
        window.representedURL = url
        window.isDocumentEdited = context.document.isDirty
    }

    /// 操作窓の載っている表示装置を、出し方の決まりに知らせる (そこを全画面で覆わないため)。
    private func updateControlDisplay() {
        session.policy.controlDisplayID = window?.screen.flatMap(DisplayMonitor.displayID(of:))
    }

    // MARK: - NSWindowDelegate

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        context.undoManager
    }

    func windowDidChangeScreen(_ notification: Notification) {
        updateControlDisplay()
    }

    /// 操作窓を閉じるのはアプリを終えること (保存していなければ尋ねる)。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApp.terminate(nil)
        return false
    }

    // MARK: - メニュー

    @objc func addSurface(_ sender: Any?) {
        session.addSurface()
    }

    @objc func delete(_ sender: Any?) {
        session.deleteSelection()
    }

    @objc func togglePaneMaximized(_ sender: NSMenuItem) {
        guard PaneKind.allCases.indices.contains(sender.tag) else { return }
        session.paneLayout.toggleMaximized(PaneKind.allCases[sender.tag])
    }

    @objc func toggleKeystoneHandles(_ sender: Any?) {
        session.showsKeystoneHandles.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(delete(_:)):
            return session.canDeleteSelection
        case #selector(togglePaneMaximized(_:)):
            let pane = PaneKind.allCases.indices.contains(menuItem.tag) ? PaneKind.allCases[menuItem.tag] : nil
            menuItem.state = pane != nil && session.paneLayout.maximized == pane ? .on : .off
            return pane != nil
        case #selector(toggleKeystoneHandles(_:)):
            menuItem.state = session.showsKeystoneHandles ? .on : .off
            return true
        default:
            return true
        }
    }
}
