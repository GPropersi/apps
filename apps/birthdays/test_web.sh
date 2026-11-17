#!/usr/bin/env bash
# test-class: docker
# test_web.sh: the web unit tests, run inside the pinned node image by building the Dockerfile's `web-test` stage (so no
# local Node is needed and the build output never touches the working tree).
#
# Needs docker; without a usable docker daemon it skips with a loud notice and exits 0. REQUIRE_DOCKER=1 turns a skip
# into a failure (a skip is not a pass):
#   REQUIRE_DOCKER=1 bash templates/go-react/test_web.sh > /tmp/claude/web.txt 2>&1
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

skip() {
  if [ "${REQUIRE_DOCKER:-0}" = 1 ]; then
    echo "FAIL: $(basename "$0"): $1 (REQUIRE_DOCKER=1 turns a skip into a failure)"
    exit 1
  fi
  echo "################################################################"
  echo "## $(basename "$0") SKIPPED: $1"
  echo "## The web tests did NOT run. Run them on a docker host before merge (REQUIRE_DOCKER=1)."
  echo "################################################################"
  exit 0
}

command -v docker > /dev/null 2>&1 || skip "docker is not installed"
docker info > /dev/null 2>&1 || skip "the docker daemon is not reachable by this user"

tag="tmpl-web-$$-$RANDOM"
log="$(mktemp)"
cleanup() {
  docker image rm -f "$tag" > /dev/null 2>&1
  rm -f -- "$log"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "test_web: docker build --target web-test"
if timeout 900 docker build --target web-test --tag "$tag" "$here" > "$log" 2>&1; then
  echo "test_web: 1 passed, 0 failed"
else
  echo "FAIL: test_web: the web-test stage failed (tail of the build log follows)"
  tail -n 60 "$log"
  exit 1
fi
