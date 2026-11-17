#!/usr/bin/env bash
# Tests for notifs-resolve.sh on a scratch git repo: an explicit app without notifs: true fails and writes no output, an
# explicit opted-in app is selected alone, and an empty input selects every opted-in app (or none, without failing).
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/notifs-resolve.sh"

t_init
mkrepo() { # <dir>: an empty git repo
  mkdir -p "$1"
  git -C "$1" init -q
}
mkapp() { # <dir> <name> <app.yaml text>
  mkdir -p "$1/apps/$2"
  printf '%b' "$3" > "$1/apps/$2/app.yaml"
}
commit() {
  git -C "$1" add -A
  git -C "$1" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m init
}

repo="$T_TMP/repo"
mkrepo "$repo"
mkapp "$repo" on-a 'schema_version: 1\nnotifs: true\n'
mkapp "$repo" on-b 'schema_version: 1\nnotifs: true\n'
mkapp "$repo" off-app 'schema_version: 1\nnotifs: false\n'
mkapp "$repo" plain 'schema_version: 1\n'
commit "$repo"

ghout="$T_TMP/github-output"
in_repo() { ( cd "$repo" || exit 99; GITHUB_OUTPUT="$ghout" "$@" ); }

# explicit app without notifs: true fails and writes nothing
: > "$ghout"
run_cmd in_repo "$script" off-app
expect_rc "explicit app with notifs: false" 1
expect_out_has "explicit app with notifs: false names the app" "off-app does not set notifs: true"
expect_eq "explicit app with notifs: false writes no output" "$(cat "$ghout")" ""

: > "$ghout"
run_cmd in_repo "$script" plain
expect_rc "explicit app with no notifs key" 1
expect_eq "explicit app with no notifs key writes no output" "$(cat "$ghout")" ""

# an explicit app that is not registered at all also fails
: > "$ghout"
run_cmd in_repo "$script" nosuch
expect_rc "explicit unknown app" 1
expect_eq "explicit unknown app writes no output" "$(cat "$ghout")" ""

# explicit app with notifs: true is selected alone
: > "$ghout"
run_cmd in_repo "$script" on-b
expect_rc "explicit opted-in app" 0
expect_eq "explicit opted-in app: only that app" "$(grep '^apps=' "$ghout")" 'apps=["on-b"]'
expect_eq "explicit opted-in app: has_apps" "$(grep '^has_apps=' "$ghout")" "has_apps=true"

# no app: every opted-in app
: > "$ghout"
run_cmd in_repo "$script" ""
expect_rc "empty input" 0
expect_eq "empty input: every notifs app, none of the others" "$(grep '^apps=' "$ghout")" 'apps=["on-a","on-b"]'
expect_eq "empty input: has_apps" "$(grep '^has_apps=' "$ghout")" "has_apps=true"

# no app and nothing opted in: not an error, has_apps=false
none="$T_TMP/none"
mkrepo "$none"
mkapp "$none" off-app 'schema_version: 1\nnotifs: false\n'
commit "$none"
: > "$ghout"
in_none() { ( cd "$none" || exit 99; GITHUB_OUTPUT="$ghout" "$@" ); }
run_cmd in_none "$script" ""
expect_rc "empty input, nothing opted in" 0
expect_eq "empty input, nothing opted in: apps" "$(grep '^apps=' "$ghout")" "apps=[]"
expect_eq "empty input, nothing opted in: has_apps" "$(grep '^has_apps=' "$ghout")" "has_apps=false"

run_cmd in_repo "$script"
expect_rc "usage" 2

t_finish
