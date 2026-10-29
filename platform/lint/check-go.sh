#!/usr/bin/env bash
# check-go.sh: the Go lint checks `make lint` runs for platform/jobs. Each failure prints `FAIL <reason>` on
# stdout and the script exits 1 (2 on usage).
#
#   platform/lint/check-go.sh [--root DIR]      DIR holds platform/jobs (default: the git top level)
#
# Checks, in order:
#   1. GOTOOLCHAIN=go<GO_VERSION> is exported, `go version` run inside platform/jobs equals GO_VERSION;
#   2. go.mod's `toolchain` line equals go<GO_VERSION> (it is only a minimum under GOTOOLCHAIN=auto, so
#      this equality is what keeps it honest);
#   3. the pinned toolchain's gofmt lists no file in platform/jobs;
#   4. `go vet ./...` and `go vet -tags live ./...` pass (the live-tagged files must compile and vet
#      locally, not only in the Docker-gated CI step).
# Does nothing (passes) when the root has no platform/jobs/go.mod.
set -uo pipefail

root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "missing value for --root" >&2; exit 2; }; root="$2"; shift 2 ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$root" ] || root="$(git rev-parse --show-toplevel)" || exit 2

jobs_dir="$root/platform/jobs"
if [ ! -f "$jobs_dir/go.mod" ]; then
  echo "check-go: no platform/jobs/go.mod, nothing to check"
  exit 0
fi

fail() {
  echo "FAIL $1"
  exit 1
}

want="$(tr -d '[:space:]' < "$jobs_dir/GO_VERSION" 2> /dev/null)"
[ -n "$want" ] || fail "platform/jobs/GO_VERSION is missing or empty"
export GOTOOLCHAIN="go$want"
command -v go > /dev/null 2>&1 || fail "go is not installed (need Go >= 1.21 on PATH to fetch go$want)"

have="$(cd "$jobs_dir" && go version 2>&1 | sed -n 's/^go version go\([^ ]*\) .*/\1/p')"
[ "$have" = "$want" ] || fail "go version mismatch: GO_VERSION wants $want, 'go version' in platform/jobs resolved ${have:-nothing} (GOTOOLCHAIN=$GOTOOLCHAIN)"

tc="$(sed -n 's/^toolchain[[:space:]][[:space:]]*go\([^[:space:]]*\)[[:space:]]*$/\1/p' "$jobs_dir/go.mod")"
if [ "$tc" != "$want" ]; then
  [ -n "$tc" ] && tc="go$tc" || tc="no toolchain line"
  fail "go.mod toolchain line mismatch: GO_VERSION wants go$want, go.mod has $tc"
fi

goroot="$(cd "$jobs_dir" && go env GOROOT)" || fail "go env GOROOT failed"
[ -x "$goroot/bin/gofmt" ] || fail "gofmt not found at $goroot/bin/gofmt"
unformatted="$(cd "$jobs_dir" && "$goroot/bin/gofmt" -l . 2>&1)"
if [ -n "$unformatted" ]; then
  while IFS= read -r f; do echo "FAIL gofmt: $f is not formatted (run gofmt -w)"; done <<< "$unformatted"
  exit 1
fi

out="$(cd "$jobs_dir" && go vet ./... 2>&1)" || { printf '%s\n' "$out"; fail "go vet ./... failed"; }
out="$(cd "$jobs_dir" && go vet -tags live ./... 2>&1)" || { printf '%s\n' "$out"; fail "go vet -tags live ./... failed (a live-tagged file does not compile or vet)"; }

echo "check-go: OK (go$want)"
