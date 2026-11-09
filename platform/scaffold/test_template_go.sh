#!/usr/bin/env bash
# test-class: heavy
# test_template_go.sh: run the go-react template's Go tests twice, as the production build and with the `dev` tag
# (dev-only test files carry //go:build dev, production-refusal tests //go:build !dev).
#
# Same rules as platform/jobs/test_go.sh: the pinned toolchain (GOTOOLCHAIN=go<GO_VERSION>, via go-env.sh),
# CGO_ENABLED=1 for -race, and it FAILS, never skips, when Go or a C compiler is missing or the version differs.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../jobs/go-env.sh disable=SC1091
. "$here/../jobs/go-env.sh" || { echo "test_template_go: FAIL: the pinned Go toolchain is not usable" >&2; exit 1; }

export CGO_ENABLED=1
if ! command -v "${CC:-gcc}" > /dev/null 2>&1 && ! command -v clang > /dev/null 2>&1; then
  echo "test_template_go: FAIL: no C compiler on PATH (go test -race needs cgo)" >&2
  exit 1
fi

cd "$here/../../templates/go-react"

echo "test_template_go: go$GO_VERSION, go test -race -count=1 ./..."
go test -race -count=1 ./...
echo "test_template_go: go$GO_VERSION, go test -race -count=1 -tags dev ./..."
go test -race -count=1 -tags dev ./...
