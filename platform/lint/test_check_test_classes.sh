#!/usr/bin/env bash
# Tests for check-test-classes.sh: the real tree, scratch trees for each rule (unmarked docker or go probe, unknown
# class, duplicate marker, marker on line 10 vs 11, every probe command position, prose that must not match), the
# exclusion list, and the Makefile `lint:` recipe wiring.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
check="$here/check-test-classes.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The probe words are held in variables so no line of this file carries them at command position (this file is
# itself scanned by the check).
d="docker info"
g="go test"
passed=0
failed=0

new_root() {
  root="$tmp/root-$RANDOM"
  mkdir -p "$root/platform/x" "$root/platform/lint"
}

# put <relative path> <printf %b text>
put() {
  mkdir -p "$(dirname "$root/$1")"
  printf '%b' "$2" > "$root/$1"
}

# pad <n>: n comment lines
pad() {
  local i
  for ((i = 0; i < $1; i++)); do printf '# pad\\n'; done
}

run_check() {
  rc=0
  out="$("$check" --root "$root" 2>&1)" || rc=$?
}

expect_pass() {
  if [ "$rc" -eq 0 ] && [ -z "$out" ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: $1 (rc=$rc)"; echo "$out"; fi
}

# expect_fail <label> <regex the output must match>
expect_fail() {
  if [ "$rc" -eq 1 ] && grep -qE -- "$2" <<< "$out"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "FAIL: $1 (rc=$rc, wanted /$2/)"; echo "$out"
  fi
}

# The real tree passes.
root="$repo"; run_check
expect_pass "the real tree passes"

new_root; run_check
expect_pass "an empty tree passes"

hdr='#!/usr/bin/env bash\n'
new_root; put platform/x/test_a.sh "$hdr$d >/dev/null || exit 1\n"; run_check
expect_fail "unmarked docker file" "^platform/x/test_a\\.sh: .*no '# test-class:' marker"

new_root; put platform/x/test_a.sh "$hdr$g ./...\n"; run_check
expect_fail "unmarked go test file" "^platform/x/test_a\\.sh: .*no '# test-class:' marker"

new_root; put platform/x/test_a.sh "$hdr# test-class: docker\n$d || exit 1\n"; run_check
expect_pass "a docker marker passes"

new_root; put platform/x/test_a.sh "$hdr# test-class: heavy\n$g ./...\n"; run_check
expect_pass "a heavy marker passes"

new_root; put platform/x/test_a.sh "$hdr# test-class: huge\n$d\n"; run_check
expect_fail "unknown class" "^platform/x/test_a\\.sh: line 2: unknown test class"

new_root; put platform/x/test_a.sh "$hdr# test-class:docker\n"; run_check
expect_fail "malformed marker" "^platform/x/test_a\\.sh: line 2: unknown test class"

new_root; put platform/x/test_a.sh "$hdr# test-class: docker\n# test-class: heavy\n$d\n"; run_check
expect_fail "duplicate marker" "^platform/x/test_a\\.sh: more than one test-class marker"

new_root; put platform/x/test_a.sh "$hdr$(pad 8)# test-class: docker\n$d\n"; run_check
expect_pass "a marker on line 10 passes"

new_root; put platform/x/test_a.sh "$hdr$(pad 9)# test-class: docker\n$d\n"; run_check
expect_fail "a marker on line 11 fails" "^platform/x/test_a\\.sh: line 11: test-class marker after line 10"

new_root; put platform/x/test_a.sh "$hdr# test-class: docker\n$(pad 9)# test-class: docker\n"; run_check
expect_fail "a second marker after line 10 fails" "^platform/x/test_a\\.sh: line 12: test-class marker after line 10"

# Probe command positions: each unmarked file must fail.
# shellcheck disable=SC2016  # the 'v=$(' fragment is literal probe text
for form in \
  "$d" "! $d" "x || $d" "x && $d" "x; $d" "x | $d" "($d)" "{ $d; }" 'v=$('"$d"')' \
  "if $d; then :; fi" "if x; then :; elif $d; then :; fi" "while $d; do :; done" "until $d; do :; done" \
  "x; then $d" "x; else $d" "for i in 1; do $d; done" "! command -v docker || ! $d"; do
  new_root; put platform/x/test_pos.sh "$hdr$form\n"; run_check
  expect_fail "probe position: $form" "^platform/x/test_pos\\.sh: .*no '# test-class:' marker"
done

# Mocked files: prose, comments, near-misses and indented comments pass.
new_root
put platform/x/test_mock.sh "$hdr# runs $d and $g in a comment\n  # $g indented comment\necho \"check-go tests: 1 passed\"\necho main.go testapp/x\necho \"the docker info page\"\ndocker information\n"
run_check
expect_pass "a mocked file mentioning the words passes"

# Exclusion list.
excl=platform/lint/test-class-exclusions.txt
new_root; put platform/x/test_stub.sh "$hdr$d\n"; put "$excl" "# comment\n\nplatform/x/test_stub.sh stubs the daemon probe\n"; run_check
expect_pass "an exclusion entry for a file with a probe passes"

new_root; put "$excl" "platform/x/test_gone.sh was removed\n"; run_check
expect_fail "exclusion entry for a missing file" "^$excl: entry 'platform/x/test_gone\\.sh' names a file that does not exist"

new_root; put platform/x/test_clean.sh "${hdr}echo hi\n"; put "$excl" "platform/x/test_clean.sh no probe now\n"; run_check
expect_fail "exclusion entry without a probe" "^$excl: entry 'platform/x/test_clean\\.sh' no longer contains"

new_root; put platform/x/test_stub.sh "$hdr$d\n"; put platform/x/test_other.sh "$hdr$d\n"; put "$excl" "platform/x/test_stub.sh stub\n"; run_check
expect_fail "an excluded file does not exempt another" "^platform/x/test_other\\.sh: "
if grep -q 'test_stub' <<< "$out"; then failed=$((failed + 1)); echo "FAIL: the excluded file was reported"; echo "$out"; else passed=$((passed + 1)); fi

# App tests are scanned too.
new_root; put apps/foo/test_app.sh "$hdr$d\n"; run_check
expect_fail "an app test is scanned" "^apps/foo/test_app\\.sh: "

# Template tests are scanned too, one level deep only (run.sh discovers templates/<name>/test_*.sh).
new_root; put templates/foo/test_tpl.sh "$hdr$d\n"; run_check
expect_fail "a template test is scanned" "^templates/foo/test_tpl\\.sh: "
new_root; put templates/foo/sub/test_deep.sh "$hdr$d\n"; run_check
expect_pass "a template test nested deeper is not scanned"

# The Makefile lint recipe runs the check (deleting the line must fail this test).
if grep -A8 '^lint:' "$repo/Makefile" | grep -q 'check-test-classes\.sh'; then
  passed=$((passed + 1))
else
  failed=$((failed + 1)); echo "FAIL: the Makefile lint recipe does not run check-test-classes.sh"
fi

# CLI behaviour.
rc=0; out="$("$check" --bogus 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: unknown argument exits 2 (rc=$rc)"; fi
rc=0; out="$("$check" --root 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: missing --root value exits 2 (rc=$rc)"; fi

echo "check-test-classes tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
