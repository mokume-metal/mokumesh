# mokumesh の開発コマンド。検査の入口は ci-check の 1 つで、CI はそれを呼ぶだけ
# (ローカルと CI の乖離を構造的に作らない。mokume の ADR-0001 原則 8)。

.DEFAULT_GOAL := ci-check
.PHONY: build test reuse-lint ci-check clean

build:
	swift build

test:
	swift test

reuse-lint:
	reuse lint

ci-check: build test reuse-lint ## CI と同一の検査 — push 前に通す

clean:
	rm -rf .build
