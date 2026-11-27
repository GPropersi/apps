#!/usr/bin/env bash
# Offline tests for the cross-app claim checker: each app claims {name, hostname}, a value claimed by two
# different apps is refused, and an unreadable or name-less file fails rather than being skipped.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"

t_init
checker="$here/check-unique-hosts.sh"
cases="$T_TMP/cases"
mkdir -p "$cases"

# app <dir> <name> [hostname]: write $cases/<dir>/app.yaml with a name and an optional hostname. Echoes the path.
app() {
  mkdir -p "$cases/$1"
  {
    printf 'schema_version: 1\nname: %s\n' "$2"
    if [ -n "${3:-}" ]; then printf 'hostname: %s\n' "$3"; fi
  } > "$cases/$1/app.yaml"
  echo "$cases/$1/app.yaml"
}

a="$(app a alpha)"
b="$(app b bravo dates)"
c="$(app c charlie)"

run_cmd "$checker"
expect_rc "no args is a usage error" 2

run_cmd "$checker" "$a" "$b" "$c"
expect_rc "distinct apps pass" 0

run_cmd "$checker" "$a"
expect_rc "one app passes" 0

d="$(app d delta dates)"
run_cmd "$checker" "$a" "$b" "$d"
expect_rc "two apps with the same hostname fail" 1
expect_out_has "same hostname: names the second file and value" "$d: 'dates' is also claimed by app 'bravo' ($b)"

e="$(app e echo alpha)"
run_cmd "$checker" "$a" "$e"
expect_rc "a hostname equal to another app's name fails" 1
expect_out_has "hostname equals name: reason" "$e: 'alpha' is also claimed by app 'alpha' ($a)"

run_cmd "$checker" "$e" "$a"
expect_rc "the clash is found in either order" 1
expect_out_has "reverse order: names the second file" "$a: 'alpha' is also claimed by app 'echo' ($e)"

run_cmd "$checker" "$a" "$a"
expect_rc "the same path twice is a usage error" 2

f="$(app f foxtrot foxtrot)"
run_cmd "$checker" "$f"
expect_rc "an app claiming its own name twice is not a clash" 0

run_cmd "$checker" "$a" "$cases/missing/app.yaml"
expect_rc "an unreadable file fails" 1
expect_out_has "unreadable: reason" "$cases/missing/app.yaml: cannot read name"

mkdir -p "$cases/noname"
printf 'schema_version: 1\nhostname: orphan\n' > "$cases/noname/app.yaml"
run_cmd "$checker" "$a" "$cases/noname/app.yaml"
expect_rc "a file with no name fails" 1
expect_out_has "no name: reason" "$cases/noname/app.yaml: cannot read name"

mkdir -p "$cases/bad"
printf 'name: [oops\n\tbad\n' > "$cases/bad/app.yaml"
run_cmd "$checker" "$cases/bad/app.yaml"
expect_rc "an unparseable file fails" 1
expect_out_has "unparseable: reason" "$cases/bad/app.yaml: cannot read name"

t_finish
