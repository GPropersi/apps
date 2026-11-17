#!/usr/bin/env bash
# notifs-apps.sh: keep only the apps that opted in to 4irl-notifs, as a compact JSON array.
#
#   platform/ci/notifs-apps.sh <json-array>       run from the repo root (reads apps/<name>/app.yaml); needs jq
#
# The array is validated first (resolve-apps.sh call), so every name already matches the registry app-name regex. An app
# is kept when its apps/<name>/app.yaml has exactly one top-level `notifs:` line and it says `true` (the same test the
# host-side notifs-key.sh applies to the registry copy). An app with `notifs: false`, no notifs key, or no app.yaml is
# dropped. Exit 0 (an empty result prints []), 1 on an invalid list, 2 on usage.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -ne 1 ]; then
  echo "usage: notifs-apps.sh <json-array>" >&2
  exit 2
fi

list="$("$here/resolve-apps.sh" call "$1")" || exit 1

kept=()
while IFS= read -r name; do
  [ -n "$name" ] || continue
  f="apps/$name/app.yaml"
  [ -f "$f" ] || continue
  [ "$(grep -c '^notifs:' "$f" || true)" = "1" ] || continue
  grep -qxE 'notifs:[[:space:]]+true[[:space:]]*' "$f" || continue
  kept+=("$name")
done < <(jq -r '.[]' <<< "$list")

if [ "${#kept[@]}" -eq 0 ]; then
  echo "[]"
  exit 0
fi
printf '%s\n' "${kept[@]}" | jq -R . | jq -sc .
