#!/usr/bin/env bash
# Tests for the live-host make targets (host-*): each must exit non-zero with a usage message when HOST is unset,
# before any script or ssh runs. ssh is stubbed on PATH and its call log is asserted empty, so nothing touches a host.
# Targets are discovered from the Makefile, so a new host-* target is covered automatically.
# SC1091: lib.sh is sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
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
expect_eq "at least the three known live-host targets exist" "$([ "$n" -ge 3 ] && echo yes || echo no)" "yes"

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
t_reset_calls
run_cmd env -u ARGS make -n -s -C "$root" host-deploy-user HOST=alias
expect_out_has "ARGS unset: the default mode is status" '${ARGS:-status}'
run_cmd env ARGS='install --pubkey-file k' make -n -s -C "$root" host-claude-access HOST=alias
expect_out_has "ARGS set: the recipe expands ARGS from the environment" '${ARGS:-status}'

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

t_finish
