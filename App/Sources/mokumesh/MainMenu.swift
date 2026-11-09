// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import MokumeshEditor

/// アプリのメニュー。
///
/// 項目は標準の selector (`undo:`・`saveDocument:`・`toggleSidebar:` など) か、操作窓の
/// `WorkspaceWindowController` が受ける selector を、target を持たずに送る。受け手は
/// responder chain で決まり、使えるかどうかは受け手の `validateMenuItem` が決める
/// (ADR-0003 決定 8)。
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu("mokumesh", [
            item("mokumesh を隠す", #selector(NSApplication.hide(_:)), "h"),
            .separator(),
            item("mokumesh を終了", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        menu.addItem(submenu("ファイル", [
            item("新規", #selector(AppDelegate.newDocument(_:)), "n"),
            item("開く…", #selector(AppDelegate.openDocument(_:)), "o"),
            .separator(),
            item("保存", #selector(AppDelegate.saveDocument(_:)), "s"),
            item("別名で保存…", #selector(AppDelegate.saveDocumentAs(_:)), "s", [.command, .shift]),
            .separator(),
            item("閉じる", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        menu.addItem(submenu("編集", [
            item("取り消す", Selector(("undo:")), "z"),
            item("やり直す", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("カット", #selector(NSText.cut(_:)), "x"),
            item("コピー", #selector(NSText.copy(_:)), "c"),
            item("ペースト", #selector(NSText.paste(_:)), "v"),
            item("すべてを選択", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("面を足す", #selector(WorkspaceWindowController.addSurface(_:)), "n", [.command, .shift]),
            // 素の ⌫ は文字の入力に要るので、⌘⌫ にする (階層では素の ⌫ も効く)
            item("消す", #selector(NSText.delete(_:)), "\u{8}"),
        ]))
        var viewItems: [NSMenuItem] = [
            item("サイドバー", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
            item("インスペクタ", #selector(NSSplitViewController.toggleInspector(_:)), "i", [.command, .option]),
            .separator(),
        ]
        for (index, pane) in PaneKind.allCases.enumerated() {
            let paneItem = item(
                "\(pane.title)を最大化", #selector(WorkspaceWindowController.togglePaneMaximized(_:)), "\(index + 1)")
            paneItem.tag = index
            viewItems.append(paneItem)
        }
        viewItems += [
            .separator(),
            item(
                "台形補正の 4 隅を出力の窓に出す", #selector(WorkspaceWindowController.toggleKeystoneHandles(_:)), "k",
                [.command, .option]),
        ]
        menu.addItem(submenu("表示", viewItems))
        let window = submenu("ウインドウ", [
            item("しまう", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("拡大/縮小", #selector(NSWindow.performZoom(_:)), ""),
        ])
        NSApp.windowsMenu = window.submenu
        menu.addItem(window)
        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        item.submenu = submenu
        return item
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
