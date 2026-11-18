#!/usr/bin/env bash
# test-class: docker
# test_sqlc.sh: the committed sqlc output (internal/app/db) equals what the pinned sqlc generates from sql/ and
# migrations/. The image reference is read from the Dockerfile's `sqlc` stage, so there is one pin. `sqlc diff` prints
# the difference and exits non-zero when the committed code is stale; regenerate with `sqlc generate` (same image).
#
# Needs docker; without a usable docker daemon it skips with a loud notice and exits 0. REQUIRE_DOCKER=1 turns a skip
# into a failure (a skip is not a pass).
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

skip() {
  if [ "${REQUIRE_DOCKER:-0}" = 1 ]; then
    echo "FAIL: $(basename "$0"): $1 (REQUIRE_DOCKER=1 turns a skip into a failure)"
    exit 1
  fi
  echo "################################################################"
  echo "## $(basename "$0") SKIPPED: $1"
  echo "## The sqlc drift check did NOT run. Run it on a docker host before merge (REQUIRE_DOCKER=1)."
  echo "################################################################"
  exit 0
}

img="$(awk 'toupper($1) == "FROM" && toupper($3) == "AS" && $4 == "sqlc" { print $2 }' "$here/Dockerfile")"
if ! [[ "$img" =~ ^sqlc/sqlc:[0-9.]+@sha256:[0-9a-f]{64}$ ]]; then
  echo "FAIL: test_sqlc: cannot read a pinned sqlc image from the Dockerfile sqlc stage (got '$img')"
  exit 1
fi

command -v docker > /dev/null 2>&1 || skip "docker is not installed"
docker info > /dev/null 2>&1 || skip "the docker daemon is not reachable by this user"

if ! docker image inspect "$img" > /dev/null 2>&1; then
  if ! timeout 300 docker pull -q "$img" > /dev/null 2>&1; then
    skip "cannot pull $img (image pull failure: offline or rate-limited, not a code failure)"
  fi
fi

log="$(mktemp)"
trap 'rm -f -- "$log"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

echo "test_sqlc: sqlc diff against the committed internal/app/db"
# The mount is read-only: diff never writes. --user keeps the container off root.
if timeout 120 docker run --rm --user "$(id -u):$(id -g)" -v "$here:/src:ro" -w /src "$img" diff > "$log" 2>&1; then
  echo "test_sqlc: 1 passed, 0 failed"
else
  echo "FAIL: test_sqlc: the committed sqlc output differs from what the pinned sqlc generates, or sqlc failed"
  tail -n 60 "$log"
  exit 1
fi
