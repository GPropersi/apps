#!/usr/bin/env bash
# Tests for should-deploy.sh on a scratch git repo: ancestor, descendant, equal, empty, unknown sha, non-sha text and an
# ssh error.
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/should-deploy.sh"

t_init
repo="$T_TMP/repo"
mkdir -p "$repo"
git -C "$repo" init -q

commit() {
  echo "$1" > "$repo/f"
  git -C "$repo" add -A
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m "$1"
  git -C "$repo" rev-parse HEAD
}
in_repo() { ( cd "$repo" || exit 99; "$@" ); }

old="$(commit one)"
new="$(commit two)"
unknown="$(printf 'e%.0s' $(seq 40))"

run_cmd in_repo "$script" "$old" 0 "$new"
expect_rc "own is an ancestor of live" 0
expect_out_has "ancestor skips" "skip"

run_cmd in_repo "$script" "$new" 0 "$old"
expect_rc "own is newer than live" 0
expect_eq "descendant deploys" "$out" "deploy"

git -C "$repo" checkout -q -b side "$old"
side="$(commit side)"
run_cmd in_repo "$script" "$side" 0 "$new"
expect_eq "diverged branches (neither is an ancestor) deploy" "$out" "deploy"

run_cmd in_repo "$script" "$new" 0 "$new"
expect_eq "equal sha deploys" "$out" "deploy"

run_cmd in_repo "$script" "$new" 0 ""
expect_rc "empty live output" 0
expect_eq "empty output deploys" "$out" "deploy"

run_cmd in_repo "$script" "$old" 0 "$unknown"
expect_eq "a live sha that is not a commit here deploys" "$out" "deploy"

run_cmd in_repo "$script" "$old" 0 "latest"
expect_eq "non-sha text deploys" "$out" "deploy"

run_cmd in_repo "$script" "$old" 255 "$new"
expect_rc "ssh error" 1

run_cmd in_repo "$script" "$old" 1 ""
expect_rc "non-zero rc with empty output" 1

run_cmd in_repo "$script" "$old" 0 "$new
"
expect_out_has "a trailing newline is tolerated" "skip"

run_cmd in_repo "$script" "$old" x "$new"
expect_rc "non-numeric rc" 2

run_cmd in_repo "$script" "$old" 0
expect_rc "usage" 2

t_finish
