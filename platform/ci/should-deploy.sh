#!/usr/bin/env bash
# should-deploy.sh: decide whether a deploy job still has anything to do (a deploy never goes backwards).
#
#   platform/ci/should-deploy.sh <own-sha> <live-rc> <live-output>      run inside the git checkout
#
# Prints `deploy` or `skip <reason>` and exits 0. It prints skip only when <live-output> is a sha that exists in the
# checkout as a commit and <own-sha> is a strict ancestor of it. An equal sha, an empty output, or a live tag that is not
# a known commit prints deploy (a newer merge merely existing on main never causes a skip). A non-zero <live-rc> exits 1
# (never deploy blind). Exit 2 on usage.
set -uo pipefail

if [ "$#" -ne 3 ]; then
  echo "usage: should-deploy.sh <own-sha> <live-rc> <live-output>" >&2
  exit 2
fi
own="$1"
live_rc="$2"
live="$3"

case "$live_rc" in
  "" | *[!0-9]*) echo "should-deploy: live-rc is not a number: $live_rc" >&2; exit 2 ;;
esac
if [ "$live_rc" -ne 0 ]; then
  echo "should-deploy: reading the live tag failed (rc=$live_rc); refusing to deploy blind" >&2
  exit 1
fi

# Only the last non-empty line, whitespace trimmed, is the tag.
live="$(printf '%s\n' "$live" | sed -e 's/[[:space:]]*$//' -e '/^$/d' | tail -n 1)"
if [ -z "$live" ]; then
  echo "deploy"
  exit 0
fi
if ! [[ "$live" =~ ^[0-9a-f]{40}$ ]] || ! git cat-file -e "${live}^{commit}" 2> /dev/null; then
  echo "deploy"
  exit 0
fi
if ! git cat-file -e "${own}^{commit}" 2> /dev/null; then
  echo "should-deploy: own sha is not a commit in this checkout: $own" >&2
  exit 1
fi
own_full="$(git rev-parse "${own}^{commit}")"
if [ "$own_full" = "$live" ]; then
  echo "deploy"
  exit 0
fi
anc=0
git merge-base --is-ancestor "$own_full" "$live" || anc=$?
case "$anc" in
  0) echo "skip live tag $live is newer than $own_full" ;;
  1) echo "deploy" ;;
  *) echo "should-deploy: git merge-base failed (rc=$anc)" >&2; exit 1 ;;
esac
exit 0
