#!/usr/bin/env bash
# validate-tracked.sh: validate every tracked apps/*/app.yaml of the git repo in the current directory, then check
# no two apps claim the same name or hostname (check-unique-hosts.sh, one invocation over all files).
# Passes vacuously when there are none. This is what `make lint` runs.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
listing="$(mktemp)"
trap 'rm -f "$listing"' EXIT
git ls-files -z -- 'apps/*/app.yaml' > "$listing" || exit 1
files=()
while IFS= read -r -d '' f; do
  files+=("$f")
done < "$listing"
[ "${#files[@]}" -gt 0 ] || exit 0

rc=0
"$here/validate-app-yaml.sh" "${files[@]}" || rc=1
"$here/check-unique-hosts.sh" "${files[@]}" || rc=1
exit "$rc"
