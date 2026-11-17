#!/usr/bin/env bash
# notifs-resolve.sh: the apps notifs-exchange.yml fans out over, written as step outputs.
#
#   platform/ci/notifs-resolve.sh <app>      run from the repo root; <app> is one app name, or "" for every notifs app
#
# Takes the registered apps (resolve-apps.sh dispatch: `all` for an empty input, else the named tracked app) and keeps
# only those with `notifs: true` (notifs-apps.sh). Appends `apps=<json array>` and `has_apps=true|false` to the file
# named by $GITHUB_OUTPUT (stdout when unset). An explicit <app> that does not opt in exits 1 and writes nothing, so a
# typo or a forgotten `notifs: true` fails loudly. An empty input with no opted-in app is not an error (has_apps=false).
# Exit 0 on success, 1 on a failure, 2 on usage.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -ne 1 ]; then
  echo "usage: notifs-resolve.sh <app|empty>" >&2
  exit 2
fi
app="$1"
out="${GITHUB_OUTPUT:-/dev/stdout}"

target="$app"
[ -n "$target" ] || target=all

registered="$("$here/resolve-apps.sh" dispatch "$target")" || exit 1
apps="$("$here/notifs-apps.sh" "$registered")" || exit 1
count="$(jq 'length' <<< "$apps")" || exit 1

if [ "$count" -eq 0 ] && [ -n "$app" ]; then
  echo "resolve: $app does not set notifs: true in its app.yaml; nothing is exchanged" >&2
  exit 1
fi

echo "apps=$apps" >> "$out"
if [ "$count" -eq 0 ]; then
  echo "has_apps=false" >> "$out"
  echo "resolve: no app sets notifs: true, nothing to do"
else
  echo "has_apps=true" >> "$out"
  echo "resolve: exchanging $apps"
fi
