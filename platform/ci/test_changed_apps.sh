#!/usr/bin/env bash
# Tests for changed-apps.sh against a scratch git repo: zero and unknown before, no change, one app, two apps, a deleted
# app, a directory without app.yaml, and usage errors.
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/changed-apps.sh"

t_init
repo="$T_TMP/repo"
mkdir -p "$repo"

g() { git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false "$@"; }
in_repo() { ( cd "$repo" || exit 99; "$@" ); }
commit() { g add -A; g commit -q -m "$1"; g rev-parse HEAD; }

g init -q
mkdir -p "$repo/apps/a" "$repo/apps/b" "$repo/apps/c"
: > "$repo/apps/a/app.yaml"
: > "$repo/apps/b/app.yaml"
: > "$repo/apps/c/notes.txt"
c1="$(commit one)"
echo 1 > "$repo/apps/a/f"
c2="$(commit two)"
echo 1 > "$repo/apps/a/g"
echo 1 > "$repo/apps/b/g"
c3="$(commit three)"
echo 1 > "$repo/apps/c/more.txt"
c4="$(commit c-only)"
g rm -q -r apps/b
c5="$(commit delete-b)"
echo 1 > "$repo/README.md"
c6="$(commit readme)"
zero="$(printf '0%.0s' $(seq 40))"

run_cmd in_repo "$script" "$zero" "$c6"
expect_rc "zero before" 0
expect_eq "zero before lists every app with an app.yaml" "$out" '["a"]'

run_cmd in_repo "$script" "$zero" "$c1"
expect_eq "zero before at the first commit lists both" "$out" '["a","b"]'

run_cmd in_repo "$script" "$(printf 'f%.0s' $(seq 40))" "$c3"
expect_rc "unknown before" 0
expect_eq "an unknown (absent) before lists every app" "$out" '["a","b"]'

run_cmd in_repo "$script" "not-a-sha" "$c3"
expect_eq "a non-hex before lists every app" "$out" '["a","b"]'

run_cmd in_repo "$script" "" "$c3"
expect_eq "an empty before lists every app" "$out" '["a","b"]'

run_cmd in_repo "$script" "$c1" "$c2"
expect_eq "one app changed" "$out" '["a"]'

run_cmd in_repo "$script" "$c2" "$c3"
expect_eq "two apps changed, sorted" "$out" '["a","b"]'

run_cmd in_repo "$script" "$c3" "$c4"
expect_eq "a directory without app.yaml is not an app" "$out" '[]'

run_cmd in_repo "$script" "$c4" "$c5"
expect_rc "deleted app" 0
expect_eq "a removed app is not listed" "$out" '[]'

run_cmd in_repo "$script" "$c5" "$c6"
expect_eq "no app change prints an empty list" "$out" '[]'

run_cmd in_repo "$script" "$c3" "$c3"
expect_eq "equal before and after prints an empty list" "$out" '[]'

mkdir -p "$repo/apps/a/testdata"
: > "$repo/apps/a/testdata/app.yaml"
echo 1 > "$repo/apps/a/h"
c7="$(commit nested)"
run_cmd in_repo "$script" "$zero" "$c7"
expect_eq "a nested app.yaml is not an app" "$out" '["a"]'

mkdir -p "$repo/apps/d"
: > "$repo/apps/d/app.yaml"
echo 1 > "$repo/apps/d/payload"
c8="$(commit add-d)"
g mv apps/d/payload apps/a/payload
c9="$(commit move-out-of-d)"
run_cmd in_repo "$script" "$c8" "$c9"
expect_eq "a file moved between apps lists both" "$out" '["a","d"]'

run_cmd in_repo "$script" "$c1" "deadbeef"
expect_rc "after not a commit" 1

run_cmd in_repo "$script" "$c1"
expect_rc "usage" 2

t_finish
