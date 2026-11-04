#!/usr/bin/env bash
# Tests for resolve-apps.sh: both entry paths, bad names, non-arrays, empty lists, `all`, known and unknown names.
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/resolve-apps.sh"

t_init
repo="$T_TMP/repo"
mkdir -p "$repo/apps/alpha" "$repo/apps/beta-2"
: > "$repo/apps/alpha/app.yaml"
: > "$repo/apps/beta-2/app.yaml"
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m init

in_repo() { ( cd "$repo" || exit 99; "$@" ); }

# call path
run_cmd in_repo "$script" call '["alpha","beta-2"]'
expect_rc "call: valid list" 0
expect_eq "call: valid list is printed compact" "$out" '["alpha","beta-2"]'

run_cmd in_repo "$script" call '[ "alpha" ]'
expect_eq "call: whitespace is normalised" "$out" '["alpha"]'

run_cmd in_repo "$script" call '[]'
expect_rc "call: empty list" 0
expect_eq "call: empty list prints []" "$out" '[]'

run_cmd in_repo "$script" call '["alpha","Bad_Name"]'
expect_rc "call: bad-regex element" 1
expect_out_has "call: bad element is named" "Bad_Name"

run_cmd in_repo "$script" call '["a"]'
expect_rc "call: too short a name" 1

run_cmd in_repo "$script" call '["-lead"]'
expect_rc "call: leading hyphen" 1

run_cmd in_repo "$script" call '["alpha; rm -rf /"]'
expect_rc "call: shell metacharacters" 1

run_cmd in_repo "$script" call '[""]'
expect_rc "call: empty element" 1

run_cmd in_repo "$script" call '["ab\ncd"]'
expect_rc "call: element with an embedded newline" 1

run_cmd in_repo "$script" call '["alpha\n"]'
expect_rc "call: trailing newline in an element" 1

run_cmd in_repo "$script" call '"alpha"'
expect_rc "call: non-array string" 1

run_cmd in_repo "$script" call '{"a":1}'
expect_rc "call: non-array object" 1

run_cmd in_repo "$script" call 'not json'
expect_rc "call: not JSON" 1

run_cmd in_repo "$script" call '[1,2]'
expect_rc "call: non-string elements" 1

# dispatch path
run_cmd in_repo "$script" dispatch all
expect_rc "dispatch: all" 0
expect_eq "dispatch: all lists every tracked app" "$out" '["alpha","beta-2"]'

run_cmd in_repo "$script" dispatch alpha
expect_rc "dispatch: known name" 0
expect_eq "dispatch: known name prints [name]" "$out" '["alpha"]'

run_cmd in_repo "$script" dispatch nosuch
expect_rc "dispatch: unknown name" 1
expect_out_has "dispatch: unknown name is named" "nosuch"

run_cmd in_repo "$script" dispatch 'Bad Name'
expect_rc "dispatch: bad-regex name" 1

mkdir -p "$T_TMP/empty"
git -C "$T_TMP/empty" init -q
git -C "$T_TMP/empty" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m init
empty_in() { ( cd "$T_TMP/empty" || exit 99; "$@" ); }
run_cmd empty_in "$script" dispatch all
expect_rc "dispatch: no apps, all" 0
expect_eq "dispatch: no apps prints []" "$out" '[]'

# a tracked directory whose name is not a valid app name is refused
mkdir -p "$repo/apps/Bad_App"
: > "$repo/apps/Bad_App/app.yaml"
git -C "$repo" add -A
git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -q -m bad
run_cmd in_repo "$script" dispatch all
expect_rc "dispatch: a tracked app with a bad name" 1
expect_out_has "dispatch: bad tracked name is named" "Bad_App"

run_cmd in_repo "$script" call
expect_rc "usage: missing argument" 2
run_cmd in_repo "$script" bogus x
expect_rc "usage: unknown mode" 2

t_finish
