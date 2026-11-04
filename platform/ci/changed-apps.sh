#!/usr/bin/env bash
# changed-apps.sh: the apps a push changed, as a sorted compact JSON array of names on stdout.
#
#   platform/ci/changed-apps.sh <before> <after>      run inside the git checkout (needs jq)
#
# An app is a directory apps/<name>/ with a tracked app.yaml at <after>. It is listed when <before>..<after> touches a
# path under apps/<name>/. An all-zero or unknown <before> (absent from the checkout, empty, not a commit) means every
# app. A removed app (no app.yaml at <after>) is never listed. Exit 0 on success (an empty list prints []), 1 on a
# failure, 2 on usage.
set -uo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: changed-apps.sh <before> <after>" >&2
  exit 2
fi
before="$1"
after="$2"

if ! git rev-parse --verify --quiet "${after}^{commit}" > /dev/null; then
  echo "changed-apps: <after> is not a commit in this checkout: $after" >&2
  exit 1
fi

tree="$(git ls-tree -r --name-only "$after" -- apps/)" || { echo "changed-apps: cannot list the tree of $after" >&2; exit 1; }
apps=()
while IFS= read -r path; do
  case "$path" in
    apps/*/app.yaml)
      name="${path#apps/}"; name="${name%/app.yaml}"
      # only apps/<name>/app.yaml, never a nested copy such as apps/<name>/testdata/app.yaml
      case "$name" in */*) ;; *) apps+=("$name") ;; esac ;;
  esac
done <<< "$tree"

all=0
case "$before" in
  "" | *[!0-9a-f]*) all=1 ;;
  *[1-9a-f]*) git rev-parse --verify --quiet "${before}^{commit}" > /dev/null || all=1 ;;
  *) all=1 ;; # all zeros
esac

changed=()
if [ "$all" -eq 1 ]; then
  changed=("${apps[@]}")
else
  diff="$(git diff --no-renames --name-only "$before" "$after" -- apps/)" || { echo "changed-apps: git diff failed for $before..$after" >&2; exit 1; }
  for name in "${apps[@]}"; do
    while IFS= read -r p; do
      case "$p" in "apps/$name/"*) changed+=("$name"); break ;; esac
    done <<< "$diff"
  done
fi

if [ "${#changed[@]}" -eq 0 ]; then
  echo "[]"
  exit 0
fi
printf '%s\n' "${changed[@]}" | LC_ALL=C sort -u | jq -R . | jq -sc .
