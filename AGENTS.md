<!--
SPDX-FileCopyrightText: 2026 mokume-metal
SPDX-License-Identifier: MIT
-->

# AGENTS.md

**規約の正典は [mokume の AGENTS.md](https://github.com/mokume-metal/mokume/blob/main/AGENTS.md) である。**
Issue の起こし方・分類・コメントの置き場・コミットと PR の書式・機構を足す順序 (実害 → Issue → 機構) は、あちらを読んで同じように振る舞う。**ここには写しを置かない。** 写せばドリフトし、どちらが正かを言えなくなる ([mokume の ADR-0026](https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0026-plugin-repository-alignment.md) 決定 3)。

このファイルが持つのは、**このリポジトリだけで違うこと**だけである。

## 違うこと

| | mokume | ここ |
| --- | --- | --- |
| 設計判断の正典 | `docs/decisions/` の ADR | **持つ** (`docs/decisions/`)。書くのはマッピングに固有の判断だけである。mokume の ADR と食い違う判断が要るときは、ここに書かずに mokume 側へ Issue を立てる。土台は [ADR-0001](docs/decisions/0001-foundations.md) |
| 本体との関係 | — | **mokume は mokumesh を知らない。** 本体の版への追随・本体の変化で壊れたことへの気付きは、すべてこちらが負う (ADR-0001 決定 2) |
| 範囲 | 絵と動きを作る | **マッピングだけ。** 動画の読み込み・シーンの切り替えのような作品の仕事は、ここに足さず作品の側で書く (ADR-0001 決定 1) |
| 検査 | `make ci-check` (多数) | `make ci-check` (**build・test・schemas・reuse-lint の 4 本**)。GitHub のランナーには mokume の描画に足る GPU が無いので、GPU の Suite は CI で飛ぶ (受け渡しの約束の検査は走る)。GPU の Suite は手元で回す |
| PR の identity | メンテナ自身の `gh` 認証で作り、承認は要求しない | **同じ** |
| ブランチ保護 | ruleset | **まだ無い** (mokume の ADR-0026 第 2 段。別の Issue で入れる) |
| バイナリ | 1 つもコミットしない | **同じ。** 視覚的な証跡も外部へ上げて URL で参照する |
| コメントの署名 | `scripts/comment.sh` が付ける | 素の `gh` で書き、同じ署名の 1 行を手で付ける (mokume の ADR-0026 決定 4) |
