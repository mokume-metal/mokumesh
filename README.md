<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# mokumesh

[mokume](https://github.com/mokume-metal/mokume) で作った作品を、プロジェクタで平面や立体物へ投影するためのマッピングのソフト (macOS / Apple Silicon・Swift + Metal)。MadMapper のような有料の道具に頼らずに、mokume の作品を本番へ出せるようにする。

> **状態: 作りはじめ。** 1 つの領域を 4 点合わせで映すところまで。メッシュ・マスク・ブレンド・3D・Syphon の受け口はまだ無い。設計の土台は [ADR-0001](docs/decisions/0001-foundations.md) にある。

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

受け手が起きていなくてもスケッチは止まらず、受け手が現れたところから渡し始める。

## 映す

```bash
swift run mokumesh                          # 操作窓を出して較正する
swift run mokumesh --config mapping.json    # 操作窓を出さずに、設定のとおりに映す (本番)
swift run mokumesh --window                 # 出力を表示装置ではなく普通の窓に出す (プロジェクタの無い手元で)
```

1. 操作窓の「表示装置」で、プロジェクタを繋いだ表示装置を入れる。その表示装置を縁の無い窓が覆う
2. 「4 隅を動かす」を入れ、出力の窓の上で隅をドラッグする。矢印キーで 1 画素、shift を押しながらで 10 画素ずつ動く。四角形が裏返る・凹む動きは採らない
3. 「保存」で設定を JSON に書く (形式は [Schemas/mapping.schema.json](Schemas/mapping.schema.json))。本番は `--config` で読む
4. 出力の窓で Esc を押すと、映すのをやめる (本番では効かない)

送り手が無いときは `swift run SendExample` で例のスケッチを送れる。
- mokume は mokumesh を知らない。mokumesh の側が mokume の版に追随する

## ライセンス

MIT
