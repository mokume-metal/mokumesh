# mokumesh の開発コマンド。検査の入口は ci-check の 1 つで、CI はそれを呼ぶだけ
# (ローカルと CI の乖離を構造的に作らない。mokume の ADR-0001 原則 8)。

.DEFAULT_GOAL := ci-check
.PHONY: build test schemas reuse-lint ci-check dmg clean

# App/ はアプリの別のパッケージ (Syphon を引く。根の Package.swift の冒頭)
build:
	swift build
	swift build --package-path App

# App/ の検査は、AppKit に依存しない編集の論理 (MokumeshEditor) だけを持つ (ADR-0003 決定 4)
test:
	swift test
	swift test --package-path App

# プロセスの外とやりとりする JSON の正典 (Schemas/*.schema.json) と、代表例が食い違わないこと
schemas:
	check-jsonschema --schemafile Schemas/mapping.schema.json Schemas/examples/mapping.json

reuse-lint:
	reuse lint

ci-check: build test schemas reuse-lint ## CI と同一の検査 — push 前に通す

# 配る DMG を dist/ に組む (ci-check には入れない — 検査ではなく配布物)。
# CI の Release (.github/workflows/release.yml) も同じこれを呼ぶ。make dmg VERSION=0.1.0
VERSION ?= 0.0.0-dev
dmg:
	scripts/build-dmg.sh $(VERSION)

clean:
	rm -rf .build dist
