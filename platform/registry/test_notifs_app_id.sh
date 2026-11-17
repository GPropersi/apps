#!/usr/bin/env bash
# Offline test for platform/lib/notifs-app-id.sh against the shared name -> app_id fixture that the Go helper also reads.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
# shellcheck source=../lib/notifs-app-id.sh
. "$here/../lib/notifs-app-id.sh"

t_init
fixture="$here/../../templates/go-react/internal/platform/testdata/notifs-app-ids.txt"
tab=$'\t'
vectors=0

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in '' | '#'*) continue ;; esac
  name="${line%%"$tab"*}"
  want="${line#*"$tab"}"
  vectors=$((vectors + 1))
  rc=0
  got="$(notifs_app_id "$name")" || rc=$?
  if [ "$want" = REFUSED ]; then
    expect_eq "'$name' is refused (rc)" "$rc" "1"
    expect_eq "'$name' prints nothing when refused" "$got" ""
  else
    expect_eq "'$name' maps to $want (rc)" "$rc" "0"
    expect_eq "'$name' maps to $want" "$got" "$want"
    if [[ "$got" =~ $NOTIFS_APP_ID_RE ]]; then _pass; else _fail "'$name' result matches the app_id rule"; fi
  fi
done < "$fixture"

if [ "$vectors" -ge 8 ]; then _pass; else _fail "the fixture holds at least 8 vectors (read $vectors)"; fi
expect_eq "birthdays vector exists" "$(grep -c '^birthdays	apps_birthdays$' "$fixture")" "1"
expect_eq "my-app vector exists" "$(grep -c '^my-app	apps_my_app$' "$fixture")" "1"

rc=0
notifs_app_id "" > /dev/null || rc=$?
expect_eq "an empty name is refused" "$rc" "1"
rc=0
notifs_app_id > /dev/null || rc=$?
expect_eq "no argument is refused" "$rc" "1"

t_finish
