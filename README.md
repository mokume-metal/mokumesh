<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# mokumesh

[mokume](https://github.com/mokume-metal/mokume) で作った作品を、プロジェクタで平面や立体物へ投影するためのマッピングのソフト (macOS / Apple Silicon・Swift + Metal)。MadMapper のような有料の道具に頼らずに、mokume の作品を本番へ出せるようにする。

> **状態: 設計段階。** まだコードはありません。設計の土台は [ADR-0001](docs/decisions/0001-foundations.md) にあります。

## するもの

- **位置合わせと幾何学的な変換**: 2D (4 点合わせ・メッシュ) と 3D (立体物のモデルとプロジェクタの較正)
- **マスク**と、プロジェクタが重なる部分の**ブレンド**
- **複数のプロジェクタの管理**: Mac に繋いだ複数の表示装置に加え、分配器で 1 本の出力を複数台に割る構成も扱う
- **較正の GUI**: 結果は差分の読めるテキスト (JSON Schema つき) に残す

## しないもの

動画の読み込み・シーンの切り替え・キュー・タイムライン・エフェクトは扱わない。**それは作品の仕事**で、mokume のスケッチの側で書く。mokumesh は届いた絵を正しい場所へ正しい形で映すことだけをする。

## mokume との関係

- 絵は **Syphon** でも、mokumesh が配る**専用の受け渡し** (半精度のまま・コピー無し・フレームの時刻つき) でも受け取れる。Syphon で送る他のアプリの絵も映せる
- mokume は mokumesh を知らない。mokumesh の側が mokume の版に追随する

## ライセンス

MIT
