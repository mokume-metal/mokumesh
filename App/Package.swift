// swift-tools-version: 6.2
// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import PackageDescription

// mokumesh のアプリ。根のパッケージ (受け渡し・マッピング) をパスで使い、Syphon を引く。
//
// 根と分けるのは、Syphon.xcframework (binaryTarget) をスケッチの利用者に引かせないため
// (根の Package.swift の冒頭)。Syphon は mokume-syphon の Release の資産を、版と checksum で
// 固定して引く (同じ org の成果物)。

// 根を path で引くと、その package の名前は根のディレクトリ名 (symlink を解いた実パスの
// 末尾) で決まり、`.package(name:path:)` は廃止済みで指定できない。"mokumesh" と書くと、
// 名前の違う checkout や worktree で組めなくなるので、自分の場所から求める (#13)。
// CI はこれを確かめるため、わざと mokumesh 以外の名前で checkout する (.github/workflows/ci.yml)。
let root = URL(fileURLWithPath: Context.packageDirectory)
    .resolvingSymlinksInPath()
    .deletingLastPathComponent()
    .lastPathComponent

let package = Package(
    name: "mokumesh-app",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "mokumesh", targets: ["mokumesh"])
    ],
    dependencies: [
        .package(path: ".."),
        // 計測のための送り手 (Examples/LatencyBench) だけが使う
        .package(url: "https://github.com/mokume-metal/mokume.git", .upToNextMinor(from: "0.42.0")),
    ],
    targets: [
        .binaryTarget(
            name: "Syphon",
            url:
                "https://github.com/mokume-metal/mokume-syphon/releases/download/v0.3.0/Syphon.xcframework.zip",
            checksum: "d129edd420d700cb7512e9c93db596f17dbd1907abb6766439af93ccfc8b6801"),
        .executableTarget(
            name: "mokumesh",
            dependencies: [
                .product(name: "MokumeshLink", package: root),
                .product(name: "MokumeshMapping", package: root),
                "Syphon",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]),
        // 専用の受け渡しと Syphon の遅れを並べて測る
        .executableTarget(
            name: "LatencyBench",
            dependencies: [
                .product(name: "MokumeshLink", package: root),
                .product(name: "MokumeshSender", package: root),
                .product(name: "mokume", package: "mokume"),
                "Syphon",
            ],
            path: "Examples/LatencyBench",
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]),
    ]
)
