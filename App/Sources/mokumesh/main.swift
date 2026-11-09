// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation

// mokumesh — 届いた絵を、表示装置ごとに 4 点合わせで歪めて映す。
//
//   mokumesh                       操作窓を出して較正する
//   mokumesh --config <file>       操作窓を出さずに、設定のとおりに映す (本番)
//   mokumesh --channel <name>      受け手のチャンネルを選ぶ (既定は default)
//   mokumesh --window              出力を表示装置ではなく普通の窓に出す (プロジェクタの無い手元で確かめる)
//   mokumesh --measure <枚数>      LatencyBench の絵を映し、描いてから提示されるまでを道ごとに測って終わる

struct Arguments {
    var configPath: String?
    var channel: String?
    var windowed = false
    var measure: Int?

    init(_ arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--config": configPath = iterator.next()
            case "--channel": channel = iterator.next()
            case "--window": windowed = true
            case "--measure": measure = iterator.next().flatMap(Int.init)
            case "--help", "-h":
                print("使い方: mokumesh [--config <file>] [--channel <name>] [--window] [--measure <枚数>]")
                exit(0)
            default:
                FileHandle.standardError.write(Data("知らない引数: \(argument)\n".utf8))
                exit(2)
            }
        }
    }
}

// 端末でなくても 1 行ずつ出す (計測の途中経過を、パイプやファイルへ落とさず届ける)
setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Arguments(CommandLine.arguments)
let application = NSApplication.shared
application.setActivationPolicy(.regular)
let delegate = AppDelegate(arguments: arguments)
application.delegate = delegate
application.mainMenu = MainMenu.make()
application.run()
