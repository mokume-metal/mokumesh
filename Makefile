# mokumesh の開発コマンド。検査の入口は ci-check の 1 つで、CI はそれを呼ぶだけ
# (ローカルと CI の乖離を構造的に作らない。mokume の ADR-0001 原則 8)。

.DEFAULT_GOAL := ci-check
.PHONY: build test schemas reuse-lint ci-check clean

build:
	swift build

test:
	swift test

# プロセスの外とやりとりする JSON の正典 (Schemas/*.schema.json) と、代表例が食い違わないこと
schemas:
	check-jsonschema --schemafile Schemas/mapping.schema.json Schemas/examples/mapping.json

reuse-lint:
	reuse lint

ci-check: build test schemas reuse-lint ## CI と同一の検査 — push 前に通す

clean:
	rm -rf .build
