<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# mokumesh

[mokume](https://github.com/mokume-metal/mokume) で作った作品を、プロジェクタで平面や立体物へ投影するためのマッピングのソフト (macOS / Apple Silicon・Swift + Metal)。MadMapper のような有料の道具に頼らずに、mokume の作品を本番へ出せるようにする。

> **状態: 作りはじめ。** 専用の受け渡しと Syphon から受け、映像の一部を切り取った面をステージに置き、複数のプロジェクタにまたがって台形補正して映すところまで。ペインの中で面と配置を編集すること・メッシュ・マスクの描画・ブレンド・3D はまだ無い。設計の土台は [ADR-0001](docs/decisions/0001-foundations.md)・[ADR-0002](docs/decisions/0002-stage-layers-projector-placement.md)・[ADR-0003](docs/decisions/0003-editor-architecture.md) にある。

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

## 入れる

[Releases](https://github.com/mokume-metal/mokumesh/releases) から `mokumesh-<版>.dmg` を落として開き、`mokumesh.app` を Applications へドラッグする (macOS 26 以降・Apple Silicon)。

**公証していないので、初回は Gatekeeper に止められる。** 一度開こうとしてから「システム設定 → プライバシーとセキュリティ」の「このまま開く」を押す。または端末で次を打つ。

```bash
xattr -dr com.apple.quarantine /Applications/mokumesh.app
```

.app から開くと操作窓が出る。`--config` などの引数を渡すときは `/Applications/mokumesh.app/Contents/MacOS/mokumesh --config mapping.json` のように中の実行ファイルを呼ぶ。

版を出すのは `v` で始まる tag の push で、[Release のワークフロー](.github/workflows/release.yml)が DMG を組んで Release に添える。手元で同じものを組むには `make dmg VERSION=0.1.0` (出力は `dist/`)。

## 映す

アプリは `App/` の別のパッケージにある (Syphon.xcframework を引くのはアプリだけにするため)。

```bash
swift run --package-path App mokumesh                          # 操作窓を出して較正する
swift run --package-path App mokumesh --config mapping.json    # 操作窓を出さずに、設定のとおりに映す (本番)
swift run --package-path App mokumesh --window                 # 出力を表示装置ではなく普通の窓に出す (プロジェクタの無い手元で)
```

操作窓は、左に**階層** (入力・面・プロジェクタ)、中央に 4 つのペイン (入力・ステージ・プロジェクタ配置・出力)、右に **inspector** を並べる。階層・ペイン・inspector は同じ選択を見る。構造は [ADR-0003](docs/decisions/0003-editor-architecture.md) にある。

1. 階層の左下の ＋ から「出力を足す」で、プロジェクタを繋いだ表示装置を選ぶ (表示装置が無い手元では「表示装置なし」)。面が無ければ、ステージを覆う面も 1 枚置かれる
2. 出力のペインで、出力ごとに出し方を選ぶ: **プレビューのみ** / **別窓** / **全画面** (全画面の先の表示装置も選べる)。表示装置が 1 台しか無くても、別窓で出力をいくつでも並べて見られる
3. 出力のペインの「4 隅」を入れ (表示メニューからも)、出力の窓の上で台形補正の隅をドラッグする。矢印キーで 1 画素、shift を押しながらで 10 画素ずつ動く。四角形が裏返る・凹む動きは採らない
4. 面は階層で足す・消す・名前を変える (ダブルクリック)・ドラッグで重なり順を変える。inspector で映像を選ぶ。どの操作も ⌘Z で取り消せる
5. ファイルメニューの「保存」(⌘S) で設定を JSON に書く (形式は [Schemas/mapping.schema.json](Schemas/mapping.schema.json)。版 1 の設定も読める)。本番は `--config` で読む
6. 出力の窓で Esc を押すと、その出力はプレビューのみに戻る (設定は残る。本番では効かない)

送り手が無いときは `swift run SendExample` で例のスケッチを送れる。

### Syphon から映す

Syphon の送り手 (他のアプリ・mokume-syphon を入れたスケッチ) は、階層の「入力」の節に `syphon:<アプリ名>/<サーバー名>` として並ぶ。面を選び、inspector の「映像」で選ぶとその面に映る。Syphon の慣習に従い、届いた色は乗算済みの alpha として扱う。

### 遅れを測る

専用の受け渡しと Syphon を、同じ絵・同じ物差しで並べて測れる。送り手は絵の上端に、描いた瞬間の時刻を符号として描く。mokumesh はそれを読み、受け手に届いた時刻と、提示された時刻との差を道ごとに数える。

```bash
swift run --package-path App LatencyBench 40     # 1920×1080・60fps で両方の道へ送る
swift run --package-path App mokumesh --config <左右に 2 つの領域を持つ設定> --window --measure 1200
```

設定では、左の領域に映像 `bench` を、右の領域に `syphon:LatencyBench/LatencyBench` を割り当てる。
- mokume は mokumesh を知らない。mokumesh の側が mokume の版に追随する

## ライセンス

MIT
