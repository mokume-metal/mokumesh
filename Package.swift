// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import PackageDescription

// mokumesh — mokume の作品をプロジェクタへ映すマッピングのソフト。
//
// 受け渡しの約束と受け手 (MokumeshLink) は mokume に依存しない。mokume に依存するのは、
// スケッチの plugins に入れる送り手の部品 (MokumeshSender) と、その検査・例だけである。
// mokume は mokumesh を知らず、mokumesh が mokume に追随する (docs/decisions/0001)。

let package = Package(
    name: "mokumesh",
    // mokume と同じ床 (mokume の ADR-0009)
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MokumeshLink", targets: ["MokumeshLink"]),
        .library(name: "MokumeshSender", targets: ["MokumeshSender"]),
    ],
    dependencies: [
        // 0.x の間は minor で壊れうるので upToNextMinor で張る (mokume の ADR-0024 決定 9)
        .package(url: "https://github.com/mokume-metal/mokume.git", .upToNextMinor(from: "0.42.0"))
    ],
    targets: [
        .target(name: "MokumeshLinkC"),
        .target(
            name: "MokumeshLink", dependencies: ["MokumeshLinkC"],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .target(
            name: "MokumeshSender",
            dependencies: ["MokumeshLink", .product(name: "mokume", package: "mokume")],
            swiftSettings: .mokume),
        .testTarget(
            name: "MokumeshLinkTests", dependencies: ["MokumeshLink", "MokumeshLinkC"],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(
            name: "MokumeshSenderTests",
            dependencies: ["MokumeshSender", "MokumeshLink", .product(name: "mokume", package: "mokume")],
            swiftSettings: .mokume),
        // 例。product には含めない — 使い方を示すもの
        .executableTarget(
            name: "SendExample", dependencies: ["MokumeshSender", .product(name: "mokume", package: "mokume")],
            path: "Examples/Send", swiftSettings: .mokume),
        .executableTarget(
            name: "ReceiveProbe", dependencies: ["MokumeshLink"], path: "Examples/ReceiveProbe",
            swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)

extension [SwiftSetting] {
    /// mokume と同じ言語設定 (Swift 6 と、既定の隔離を main actor にする — mokume の ADR-0010 決定 1)。
    /// 差込口は mokume の main actor 隔離された型を受けるので、ここが揃っていないと準拠のたびに注釈が要る。
    static var mokume: [SwiftSetting] {
        [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
    }
}
