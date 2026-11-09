#!/usr/bin/env bash
# test-class: docker
# test_template_go_react_live.sh: the template smoke test CI runs. Scaffolds a fresh app (tmpl<random>) from the real
# go-react template into a scratch copy of the repo with the real `app-new.sh`, then runs that app's own test_*.sh files
# through the scratch copy's platform/test/run.sh, proving a fresh app passes its own tests unchanged (Go tests, the web
# build and tests, sqlc drift, and the final image against real Postgres and Redis).
#
# Cost: the nested files run serially (inside a runner `run.sh` forces one job and skips prewarm), so the outer class
# prewarms the template images (node, sqlc, golang, distroless, Postgres, Redis) before this file starts and the nested
# runs are warm. TEST_FILE_TIMEOUT is one global run.sh knob (default 1800 s, not settable per file), so this file keeps
# the default and wraps its nested run.sh in its own inner `timeout` (TEST_FILE_TIMEOUT minus 300 s, at most 1500 s): a hang is killed
# here, naming its step, before the outer limit fires. A killed nested test_image.sh can leave containers named tmpl-<pid>-<random>
# (see its header for the cleanup command). Measured nested wall time, warm image cache: about 34 s
# for the four nested files run serially under the outer runner (2026-11-08, 12 CPUs; test_image 18 s, test_web 7 s,
# test_go 8 s, test_sqlc under 1 s), far below the 1800 s global limit and the 1500 s inner timeout. A cold cache adds
# the image pulls and the npm and Go module downloads; stay well under about 900 s or investigate.
#
# Needs docker; without a usable docker daemon it skips with a loud notice and exits 0. REQUIRE_DOCKER=1 turns a skip
# into a failure (a skip is not a pass).
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
root="$(cd "$here/../.." && pwd)"

# The inner timeout must fire before the outer per-file limit (TEST_FILE_TIMEOUT, default 1800 s): 300 s earlier, at most 1500 s.
file_timeout="${TEST_FILE_TIMEOUT:-1800}"
inner_timeout=$((file_timeout - 300))
[ "$inner_timeout" -le 1500 ] || inner_timeout=1500
if [ "$inner_timeout" -lt 120 ]; then
  echo "FAIL: TEST_FILE_TIMEOUT=$file_timeout leaves no room for an inner timeout (need at least 420)"
  exit 1
fi

skip() {
  if [ "${REQUIRE_DOCKER:-0}" = 1 ]; then
    echo "FAIL: $(basename "$0"): $1 (REQUIRE_DOCKER=1 turns a skip into a failure)"
    exit 1
  fi
  echo "################################################################"
  echo "## $(basename "$0") SKIPPED: $1"
  echo "## A freshly scaffolded app was NOT run through its own tests. Run it on a docker host before merge (REQUIRE_DOCKER=1)."
  echo "################################################################"
  exit 0
}

command -v docker > /dev/null 2>&1 || skip "docker is not installed"
docker info > /dev/null 2>&1 || skip "the docker daemon is not reachable by this user"

t_init

S="$T_TMP/repo"
mkdir -p "$S/apps"
step() { echo "test_template_go_react_live: $*"; }

step "copying the repo's platform/, templates/ and Makefile into a scratch tree"
for item in platform templates; do
  mkdir -p "$S/$item"
  tar -C "$root/$item" --exclude=node_modules --exclude=./go-react/web/dist -cf - . | tar -C "$S/$item" -xf - \
    || { echo "FAIL: copying $item into the scratch tree"; exit 1; }
done
cp -- "$root/Makefile" "$S/Makefile" || { echo "FAIL: copying the Makefile"; exit 1; }

name="tmpl$RANDOM"
step "app-new $name"
run_cmd "$S/platform/scaffold/app-new.sh" "$name" --purpose "Template smoke test app"
expect_rc "app-new scaffolds $name" 0
if [ "$rc" -ne 0 ]; then
  t_finish
  exit 1
fi
expect_file "the scaffold carries its own tests" "$S/apps/$name/test_go.sh"

# "Must be true": the scaffold passes the repo lints once git add-ed. Same three lints that read tracked files, on a
# scratch git work tree of the scratch repo (the real go toolchain vets and formats the scaffold, digest included).
git -C "$S" init -q || { echo "FAIL: git init in the scratch repo"; exit 1; }
git -C "$S" add -A || { echo "FAIL: git add in the scratch repo"; exit 1; }
for lint in check-apps check-template-copies check-go; do
  run_cmd "$S/platform/lint/$lint.sh" --root "$S"
  expect_rc "the scaffold passes $lint" 0
done

mapfile -t files < <(cd "$S" && find "apps/$name" -maxdepth 1 -name 'test_*.sh' | LC_ALL=C sort)
if [ "${#files[@]}" -eq 0 ]; then
  echo "FAIL: the scaffolded app has no test_*.sh"
  exit 1
fi
step "running ${#files[@]} nested file(s) under timeout $inner_timeout s: ${files[*]}"

log="$T_TMP/nested.txt"
start=$SECONDS
nested_rc=0
timeout -k 20 "$inner_timeout" "$S/platform/test/run.sh" "${files[@]}" > "$log" 2>&1 || nested_rc=$?
elapsed=$((SECONDS - start))
step "nested run.sh rc=$nested_rc in ${elapsed}s"
cat -- "$log"

if [ "$nested_rc" -eq 124 ] || [ "$nested_rc" -eq 137 ]; then
  _fail "nested run of the scaffolded app's tests" "hit the inner ${inner_timeout}s timeout (see the last '== apps/$name/...' line above for the step that hung)"
else
  expect_eq "the scaffolded app passes its own tests unchanged" "$nested_rc" "0"
fi
# Recorded in the header: far below the global limit. A regression past about 900 s on a warm cache should be visible.
if [ "$elapsed" -lt 900 ]; then _pass; else _fail "nested wall time ${elapsed}s" "is not well under the 1800 s global limit (about 900 s allowed on a warm cache)"; fi

t_finish
