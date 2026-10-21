#!/usr/bin/env bash
# Tests for the live-host make targets (host-*): each must exit non-zero with a usage message when HOST is unset,
# before any script or ssh runs. ssh is stubbed on PATH and its call log is asserted empty, so nothing touches a host.
# Targets are discovered from the Makefile, so a new host-* target is covered automatically.
# SC1091: lib.sh is sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# SC2016: the make recipe text is matched literally, so it is single-quoted on purpose.
# shellcheck disable=SC1091,SC2016,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
root="$(cd "$here/../.." && pwd)"

t_init
t_stub ssh 0
t_stub sudo 0

targets=$(grep -oE '^host-[A-Za-z0-9_-]+:' "$root/Makefile" | tr -d ':')
n=$(printf '%s\n' "$targets" | grep -c .)
expect_eq "at least the six known live-host targets exist" "$([ "$n" -ge 6 ] && echo yes || echo no)" "yes"

for tgt in $targets; do
  t_reset_calls
  run_cmd env -u HOST -u ARGS make -s -C "$root" "$tgt"
  if [ "$rc" -ne 0 ]; then _pass; else _fail "$tgt without HOST exits non-zero" "rc=0"; fi
  expect_out_has "$tgt without HOST prints usage" "usage: make $tgt HOST="
  expect_eq "$tgt without HOST made no ssh or sudo call" "$(t_calls)" ""

  t_reset_calls
  run_cmd env -u ARGS HOST= make -s -C "$root" "$tgt"
  if [ "$rc" -ne 0 ]; then _pass; else _fail "$tgt with empty HOST exits non-zero" "rc=0"; fi
  expect_out_has "$tgt with empty HOST prints usage" "usage: make $tgt HOST="
  expect_eq "$tgt with empty HOST made no ssh or sudo call" "$(t_calls)" ""
done

# Dry runs with HOST set: the printed recipe must hand ARGS (or the default mode) and --host to the right script.
# make -n prints the recipe lines without running them, so nothing reaches ssh or a host.
dry_case() {
  local label="$1" tgt="$2" script_name="$3"
  shift 3
  t_reset_calls
  run_cmd env -u ARGS "$@" make -n -s -C "$root" "$tgt" HOST=alias
  expect_rc "dry run: $label" 0
  expect_out_has "dry run runs the right script: $label" "platform/host/$script_name"
  expect_out_has "dry run passes --host with the alias: $label" '--host "$HOST"'
  expect_eq "dry run made no ssh or sudo call: $label" "$(t_calls)" ""
}
dry_case "deploy-user, ARGS unset" host-deploy-user install-deploy-user.sh
dry_case "claude-access, ARGS unset" host-claude-access install-claude-access.sh
dry_case "deploy-user with ARGS" host-deploy-user install-deploy-user.sh ARGS='install --pubkey-file k'
dry_case "claude-access with ARGS" host-claude-access install-claude-access.sh ARGS='install --pubkey-file k'
dry_case "verify-egress with ARGS" host-verify-egress verify-egress.sh ARGS='--probe'
dry_case "verify-ingress with ARGS" host-verify-ingress verify-ingress.sh ARGS='--domain example.test'
dry_case "ingress, ARGS unset" host-ingress install-ingress.sh
dry_case "ingress with ARGS" host-ingress install-ingress.sh ARGS='verify --live --hold'
dry_case "data, ARGS unset" host-data install-data.sh
dry_case "data with ARGS" host-data install-data.sh ARGS='verify'
# make -n leaves the shell expansion of ARGS unexpanded, so the real recipes run here against stub scripts in a
# scratch tree that record their argv; nothing reaches ssh or a host.
stub_tree="$T_TMP/stub-tree"
rm -rf "$stub_tree"
mkdir -p "$stub_tree/platform/host"
cp -- "$root/Makefile" "$stub_tree/Makefile"
for stub in install-deploy-user.sh install-claude-access.sh install-ingress.sh install-data.sh verify-egress.sh verify-ingress.sh; do
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" > "$STUB_ARGV"\n' > "$stub_tree/platform/host/$stub"
  chmod +x "$stub_tree/platform/host/$stub"
done
stub_argv="$T_TMP/stub-argv.txt"
stub_run() { # target [ARGS value; omit to leave ARGS unset]
  rm -f "$stub_argv"
  if [ "$#" -ge 2 ]; then
    run_cmd env STUB_ARGV="$stub_argv" ARGS="$2" make -s -C "$stub_tree" "$1" HOST=alias
  else
    run_cmd env -u ARGS STUB_ARGV="$stub_argv" make -s -C "$stub_tree" "$1" HOST=alias
  fi
}
stub_run host-deploy-user
expect_rc "stub run: deploy-user, ARGS unset" 0
expect_eq "ARGS unset: the default mode is status" "$(cat "$stub_argv")" "status --host alias"
stub_run host-claude-access
expect_eq "ARGS unset: claude-access defaults to status" "$(cat "$stub_argv")" "status --host alias"
stub_run host-deploy-user 'install --pubkey-file k'
expect_rc "stub run: deploy-user, ARGS set" 0
expect_eq "ARGS set: deploy-user receives ARGS then --host" "$(cat "$stub_argv")" "install --pubkey-file k --host alias"
stub_run host-claude-access 'install --pubkey-file k'
expect_eq "ARGS set: claude-access receives ARGS then --host" "$(cat "$stub_argv")" "install --pubkey-file k --host alias"
stub_run host-ingress
expect_rc "stub run: ingress, ARGS unset" 0
expect_eq "ARGS unset: ingress defaults to status" "$(cat "$stub_argv")" "status --host alias"
stub_run host-ingress 'verify --live --hold'
expect_eq "ARGS set: ingress receives ARGS then --host" "$(cat "$stub_argv")" "verify --live --hold --host alias"
stub_run host-data
expect_rc "stub run: data, ARGS unset" 0
expect_eq "ARGS unset: data defaults to status" "$(cat "$stub_argv")" "status --host alias"
stub_run host-data 'install'
expect_eq "ARGS set: data receives ARGS then --host" "$(cat "$stub_argv")" "install --host alias"
stub_run host-verify-egress '--probe'
expect_eq "ARGS reaches verify-egress" "$(cat "$stub_argv")" "--probe --host alias"
stub_run host-verify-egress
expect_eq "ARGS unset: verify-egress gets only --host" "$(cat "$stub_argv")" "--host alias"
stub_run host-verify-ingress '--domain example.test'
expect_eq "ARGS set: verify-ingress receives ARGS then --host" "$(cat "$stub_argv")" "--domain example.test --host alias"
stub_run host-verify-ingress
expect_eq "ARGS unset: verify-ingress gets only --host (no domain default)" "$(cat "$stub_argv")" "--host alias"

# make test on scratch trees: a failing test fails the run, a passing tree passes, an empty tree is an error.
scratch_make() {
  local dir="$1"
  rm -rf "$dir"
  mkdir -p "$dir/platform"
  cp -- "$root/Makefile" "$dir/Makefile"
}
scratch="$T_TMP/scratch-pass"
scratch_make "$scratch"
printf '#!/usr/bin/env bash\nexit 0\n' > "$scratch/platform/test_ok.sh"
run_cmd make -s -C "$scratch" test
expect_rc "make test with only a passing test" 0

scratch="$T_TMP/scratch-mixed"
scratch_make "$scratch"
printf '#!/usr/bin/env bash\nexit 0\n' > "$scratch/platform/test_ok.sh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$scratch/platform/test_bad.sh"
run_cmd make -s -C "$scratch" test
# make reports a failed recipe as status 2
expect_rc "make test with one failing test fails" 2
expect_out_has "the failing test was run" "test_bad.sh"
expect_out_has "the passing test was run too" "test_ok.sh"

scratch="$T_TMP/scratch-empty"
scratch_make "$scratch"
run_cmd make -s -C "$scratch" test
expect_rc "make test with no tests is an error" 2
expect_out_has "the empty tree names what is missing" "no platform/**/test_*.sh found"

# No live-host target may be offered in a worktree: the allowed list in CLAUDE.md is help, lint, test, embed only.
allowed=$(grep -E '^- \*\*Worktree allowed targets:\*\*' "$root/CLAUDE.md" || true)
for want in help lint test embed; do
  case "$allowed" in
    *"$want"*) _pass ;;
    *) _fail "allowed targets line lists $want" "line missing or renamed" ;;
  esac
done
for tgt in $targets; do
  case "$allowed" in
    *"$tgt"*) _fail "$tgt is not a worktree allowed target" "listed in CLAUDE.md" ;;
    *) _pass ;;
  esac
done

# Every host-* target must be documented in a Commands-table row of CLAUDE.md (a table row line containing
# `make <target>`, not merely a longer target name that starts with it).
missing_rows() { # claude-md-file: prints each discovered target that has no row
  local file="$1" t
  for t in $targets; do
    grep -qE "^[[:space:]]*\|.*make ${t}([^A-Za-z0-9_-]|\$)" "$file" || printf '%s\n' "$t"
  done
}
expect_eq "every host-* target has a Commands row in CLAUDE.md" "$(missing_rows "$root/CLAUDE.md")" ""
# Mutation: a copy of CLAUDE.md without the host-verify-ingress row must be caught, and only that target.
mutant="$T_TMP/CLAUDE.mutant.md"
grep -v 'make host-verify-ingress' "$root/CLAUDE.md" > "$mutant" || true
expect_eq "a target missing its Commands row is reported" "$(missing_rows "$mutant")" "host-verify-ingress"
# A row for a longer target name must not satisfy its prefix.
printf '| x | `make host-ingress-x` |\n' > "$mutant"
case "$(missing_rows "$mutant")" in
  *host-ingress*) _pass ;;
  *) _fail "a longer target name does not satisfy a shorter one" "host-ingress was accepted" ;;
esac
# A non-table mention is not a row.
printf 'Run make host-ingress sometimes.\n' > "$mutant"
case "$(missing_rows "$mutant")" in
  *host-ingress*) _pass ;;
  *) _fail "a prose mention does not count as a Commands row" "host-ingress was accepted" ;;
esac

t_finish
