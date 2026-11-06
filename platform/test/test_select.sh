#!/usr/bin/env bash
# Tests for select.sh and the make test-changed target, on a scratch git repo that holds copies of the selector, its
# library and the real areas.map plus one dummy test per area and two dummy apps (foo, and foo-bar to catch prefix bugs).
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
root="$(cd "$here/../.." && pwd)"
# Scratch `make test-changed` runs use ENVU (from lib.sh), so they start without the outer runner, hostq and knob variables.

t_init
S="$T_TMP/repo"
mkdir -p "$S/platform/test"
cp -- "$here/select.sh" "$here/areamap-lib.sh" "$here/areas.map" "$here/run.sh" "$S/platform/test/"
cp -- "$root/Makefile" "$S/Makefile"
chmod +x "$S/platform/test/select.sh" "$S/platform/test/run.sh"

dummy_test() { # path: a passing dummy test
  mkdir -p "$(dirname "$S/$1")"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$S/$1"
}
for a in host data jobs lint registry ingress backup deploy ci; do dummy_test "platform/$a/test_$a.sh"; done
dummy_test platform/test/test_t.sh
mkdir -p "$S/platform/lib" "$S/docs"
echo lib > "$S/platform/lib/l.sh"
dummy_test apps/foo/test_a.sh
dummy_test apps/foo-bar/test_b.sh
echo r > "$S/README.md"
echo r > "$S/apps/foo/README.md"
echo d > "$S/docs/x.md"
echo c > "$S/CLAUDE.md"

g() { git -C "$S" -c user.name=t -c user.email=t@example.test "$@"; }
g init -q -b main
g add -A
g commit -q -m base

APPS=(apps/foo-bar/test_b.sh apps/foo/test_a.sh)
ALL=(platform/backup/test_backup.sh platform/ci/test_ci.sh platform/data/test_data.sh platform/deploy/test_deploy.sh platform/host/test_host.sh platform/ingress/test_ingress.sh
  platform/jobs/test_jobs.sh platform/lint/test_lint.sh platform/registry/test_registry.sh platform/test/test_t.sh "${APPS[@]}")

want() { printf '%s\n' "$@" | LC_ALL=C sort -u | paste -sd' ' -; }
touch_file() { mkdir -p "$(dirname "$S/$1")"; printf 'x\n' >> "$S/$1"; }

# branch_with <path...>: a fresh branch off main in which each path is appended to and committed.
branch_with() {
  g checkout -q -B work main
  local p
  for p in "$@"; do touch_file "$p"; done
  g add -A
  g commit -q -m change
}

sel="" err="" srcrc=0
run_select() { # base: stdout (newlines as spaces) in $sel, stderr in $err, exit status in $srcrc
  srcrc=0
  sel="$("$S/platform/test/select.sh" --base "$1" 2>"$T_TMP/err")" || srcrc=$?
  sel="${sel//$'\n'/ }"
  err="$(cat "$T_TMP/err")"
}
case_sel() { # label, "changed paths", expected files...
  local label="$1" paths="$2"
  shift 2
  # shellcheck disable=SC2086
  branch_with $paths
  run_select main
  expect_eq "$label" "$sel" "$(want "$@")"
  expect_eq "$label: exit 0 and no warning" "$srcrc:$err" "0:"
}

# Each map row, in the order of the file.
case_sel "docs-only selects nothing" "README.md docs/x.md apps/foo/README.md"
case_sel "Makefile selects test, host, lint and registry" "Makefile" platform/test/test_t.sh platform/host/test_host.sh \
  platform/lint/test_lint.sh platform/registry/test_registry.sh
case_sel ".github selects lint and ci" ".github/workflows/ci.yml" platform/lint/test_lint.sh platform/ci/test_ci.sh
case_sel "platform/test/lib.sh selects all" "platform/test/lib.sh" "${ALL[@]}"
case_sel "platform/test/prewarm.sh selects all (the all row beats platform/test/**)" "platform/test/prewarm.sh" "${ALL[@]}"
case_sel "platform/test/run.sh selects all (the all row beats platform/test/**)" "platform/test/run.sh" "${ALL[@]}"
case_sel "another platform/test file selects test, host and lint" "platform/test/test_t.sh" platform/test/test_t.sh \
  platform/host/test_host.sh platform/lint/test_lint.sh
case_sel "CLAUDE.md selects host" "CLAUDE.md" platform/host/test_host.sh
case_sel "platform/lib row" "platform/lib/l.sh" platform/registry/test_registry.sh platform/data/test_data.sh platform/host/test_host.sh \
  platform/backup/test_backup.sh platform/jobs/test_jobs.sh platform/ingress/test_ingress.sh platform/deploy/test_deploy.sh platform/test/test_t.sh "${APPS[@]}"
case_sel "platform/registry row" "platform/registry/r.txt" platform/registry/test_registry.sh platform/data/test_data.sh \
  platform/host/test_host.sh platform/backup/test_backup.sh platform/jobs/test_jobs.sh platform/lint/test_lint.sh \
  platform/deploy/test_deploy.sh platform/test/test_t.sh "${APPS[@]}"
case_sel "platform/data row" "platform/data/d.txt" platform/data/test_data.sh platform/host/test_host.sh \
  platform/backup/test_backup.sh platform/jobs/test_jobs.sh platform/lint/test_lint.sh platform/deploy/test_deploy.sh \
  platform/test/test_t.sh "${APPS[@]}"
case_sel "platform/deploy row: deploy, host, lint and data (the removal tests run in data), no apps" "platform/deploy/d.txt" \
  platform/data/test_data.sh platform/deploy/test_deploy.sh platform/host/test_host.sh platform/lint/test_lint.sh
case_sel "platform/ci row: ci only" "platform/ci/c.txt" platform/ci/test_ci.sh
case_sel "platform/jobs row: jobs, host, lint and every app" "platform/jobs/j.txt" platform/jobs/test_jobs.sh \
  platform/host/test_host.sh platform/lint/test_lint.sh platform/test/test_t.sh "${APPS[@]}"
case_sel "platform/backup row" "platform/backup/b.txt" platform/backup/test_backup.sh platform/host/test_host.sh \
  platform/data/test_data.sh platform/lint/test_lint.sh "${APPS[@]}"
case_sel "platform/ingress row" "platform/ingress/i.txt" platform/ingress/test_ingress.sh platform/host/test_host.sh \
  platform/lint/test_lint.sh platform/test/test_t.sh "${APPS[@]}"
case_sel "platform/host row" "platform/host/h.txt" platform/host/test_host.sh platform/data/test_data.sh \
  platform/backup/test_backup.sh platform/jobs/test_jobs.sh platform/lint/test_lint.sh "${APPS[@]}"
case_sel "platform/lint row is lint only" "platform/lint/l.txt" platform/lint/test_lint.sh
case_sel "the catch-all selects all for an unknown path" "weird/file.txt" "${ALL[@]}"

# Apps.
case_sel "an app-only change selects only that app" "apps/foo/main.txt" apps/foo/test_a.sh
case_sel "apps/foo-bar never selects apps/foo" "apps/foo-bar/main.txt" apps/foo-bar/test_b.sh
case_sel "an app plus a platform change" "apps/foo/main.txt platform/lint/l.txt" apps/foo/test_a.sh platform/lint/test_lint.sh
case_sel "an app README selects nothing" "apps/foo/README.md"
case_sel "a new app without tests selects nothing" "apps/newapp/main.txt"

# First match wins: README.md sits above everything (a README under platform/lint is docs).
case_sel "first match wins: README.md under platform/lint is docs" "platform/lint/README.md"

# A rename lists both sides: moving platform/lint/m.txt to docs/m.txt still selects lint.
g checkout -q -B work main
mkdir -p "$S/platform/lint"
printf 'moved content that is long enough for rename detection to pair the files\n' > "$S/platform/lint/m.txt"
g add -A
g commit -q -m "add m"
g checkout -q -B base2 work
mkdir -p "$S/docs"
g mv platform/lint/m.txt docs/m.txt
g commit -q -m "rename m"
run_select work
expect_eq "a rename out of an area selects the old area" "$sel" "platform/lint/test_lint.sh"
expect_eq "a rename: exit 0 and no warning" "$srcrc:$err" "0:"

# A rename between two test-bearing areas selects both: lint (lint only) to ingress (ingress, host, lint, apps).
g checkout -q -B work main
printf 'second moved content that is long enough for rename detection to pair\n' > "$S/platform/lint/m2.txt"
g add -A
g commit -q -m "add m2"
g checkout -q -B base3 work
g mv platform/lint/m2.txt platform/ingress/m2.txt
g commit -q -m "rename m2"
run_select work
expect_eq "a rename between areas selects both areas" "$sel" "$(want platform/lint/test_lint.sh platform/ingress/test_ingress.sh platform/host/test_host.sh platform/test/test_t.sh "${APPS[@]}")"

# Fail toward more tests: a bad ref, an unreadable map, a malformed row, an unknown area, a path no row matches.
branch_with README.md
run_select no-such-ref
expect_eq "a bad ref selects everything" "$sel" "$(want "${ALL[@]}")"
expect_eq "a bad ref exits 0" "$srcrc" "0"
case "$err" in *"select.sh: warning:"*"no-such-ref"*) _pass ;; *) _fail "a bad ref names itself in a warning" "stderr: $err" ;; esac
run_select origin/main
expect_eq "the default base with no origin/main selects everything" "$sel" "$(want "${ALL[@]}")"
case "$err" in *"warning"*"origin/main"*) _pass ;; *) _fail "the missing origin/main is named" "stderr: $err" ;; esac

run_select "--output=$T_TMP/pwned"
expect_eq "an option-like base selects everything" "$sel" "$(want "${ALL[@]}")"
expect_eq "an option-like base wrote nothing" "$(ls "$T_TMP/pwned" 2>/dev/null)" ""
case "$err" in *"looks like an option"*) _pass ;; *) _fail "an option-like base is named" "stderr: $err" ;; esac

run_cmd "${ENVU[@]}" make -s -C "$S" test-changed BASE="main\"; touch $T_TMP/injected; \""
if [ -e "$T_TMP/injected" ]; then _fail "BASE is not shell-expanded by make" "injected file exists"; else _pass; fi

map="$S/platform/test/areas.map"
cp -- "$map" "$T_TMP/areas.good"
restore_map() { cp -- "$T_TMP/areas.good" "$map"; }

rm -f "$map"
run_select main
expect_eq "a missing map selects everything" "$sel" "$(want "${ALL[@]}")"
case "$err" in *"areas.map unusable"*) _pass ;; *) _fail "a missing map is named" "stderr: $err" ;; esac
restore_map

printf 'no tab on this row\n' >> "$map"
run_select main
expect_eq "a malformed row selects everything" "$sel" "$(want "${ALL[@]}")"
case "$err" in *"areas.map unusable"*"line"*) _pass ;; *) _fail "a malformed row is named with its line" "stderr: $err" ;; esac
restore_map

printf 'README.md\t\n' > "$map"
run_select main
expect_eq "a row with empty targets selects everything" "$sel" "$(want "${ALL[@]}")"
restore_map

branch_with platform/lint/l.txt
printf 'platform/lint/**\tnosuchdir\n' > "$map"
run_select main
expect_eq "an unknown area target selects everything" "$sel" "$(want "${ALL[@]}")"
case "$err" in *"unknown area 'nosuchdir'"*) _pass ;; *) _fail "the unknown area is named" "stderr: $err" ;; esac
restore_map

branch_with weird/file.txt
printf 'README.md\tnone\n' > "$map"
run_select main
expect_eq "a path no row matches selects everything" "$sel" "$(want "${ALL[@]}")"
case "$err" in *"no areas.map row matches 'weird/file.txt'"*) _pass ;; *) _fail "the unmatched path is named" "stderr: $err" ;; esac
restore_map

run_cmd "$S/platform/test/select.sh"
expect_rc "select.sh without --base is a usage error" 2

# make test-changed.
branch_with README.md
run_cmd "${ENVU[@]}" make -s -C "$S" test-changed BASE=main
expect_rc "test-changed with a docs-only change" 0
expect_out_has "a docs-only change prints that nothing was selected" "no tests selected"
expect_out_lacks "a docs-only change runs no test" "== "

branch_with apps/foo/main.txt
run_cmd "${ENVU[@]}" make -s -C "$S" test-changed BASE=main
expect_rc "test-changed with an app change" 0
expect_out_has "test-changed runs the app's test" "== apps/foo/test_a.sh"
expect_out_lacks "test-changed does not run another app's test" "foo-bar"

printf '#!/usr/bin/env bash\nexit 1\n' > "$S/apps/foo/test_a.sh"
g add -A
g commit -q -m "break foo's test"
run_cmd "${ENVU[@]}" make -s -C "$S" test-changed BASE=main
if [ "$rc" -ne 0 ]; then _pass; else _fail "test-changed fails when a selected test fails" "rc=0"; fi

run_cmd "${ENVU[@]}" make -s -C "$S" test-changed
expect_rc "test-changed with the default BASE (no origin/main) runs everything and the broken test fails it" 2
expect_out_has "the default BASE warns" "warning"
expect_out_has "the default BASE ran another area's test" "== platform/lint/test_lint.sh"

t_finish
