.PHONY: build test check hooks fmt release-build demo
build:  ## build ./catalyst
	go build -ldflags "-s -w" -o catalyst ./cmd/catalyst
test:  ## the whole test suite, no real machine state touched
	go test ./...
fmt:  ## format the code
	gofmt -w .
check:  ## scan the whole tree: format, vet, data guard, personal values
	@test -z "$$(gofmt -l .)" || { echo "Run make fmt:"; gofmt -l .; exit 1; }
	go vet ./...
	scripts/check-data-guard.sh --all
	scripts/check-denylist.sh --all
	python3 scripts/check-personal.py --all
hooks:  ## enable the pre-commit and pre-push guards
	git config core.hooksPath .githooks
	@if [ -s .private/denylist.txt ]; then git config catalyst.maintainer true; echo "Maintainer mode: the personal denylist is required."; fi
	@command -v gitleaks >/dev/null || echo "Install gitleaks: brew install gitleaks (or see https://github.com/gitleaks/gitleaks)"
release-build:  ## build every release archive into dist/ (VERSION=v0.1.0)
	scripts/release-build.sh "$(VERSION)"
demo:  ## re-record the README screenshots from fake data (needs python3 with pyte and pillow, on a Mac)
	python3 demo/shots.py
