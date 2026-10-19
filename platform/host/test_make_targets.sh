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
