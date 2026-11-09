#!/usr/bin/env bash
# check-go.sh: the Go lint checks `make lint` runs for every Go module. Each failure prints `FAIL <reason>` on
# stdout and the script exits 1 (2 on usage).
#
#   platform/lint/check-go.sh [--root DIR]      DIR holds platform/jobs (default: the git top level)
#
# Modules covered: platform/jobs, templates/*/go.mod and apps/*/go.mod (the pin lives in platform/jobs/GO_VERSION).
# Checks, in order:
#   1. GOTOOLCHAIN=go<GO_VERSION> is exported, `go version` run inside platform/jobs equals GO_VERSION;
#   then, for each module:
#   2. go.mod's `toolchain` line equals go<GO_VERSION> (it is only a minimum under GOTOOLCHAIN=auto, so
#      this equality is what keeps it honest);
#   3. the pinned toolchain's gofmt lists no file in the module;
#   3b. for a template or app module with a Dockerfile, its golang builder (tag and digest) equals
#      platform/jobs/Dockerfile's;
#   4. `go vet ./...` passes, plus `go vet -tags live ./...` for platform/jobs (the live-tagged files must compile
#      and vet locally, not only in the Docker-gated CI step) and `go vet -tags dev ./...` for template and app
#      modules (the dev-identity files must compile and vet too).
# Does nothing (passes) when the root has no platform/jobs/go.mod.
set -uo pipefail

root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "missing value for --root" >&2; exit 2; }; root="$2"; shift 2 ;;
    -h | --help) sed -n '2,19p' "$0"; exit 0 ;;
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

goroot="$(cd "$jobs_dir" && go env GOROOT)" || fail "go env GOROOT failed"
[ -x "$goroot/bin/gofmt" ] || fail "gofmt not found at $goroot/bin/gofmt"

# builder_refs <Dockerfile>: every `golang:<tag>@sha256:<digest>` image a FROM names, one per line.
builder_refs() {
  awk 'toupper($1) == "FROM" { for (i = 2; i <= NF; i++) if ($i ~ /^golang:/) { print $i; break } }' "$1"
}

# check_builder_digest <relative module dir>: a template or app Dockerfile's golang builder equals
# platform/jobs/Dockerfile's (same tag and digest). A module without a Dockerfile is skipped; a Dockerfile with no
# golang builder, or an unpinned one, fails.
check_builder_digest() {
  local rel="$1" df="$root/$1/Dockerfile" want_ref have_ref
  [ "$rel" != "platform/jobs" ] || return 0
  [ -f "$df" ] || return 0
  want_ref="$(builder_refs "$jobs_dir/Dockerfile" 2> /dev/null | head -n 1)"
  [[ "$want_ref" =~ @sha256:[0-9a-f]{64}$ ]] || fail "platform/jobs/Dockerfile has no digest-pinned golang builder to compare $rel/Dockerfile with"
  have_ref="$(builder_refs "$df")"
  [ -n "$have_ref" ] || fail "$rel/Dockerfile has no golang builder FROM (the builder must equal platform/jobs/Dockerfile's: $want_ref)"
  while IFS= read -r ref; do
    [ "$ref" = "$want_ref" ] || fail "golang builder mismatch: $rel/Dockerfile has $ref, platform/jobs/Dockerfile has $want_ref (bump them together)"
  done <<< "$have_ref"
}

# check_module <relative dir> <extra vet tag, or empty>
check_module() {
  local rel="$1" tag="$2" dir="$root/$1" tc unformatted out f
  tc="$(sed -n 's/^toolchain[[:space:]][[:space:]]*go\([^[:space:]]*\)[[:space:]]*$/\1/p' "$dir/go.mod")"
  if [ "$tc" != "$want" ]; then
    [ -n "$tc" ] && tc="go$tc" || tc="no toolchain line"
    fail "go.mod toolchain line mismatch: GO_VERSION wants go$want, go.mod has $tc (in $rel)"
  fi

  unformatted="$(cd "$dir" && "$goroot/bin/gofmt" -l . 2>&1)"
  if [ -n "$unformatted" ]; then
    while IFS= read -r f; do echo "FAIL gofmt: $f is not formatted (run gofmt -w) (in $rel)"; done <<< "$unformatted"
    exit 1
  fi

  check_builder_digest "$rel"

  out="$(cd "$dir" && go vet ./... 2>&1)" || { printf '%s\n' "$out"; fail "go vet ./... failed (in $rel)"; }
  if [ -n "$tag" ]; then
    out="$(cd "$dir" && go vet -tags "$tag" ./... 2>&1)" || { printf '%s\n' "$out"; fail "go vet -tags $tag ./... failed (a $tag-tagged file does not compile or vet) (in $rel)"; }
  fi
}

check_module "platform/jobs" "live"
count=1
for mod in "$root"/templates/*/go.mod "$root"/apps/*/go.mod; do
  [ -f "$mod" ] || continue
  rel="${mod#"$root"/}"
  check_module "$(dirname "$rel")" "dev"
  count=$((count + 1))
done

echo "check-go: OK (go$want, $count module(s))"
