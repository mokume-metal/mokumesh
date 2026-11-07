<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# mokumesh

[mokume](https://github.com/mokume-metal/mokume) で作った作品を、プロジェクタで平面や立体物へ投影するためのマッピングのソフト (macOS / Apple Silicon・Swift + Metal)。MadMapper のような有料の道具に頼らずに、mokume の作品を本番へ出せるようにする。

> **状態: 作りはじめ。** 受け渡しの約束・送り手の部品・受け手のライブラリまで。マッピングのアプリはまだ無い。設計の土台は [ADR-0001](docs/decisions/0001-foundations.md) にある。

## するもの

- **位置合わせと幾何学的な変換**: 2D (4 点合わせ・メッシュ) と 3D (立体物のモデルとプロジェクタの較正)
- **マスク**と、プロジェクタが重なる部分の**ブレンド**
- **複数のプロジェクタの管理**: Mac に繋いだ複数の表示装置に加え、分配器で 1 本の出力を複数台に割る構成も扱う
- **較正の GUI**: 結果は差分の読めるテキスト (JSON Schema つき) に残す

## しないもの

動画の読み込み・シーンの切り替え・キュー・タイムライン・エフェクトは扱わない。**それは作品の仕事**で、mokume のスケッチの側で書く。mokumesh は届いた絵を正しい場所へ正しい形で映すことだけをする。

## mokume との関係

- 絵は **Syphon** でも、mokumesh が配る**専用の受け渡し**でも受け取れる。専用の受け渡しは、フレームの番号と時刻・名前つきの映像を運び、面を他のプロセスから読める形にしない。Syphon で送る他のアプリの絵も映せる
- 専用の受け渡しは、いまは Syphon と同じ 8 bit・コピー 1 回である。mokume に汎用の出口の口 (コピー 0 回・半精度) が入ったら、送り手の部品だけを差し替えて上回る ([ADR-0001](docs/decisions/0001-foundations.md) 決定 3 の改訂)

## スケッチから送る

```swift
// Package.swift
.package(url: "https://github.com/mokume-metal/mokumesh.git", branch: "main")
// ターゲットの dependencies
.product(name: "MokumeshSender", package: "mokumesh")
```

```swift
import mokume
import MokumeshSender

@main
final class MySketch: Sketch {
    let mokumesh = MokumeshPlugin(sending: "main")
    var plugins: [any Plugin] { [mokumesh] }

    func draw() { /* ... */ }
}
```

受け手が起きていなくてもスケッチは止まらず、受け手が現れたところから渡し始める。受け手のアプリはまだ無い。手元で確かめるには `swift run ReceiveProbe` と `swift run SendExample` を並べて走らせる
- mokume は mokumesh を知らない。mokumesh の側が mokume の版に追随する

## ライセンス

MIT
