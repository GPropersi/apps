#!/usr/bin/env bash
# test-class: heavy
# test_go.sh: the app's Go tests with the pinned toolchain. The production tag set runs the production-only tests, then
# the `dev` tag set runs the dev-identity tests and vet. The `live` tag is never run here (test_image.sh runs it against
# a real Redis). Forces GOTOOLCHAIN=go<GO_VERSION> via go-env.sh (the same relative path from templates/go-react and
# from apps/<name>), sets CGO_ENABLED=1 (-race needs cgo) and FAILS, never skips, when Go or a C compiler is missing.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=../../platform/jobs/go-env.sh disable=SC1091
. "$here/../../platform/jobs/go-env.sh" || { echo "test_go: FAIL: the pinned Go toolchain is not usable" >&2; exit 1; }

export CGO_ENABLED=1
if ! command -v "${CC:-gcc}" > /dev/null 2>&1 && ! command -v clang > /dev/null 2>&1; then
  echo "test_go: FAIL: no C compiler on PATH (go test -race needs cgo)" >&2
  exit 1
fi

cd "$here"
echo "test_go: go$GO_VERSION, go test -race -count=1 ./..."
go test -race -count=1 ./...
echo "test_go: go$GO_VERSION, go test -race -count=1 -tags dev ./..."
go test -race -count=1 -tags dev ./...
echo "test_go: go$GO_VERSION, go vet -tags dev ./..."
go vet -tags dev ./...
