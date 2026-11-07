// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import MokumeshMapping
import SwiftUI

// mokumesh — 届いた絵を、表示装置ごとに 4 点合わせで歪めて映す。
//
//   mokumesh                       操作窓を出して較正する
//   mokumesh --config <file>       操作窓を出さずに、設定のとおりに映す (本番)
//   mokumesh --channel <name>      受け手のチャンネルを選ぶ (既定は default)

struct Arguments {
    var configPath: String?
    var channel: String?

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--config": configPath = iterator.next()
            case "--channel": channel = iterator.next()
            case "--help", "-h":
                print("使い方: mokumesh [--config <file>] [--channel <name>]")
                exit(0)
            default:
                FileHandle.standardError.write(Data("知らない引数: \(argument)\n".utf8))
                exit(2)
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let arguments: Arguments
    var model: AppModel?
    var controlWindow: NSWindow?

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

        let model = AppModel(config: config)
        model.configURL = configURL
        self.model = model
        if let error = model.receiverError {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
        }

        if configURL != nil {
            // 本番: 操作窓を出さずに映す
            model.isProduction = true
            model.rebuildWindows()
            if let message = model.lastMessage {
                FileHandle.standardError.write(Data("\(message)\n".utf8))
            }
        } else {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
                defer: false)
            window.title = "mokumesh"
            window.contentViewController = NSHostingController(rootView: ControlView(model: model))
            window.center()
            window.makeKeyAndOrderFront(nil)
            controlWindow = window
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        controlWindow != nil
    }
}

let arguments = Arguments(CommandLine.arguments)
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate(arguments: arguments)
application.delegate = delegate
application.mainMenu = {
    let menu = NSMenu()
    let appItem = NSMenuItem()
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "mokumesh を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    appItem.submenu = appMenu
    menu.addItem(appItem)
    return menu
}()
application.run()
