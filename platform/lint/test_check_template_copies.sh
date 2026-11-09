#!/usr/bin/env bash
# Tests for check-template-copies.sh against scratch git repos: identical copies pass; a changed byte, a missing file,
# an extra file, a missing helper directory, a placeholder in the template's helpers and an untracked copy fail; apps of
# another template and no apps pass; the script is not vacuous on an untracked tree.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
check="$here/check-template-copies.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0
helper="templates/go-react/internal/platform"

# new_root: a git repo in $root holding the template's helper package (two files).
new_root() {
  root="$(mktemp -d "$tmp/root.XXXXXX")"
  mkdir -p "$root/$helper"
  git -C "$root" init -q
  printf 'package platform\n\nconst A = 1\n' > "$root/$helper/a.go"
  printf 'package platform\n\nconst B = 2\n' > "$root/$helper/b.go"
}

# add_app <name> [template]: apps/<name>/ with a byte-identical copy of the helper package.
add_app() {
  local name="$1" tpl="${2:-go-react}"
  mkdir -p "$root/apps/$name/internal"
  printf 'name: %s\ntemplate: %s\n' "$name" "$tpl" > "$root/apps/$name/app.yaml"
  cp -R "$root/$helper" "$root/apps/$name/internal/platform"
}

track() { git -C "$root" add -A; }

run_check() {
  rc=0
  out="$("$check" --root "$root" 2>&1)" || rc=$?
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

new_root; track; run_check
expect_pass "no apps passes"

new_root; add_app one; add_app two; track; run_check
expect_pass "identical copies pass"

new_root; add_app one; printf 'package platform\n\nconst A = 9\n' > "$root/apps/one/internal/platform/a.go"; track; run_check
expect_fail "one changed byte" "^apps/one/internal/platform: differs from $helper: a\\.go\\(differs\\) .*cp -R"

new_root; add_app one; add_app two; printf 'x' >> "$root/apps/two/internal/platform/b.go"; track; run_check
expect_fail "only the drifted app is named" "^apps/two/internal/platform: differs from .* b\\.go\\(differs\\)"
if grep -q '^apps/one/' <<< "$out"; then failed=$((failed + 1)); echo "FAIL: the clean app was named"; echo "$out"; else passed=$((passed + 1)); fi

new_root; add_app one; rm "$root/apps/one/internal/platform/b.go"; track; run_check
expect_fail "a missing file" "b\\.go\\(missing\\)"

new_root; add_app one; printf 'package platform\n' > "$root/apps/one/internal/platform/extra.go"; track; run_check
expect_fail "an extra file" "extra\\.go\\(extra\\)"

new_root; add_app one; rm -r "$root/apps/one/internal/platform"; track; run_check
expect_fail "no helper copy at all" "^apps/one/internal/platform: missing"

new_root; add_app one; printf 'package platform\n\n// the tmpl''goreact app\n' >> "$root/$helper/a.go"; cp "$root/$helper/a.go" "$root/apps/one/internal/platform/a.go"; track; run_check
expect_fail "the placeholder in the template's helper dir" "^$helper/a\\.go: names the placeholder app"

new_root; add_app one; chmod +x "$root/apps/one/internal/platform/a.go"; track; run_check
expect_fail "an executable-bit difference" "a\\.go\\(differs\\)"

new_root; add_app one; rm "$root/apps/one/internal/platform/a.go"; ln -s "../../../../../$helper/a.go" "$root/apps/one/internal/platform/a.go"; track; run_check
expect_fail "a symlink to the template's file" "a\\.go\\(differs\\)"

new_root; printf 'x' > "$root/$helper/tmpl""goreact.go"; add_app one; track; run_check
expect_fail "a placeholder in a helper file name" "^$helper/tmpl""goreact\\.go: names the placeholder"

new_root; printf 'x\0tmpl''goreact\0' > "$root/$helper/blob.bin"; add_app one; track; run_check
expect_fail "a placeholder in a binary helper file" "^$helper/blob\\.bin: names the placeholder"

# A copy that exists but is not tracked is not seen: the app's helper dir looks missing, so the check fails rather than
# passing vacuously.
new_root; add_app one; track; git -C "$root" rm -r -q --cached apps/one/internal/platform; run_check
expect_fail "an untracked copy is not read (fails, never passes vacuously)" "^apps/one/internal/platform: missing"

new_root; add_app other go-htmx; rm -r "$root/apps/other/internal/platform"; track; run_check
expect_pass "an app of another template is not compared"

new_root; add_app one; track; git -C "$root" rm -r -q -f "$helper"; run_check
expect_fail "a go-react app with no template helpers to compare against" "declares template go-react but $helper has no tracked files"

# CLI behaviour.
rc=0; out="$("$check" --bogus 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: unknown argument exits 2 (rc=$rc)"; fi
rc=0; out="$("$check" --root 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: missing --root value exits 2 (rc=$rc)"; fi

echo "check-template-copies tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
