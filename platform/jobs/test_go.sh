#!/usr/bin/env bash
# test_go.sh: run the jobs runner's Go unit tests (no -tags live; the live test runs only via test_jobs_live.sh).
#
# Forces the pinned toolchain (GOTOOLCHAIN=go<GO_VERSION>, via go-env.sh), sets CGO_ENABLED=1 (-race needs cgo; the
# runner Dockerfile's CGO_ENABLED=0 must not leak in) and FAILS, never skips, when Go or a C compiler is missing
# or the resolved Go version differs from GO_VERSION.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

# shellcheck source=go-env.sh disable=SC1091
. "$here/go-env.sh" || { echo "test_go: FAIL: the pinned Go toolchain is not usable" >&2; exit 1; }

export CGO_ENABLED=1
if ! command -v "${CC:-gcc}" > /dev/null 2>&1 && ! command -v clang > /dev/null 2>&1; then
  echo "test_go: FAIL: no C compiler on PATH (go test -race needs cgo)" >&2
  exit 1
fi

echo "test_go: go$GO_VERSION, go test -race -count=1 ./..."
cd "$here"
go test -race -count=1 ./...
