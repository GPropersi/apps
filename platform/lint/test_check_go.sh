#!/usr/bin/env bash
# Tests for check-go.sh against temp copies of a tiny platform/jobs module: a mutated GO_VERSION, a mutated
# go.mod toolchain line, an unformatted .go file, a live-tagged file that does not compile, a missing go, and a
# `go` stub (for the version report and the `go env GOROOT` path).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
check="$here/check-go.sh"
real_go="$(command -v go || true)"
if [ -z "$real_go" ]; then
  echo "test_check_go: FAIL: go is not installed" >&2
  exit 1
fi
good_version="$(tr -d '[:space:]' < "$here/../jobs/GO_VERSION")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0

new_root() {
  root="$tmp/root-$RANDOM"
  mkdir -p "$root/platform/jobs"
  printf '%s\n' "$good_version" > "$root/platform/jobs/GO_VERSION"
  # The `go` line is the language version (1.26): Go drops a `toolchain` line that equals the `go` line.
  printf 'module example.test/jobs\n\ngo %s\n\ntoolchain go%s\n' "${good_version%.*}" "$good_version" > "$root/platform/jobs/go.mod"
  printf 'package main\n\nfunc main() {}\n' > "$root/platform/jobs/main.go"
  stub_path=""
}

# make_stub <reported version> [fake-gofmt-output]: a `go` in front of PATH that answers `go version` with the
# given version (recording the GOTOOLCHAIN it saw), and, when a fake gofmt output is given, `go env GOROOT` with
# a fake GOROOT whose gofmt prints it. Everything else goes to the real go.
make_stub() {
  local d="$tmp/stub-$RANDOM"
  mkdir -p "$d/fakeroot/bin"
  if [ -n "${2:-}" ]; then
    printf '#!/bin/sh\necho "%s"\n' "$2" > "$d/fakeroot/bin/gofmt"
    chmod +x "$d/fakeroot/bin/gofmt"
  fi
  cat > "$d/go" << STUB
#!/bin/sh
case "\$1" in
  version) echo "\$GOTOOLCHAIN" > "$d/seen-toolchain"; echo "go version go$1 linux/amd64"; exit 0 ;;
esac
if [ "\$1 \$2" = "env GOROOT" ] && [ -n "${2:-}" ]; then echo "$d/fakeroot"; exit 0; fi
exec "$real_go" "\$@"
STUB
  chmod +x "$d/go"
  stub_path="$d"
}

run_check() {
  rc=0
  if [ -n "$stub_path" ]; then
    out="$(PATH="$stub_path:$PATH" "$check" --root "$root" 2>&1)" || rc=$?
  else
    out="$("$check" --root "$root" 2>&1)" || rc=$?
  fi
}

expect_pass() {
  if [ "$rc" -eq 0 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: $1 (rc=$rc)"; echo "$out"; fi
}

# expect_fail <label> <regex the output must match>
expect_fail() {
  if [ "$rc" -eq 1 ] && grep -qE -- "$2" <<< "$out"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "FAIL: $1 (rc=$rc, wanted /$2/)"; echo "$out"
  fi
}

new_root; run_check
expect_pass "clean module passes"

new_root; rm "$root/platform/jobs/go.mod"; run_check
expect_pass "no go.mod: nothing to check"

new_root; printf '9.9.9\n' > "$root/platform/jobs/GO_VERSION"; make_stub "$good_version"; run_check
expect_fail "GO_VERSION differs from the resolved go" "^FAIL go version mismatch: GO_VERSION wants 9\\.9\\.9, .*resolved $good_version"

new_root; make_stub "9.9.9"; run_check
expect_fail "resolved go differs from GO_VERSION" "^FAIL go version mismatch: GO_VERSION wants $good_version, .*resolved 9\\.9\\.9"

new_root; printf '' > "$root/platform/jobs/GO_VERSION"; run_check
expect_fail "empty GO_VERSION" "^FAIL platform/jobs/GO_VERSION is missing or empty"

new_root; sed -i "s/^toolchain go.*/toolchain go9.9.9/" "$root/platform/jobs/go.mod"; run_check
expect_fail "go.mod toolchain line differs" "^FAIL go.mod toolchain line mismatch: GO_VERSION wants go$good_version, go.mod has go9\\.9\\.9"

new_root; sed -i "/^toolchain/d" "$root/platform/jobs/go.mod"; run_check
expect_fail "go.mod without a toolchain line" "^FAIL go.mod toolchain line mismatch: .*no toolchain line"

new_root; printf 'package main\n\nfunc   main( ) {  }\n' > "$root/platform/jobs/main.go"; run_check
expect_fail "unformatted .go file" "^FAIL gofmt: main\\.go is not formatted"

new_root; make_stub "$good_version" "fake/needs-format.go"; run_check
expect_fail "gofmt comes from go env GOROOT" "^FAIL gofmt: fake/needs-format\\.go is not formatted"

new_root; printf '//go:build live\n\npackage main\n\nfunc broken() { undefinedSymbol() }\n' > "$root/platform/jobs/live_test.go"; run_check
expect_fail "live-tagged file that does not compile" "^FAIL go vet -tags live \\./\\.\\.\\. failed"

new_root; printf 'package main\n\nfunc broken() { undefinedSymbol() }\n' > "$root/platform/jobs/bad.go"; run_check
expect_fail "untagged file that does not compile" "^FAIL go vet \\./\\.\\.\\. failed"

# Template and app modules are covered too, with the dev tag vetted.
add_module() { # <relative dir>: a clean module at that path
  mkdir -p "$root/$1"
  printf 'module example.test/m\n\ngo %s\n\ntoolchain go%s\n' "${good_version%.*}" "$good_version" > "$root/$1/go.mod"
  printf 'package main\n\nfunc main() {}\n' > "$root/$1/main.go"
}
new_root; add_module templates/t1; add_module apps/a1; run_check
expect_pass "clean template and app modules pass"
if grep -qE '(^|[^0-9])3 module' <<< "$out"; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: module count not reported"; echo "$out"; fi

new_root; add_module templates/t1; sed -i "s/^toolchain go.*/toolchain go9.9.9/" "$root/templates/t1/go.mod"; run_check
expect_fail "template toolchain line differs" "^FAIL go.mod toolchain line mismatch: .*go9\\.9\\.9 \\(in templates/t1\\)"

new_root; add_module apps/a1; printf 'package main\n\nfunc   main( ) {  }\n' > "$root/apps/a1/main.go"; run_check
expect_fail "unformatted app file" "^FAIL gofmt: main\\.go is not formatted .*\\(in apps/a1\\)"

new_root; add_module templates/t1; printf 'package main\n\nfunc broken() { undefinedSymbol() }\n' > "$root/templates/t1/bad.go"; run_check
expect_fail "untagged template file that does not compile" "^FAIL go vet \\./\\.\\.\\. failed .*\\(in templates/t1\\)"

new_root; add_module templates/t1; printf '//go:build dev\n\npackage main\n\nfunc broken() { undefinedSymbol() }\n' > "$root/templates/t1/dev.go"; run_check
expect_fail "dev-tagged template file that does not compile" "^FAIL go vet -tags dev \\./\\.\\.\\. failed .*\\(in templates/t1\\)"

# The golang builder of a template or app Dockerfile equals platform/jobs/Dockerfile's.
jobs_ref="golang:1.26.0@sha256:$(printf 'a%.0s' $(seq 64))"
other_ref="golang:1.26.0@sha256:$(printf 'b%.0s' $(seq 64))"
set_dockerfile() { # <relative dir> <FROM ref>
  printf 'FROM %s AS build\nFROM scratch\n' "$2" > "$root/$1/Dockerfile"
}
new_root; add_module templates/t1; add_module apps/a1
printf 'FROM %s AS build\n' "$jobs_ref" > "$root/platform/jobs/Dockerfile"
set_dockerfile templates/t1 "$jobs_ref"; set_dockerfile apps/a1 "$jobs_ref"; run_check
expect_pass "matching golang builders pass"

new_root; add_module templates/t1; add_module apps/a1
printf 'FROM %s AS build\n' "$jobs_ref" > "$root/platform/jobs/Dockerfile"
set_dockerfile templates/t1 "$jobs_ref"; set_dockerfile apps/a1 "$other_ref"; run_check
expect_fail "an app builder digest differs" "^FAIL golang builder mismatch: apps/a1/Dockerfile has golang:1\\.26\\.0@sha256:b+, platform/jobs/Dockerfile has golang:1\\.26\\.0@sha256:a+"

new_root; add_module templates/t1
printf 'FROM %s AS build\n' "$jobs_ref" > "$root/platform/jobs/Dockerfile"
set_dockerfile templates/t1 "$other_ref"; run_check
expect_fail "a template builder digest differs" "^FAIL golang builder mismatch: templates/t1/Dockerfile has "

new_root; add_module templates/t1
printf 'FROM %s AS build\n' "$jobs_ref" > "$root/platform/jobs/Dockerfile"
printf 'FROM alpine@sha256:%s\n' "$(printf 'c%.0s' $(seq 64))" > "$root/templates/t1/Dockerfile"; run_check
expect_fail "a Dockerfile with no golang builder" "^FAIL templates/t1/Dockerfile has no golang builder FROM"

new_root; add_module templates/t1
printf 'FROM golang:1.26.0 AS build\n' > "$root/platform/jobs/Dockerfile"
set_dockerfile templates/t1 "$jobs_ref"; run_check
expect_fail "an unpinned platform/jobs builder fails closed" "^FAIL platform/jobs/Dockerfile has no digest-pinned golang builder"

# GOTOOLCHAIN=local forced from outside must not win: the script exports go<GO_VERSION> itself.
new_root; make_stub "$good_version"
rc=0; out="$(GOTOOLCHAIN=local PATH="$stub_path:$PATH" "$check" --root "$root" 2>&1)" || rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$stub_path/seen-toolchain")" = "go$good_version" ]; then
  passed=$((passed + 1))
else
  failed=$((failed + 1)); echo "FAIL: outer GOTOOLCHAIN=local leaked in (rc=$rc, saw $(cat "$stub_path/seen-toolchain" 2> /dev/null))"; echo "$out"
fi

# No go on PATH at all: a bin dir with only the tools the script needs.
new_root
nogo="$tmp/nogo"
mkdir -p "$nogo"
for tool in env bash tr sed dirname git; do ln -s "$(command -v "$tool")" "$nogo/$tool"; done
rc=0; out="$(PATH="$nogo" "$check" --root "$root" 2>&1)" || rc=$?
expect_fail "go missing" "^FAIL go is not installed"

# CLI behaviour.
rc=0; out="$("$check" --bogus 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: unknown argument exits 2 (rc=$rc)"; fi
rc=0; out="$("$check" --root 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: missing --root value exits 2 (rc=$rc)"; fi

echo "check-go tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
