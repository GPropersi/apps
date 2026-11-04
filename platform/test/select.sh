#!/usr/bin/env bash
# Test selection: `select.sh --base <ref>` prints, one per line and sorted, the test files the change since <ref>
# needs (git diff --name-only --no-renames <ref>...HEAD, resolved through platform/test/areas.map). Prints nothing when
# every changed path resolves to `none`. Any failure (bad ref, unreadable or malformed map, unknown area, a path no row
# matches) prints a named warning to stderr and prints every test file: selection fails toward more tests.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
# shellcheck disable=SC1091
. "$here/areamap-lib.sh"

base=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base)
      [ "$#" -ge 2 ] || { echo "usage: select.sh --base <ref>" >&2; exit 2; }
      base="$2"
      shift 2
      ;;
    *)
      echo "usage: select.sh --base <ref>" >&2
      exit 2
      ;;
  esac
done
[ -n "$base" ] || { echo "usage: select.sh --base <ref>" >&2; exit 2; }

# platform_tests <area>: platform/<area>/**/test_*.sh. app_tests <name>: apps/<name>/test_*.sh.
platform_tests() { [ -d "$root/platform/$1" ] && (cd "$root" && find "platform/$1" -name 'test_*.sh'); return 0; }
app_tests() { [ -d "$root/apps/$1" ] && (cd "$root" && find "apps/$1" -maxdepth 1 -name 'test_*.sh'); return 0; }
all_apps_tests() { [ -d "$root/apps" ] && (cd "$root" && find apps -mindepth 2 -maxdepth 2 -name 'test_*.sh'); return 0; }
all_tests() { platform_tests ""; all_apps_tests; }

fallback() {
  echo "select.sh: warning: $1; selecting every test" >&2
  all_tests | LC_ALL=C sort -u
  exit 0
}

case "$base" in -*) fallback "base '$base' looks like an option" ;; esac
am_load "$here/areas.map" || fallback "areas.map unusable ($AM_ERR)"
changed="$(git -C "$root" -c core.quotepath=false diff --name-only --no-renames "$base...HEAD")" ||
  fallback "git diff against '$base' failed"

selected=""
while IFS= read -r p; do
  [ -n "$p" ] || continue
  am_lookup "$p" || fallback "no areas.map row matches '$p'"
  targets="$AM_RESULT"
  if [[ "$p" =~ ^apps/([^/]+)/ ]] && [ "$targets" != "none" ]; then
    selected+="$(app_tests "${BASH_REMATCH[1]}")"$'\n'
    continue
  fi
  IFS=, read -ra ts <<<"$targets"
  for t in "${ts[@]}"; do
    case "$t" in
      none) ;;
      all) selected+="$(all_tests)"$'\n' ;;
      apps) selected+="$(all_apps_tests)"$'\n' ;;
      *)
        [ -d "$root/platform/$t" ] || fallback "areas.map names unknown area '$t' for '$p'"
        selected+="$(platform_tests "$t")"$'\n'
        ;;
    esac
  done
done <<<"$changed"

printf '%s' "$selected" | grep -v '^$' | LC_ALL=C sort -u || true
