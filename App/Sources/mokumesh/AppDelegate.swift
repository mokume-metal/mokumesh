// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeshEditor
import MokumeshMapping
import UniformTypeIdentifiers

/// アプリの組み立て (composition root)。部品をつなぐのはここだけ (ADR-0003 決定 1)。
///
/// 起動は 3 通りあり、組み立て方だけが違う。
///
/// | 起動 | 操作窓 | 出力の出し方 |
/// | --- | --- | --- |
/// | 編集 (引数なし) | 出す | 出力ごとに選ぶ (既定は `PresentationPolicy.initialMode`) |
/// | 本番 (`--config`) | 出さない | 全部を全画面 (`--window` なら窓) |
/// | 計測 (`--measure`) | どちらにも重ねる | 提示の時刻を出力の窓からだけ取る |
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let arguments: Arguments
    private var context: AppContext?
    private var outputs: OutputWindowController?
    private var workspace: WorkspaceWindowController?

    init(arguments: Arguments) {
        self.arguments = arguments
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        var config = MappingConfig()
        var configURL: URL?
        if let path = arguments.configPath {
            let url = URL(fileURLWithPath: path)
            do {
                config = try MappingConfig.decode(Data(contentsOf: url))
                configURL = url
            } catch {
                FileHandle.standardError.write(Data("設定を読めない: \(path): \(error)\n".utf8))
                exit(1)
            }
        }
        if let channel = arguments.channel { config.channel = channel }

        let isProduction = configURL != nil
        let document = EditorDocument(config: config, fileURL: configURL)
        let displays = DisplayMonitor()
        let session = EditorSession(
            document: document, policy: PresentationPolicy(windowedOnly: arguments.windowed),
            displays: displays.displays)
        let hub = FrameHub(renderer: Renderer())
        let context = AppContext(
            document: document, session: session, hub: hub, displays: displays, isProduction: isProduction)
        self.context = context

        // サービス → 編集の状態
        hub.wanted = { [unowned session] in session.wantedStreams }
        hub.onStreamsChanged = { [unowned session] in session.setAvailableStreams($0) }
        hub.onSizeChanged = { [unowned session] in session.setStreamSize($1, for: $0) }
        displays.onChange = { [unowned session] in session.setDisplays($0) }
        hub.startReceiver(channel: config.channel)
        context.status.receiverError = hub.receiverError
        hub.watchStreams()

        // 編集の状態 → 出力の窓
        let outputs = OutputWindowController(context: context)
        self.outputs = outputs
        session.observePlan { [unowned outputs] in outputs.reconcile() }
        document.observeChanges { [unowned hub, unowned context] old, new in
            if old.channel != new.channel {
                hub.startReceiver(channel: new.channel)
                context.status.receiverError = hub.receiverError
            }
        }

        if let target = arguments.measure {
            let measurement = Measurement(target: target) { report in
                print(report)
                exit(0)
            }
            hub.isMeasuring = true
            print("映せる映像: \(hub.streams.joined(separator: ", "))")
            outputs.presented = { measurement.presented(at: $0, frames: $1) }
            outputs.floatsWindows = arguments.windowed
        }
        if let error = hub.receiverError {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
        }

        if isProduction {
            // 本番: 操作窓を出さずに、全部の出力を映す
            session.setAllModes(.fullscreen)
            let missing = session.missingDisplays.map(\.display.name)
            if !missing.isEmpty {
                FileHandle.standardError.write(Data("見つからない表示装置: \(missing.joined(separator: ", "))\n".utf8))
            }
        } else {
            let workspace = WorkspaceWindowController(context: context)
            self.workspace = workspace
            workspace.showWindow(nil)
        }
        outputs.reconcile()
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        workspace != nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard workspace != nil, let context, context.document.isDirty else { return .terminateNow }
        return confirmDiscardingChanges(context, action: "終了") ? .terminateNow : .terminateCancel
    }

    // MARK: - ファイル (メニューから responder chain で届く)

    @objc func newDocument(_ sender: Any?) {
        guard let context, confirmDiscardingChanges(context, action: "新しくする") else { return }
        context.document.replace(with: MappingConfig(channel: context.document.config.channel), fileURL: nil)
        context.status.message = nil
        workspace?.refreshTitle()
    }

    @objc func openDocument(_ sender: Any?) {
        guard let context, confirmDiscardingChanges(context, action: "読み込む") else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try context.document.load(from: url)
            context.status.message = "読み込んだ: \(url.lastPathComponent)"
        } catch {
            context.status.message = "読み込めなかった: \(error)"
        }
        workspace?.refreshTitle()
    }

    @objc func saveDocument(_ sender: Any?) {
        guard let context else { return }
        if let url = context.document.fileURL {
            save(context, to: url)
        } else {
            saveDocumentAs(sender)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        guard let context else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = context.document.fileURL?.lastPathComponent ?? "mapping.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(context, to: url)
    }

    @discardableResult
    private func save(_ context: AppContext, to url: URL) -> Bool {
        do {
            try context.document.save(to: url)
            context.status.message = "保存した: \(url.lastPathComponent)"
            workspace?.refreshTitle()
            return true
        } catch {
            context.status.message = "保存できなかった: \(error.localizedDescription)"
            return false
        }
    }

    /// 保存していない変更があれば、保存するか捨てるかを尋ねる。続けてよければ `true`。
    private func confirmDiscardingChanges(_ context: AppContext, action: String) -> Bool {
        guard context.document.isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = "保存していない変更があります"
        alert.informativeText = "\(action)前に保存しますか? 保存しないと変更は失われます。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "保存しない")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            saveDocument(nil)
            return !context.document.isDirty
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard workspace != nil else { return false }
        return true
    }
}
