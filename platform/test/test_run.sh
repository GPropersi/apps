#!/usr/bin/env bash
# Tests for run.sh (timing output, exit codes, ordering) on a scratch root that holds a copy of run.sh and fake test files.
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

t_init
S="$T_TMP/repo"
mkdir -p "$S/platform/test" "$S/platform/a" "$S/platform/b" "$S/apps/foo"
cp -- "$here/run.sh" "$S/platform/test/run.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$S/platform/a/test_a.sh"
printf '#!/usr/bin/env bash\nsleep 0.2\nexit 1\n' > "$S/platform/b/test_b.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$S/apps/foo/test_c.sh"
R="$S/platform/test/run.sh"

run_cmd bash "$R"
expect_rc "a failing file gives rc 1" 1
expect_out_has "all files still run (first)" "== platform/a/test_a.sh"
expect_out_has "all files still run (last)" "== apps/foo/test_c.sh"
expect_out_has "the failing file is named with its rc" "-- platform/b/test_b.sh rc=1 "
expect_out_has "the passing file reports rc 0" "-- platform/a/test_a.sh rc=0 "
expect_out_has "the summary header" "-- timings (slowest first)"
expect_out_has "the total line counts files and failures" " wall, 3 files, 1 failed"

if grep -qE '^-- platform/a/test_a\.sh rc=0 [0-9]+\.[0-9]s$' <<<"$out"; then _pass; else _fail "the per-file line matches the pattern"; fi
if grep -qE '^-- total [0-9]+\.[0-9]s wall, 3 files, 1 failed$' <<<"$out"; then _pass; else _fail "the total line matches the pattern"; fi

# The slowest file (sleeps 0.2 s) is listed first after the header.
first="$(sed -n '/^-- timings/{n;p;}' <<<"$out")"
case "$first" in
  *" platform/b/test_b.sh") _pass ;;
  *) _fail "the summary is sorted slowest first" "first timing line: $first" ;;
esac
if grep -qE '^[0-9]+\.[0-9]s platform/' <<<"$first"; then _pass; else _fail "the timing line has the secs-then-file shape" "line: $first"; fi

run_cmd bash "$R" apps/foo/test_c.sh platform/a/test_a.sh
expect_rc "explicit passing files give rc 0" 0
order="$(grep -E '^== ' <<<"$out" | paste -sd' ' -)"
expect_eq "explicit args run exactly those files in order" "$order" "== apps/foo/test_c.sh == platform/a/test_a.sh"
expect_out_lacks "the summary names only files that ran" "test_b.sh"
expect_out_has "the total counts only the files run" " wall, 2 files, 0 failed"

rm -f "$S"/platform/*/test_*.sh "$S"/apps/*/test_*.sh
run_cmd bash "$R"
expect_rc "no files gives rc 1" 1
expect_out_has "no files is named" "no test_*.sh found"

t_finish
