#!/usr/bin/env bash
# Embedded-sources image build (Docker-gated). Writes the build inputs exactly as install-jobs.sh does (its own
# runner_inputs / testapp_inputs lists and payload_* functions, sourced with INSTALL_JOBS_SOURCE_ONLY=1) into two temp
# directories, then runs `docker build` for the runner Dockerfile (context = group 1's build inputs only) and for
# Dockerfile.testapp (context = group 2 plus group 1's go.mod and go.sum) from those directories alone. A file missing
# from the embedded payload, from an input list or from a Dockerfile COPY list fails here, and a build from the repo
# tree cannot hide it. The runner context holds no compose.yaml and no testapp source, as on the host.
# (test_install_jobs.sh runs against PATH stubs and holds no real build.)
#
# Without Docker the test skips loudly (exit 0) unless REQUIRE_DOCKER=1, which makes a missing Docker a failure.
# INSTALLER=<path> overrides the installer to read (default: install-jobs.sh beside this file).
# A registry pull error is a network problem, not a payload bug.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
installer="${INSTALLER:-$here/install-jobs.sh}"
runner_tag="pjimg-$$-runner"
testapp_tag="pjimg-$$-testapp"
tmp=""
rc=0

# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() {
  docker rmi -f "$runner_tag" "$testapp_tag" > /dev/null 2>&1
  [ -z "$tmp" ] || rm -rf "$tmp"
}
trap cleanup EXIT

if ! command -v docker > /dev/null 2>&1 || ! docker info > /dev/null 2>&1; then
  if [ "${REQUIRE_DOCKER:-0}" = 1 ]; then
    echo "FAIL: test_jobs_image.sh: docker is not available and REQUIRE_DOCKER=1"
    exit 1
  fi
  echo "SKIP: test_jobs_image.sh: docker is not available (set REQUIRE_DOCKER=1 to make this a failure)"
  exit 0
fi

if [ ! -f "$installer" ]; then
  echo "FAIL: test_jobs_image.sh: installer not found: $installer"
  exit 1
fi

tmp="$(mktemp -d)" || { echo "FAIL: test_jobs_image.sh: mktemp failed"; exit 1; }

rctx="$tmp/runner"
tctx="$tmp/testapp"
mkdir -p "$rctx" "$tctx"
# shellcheck disable=SC2016  # the script body is single-quoted on purpose; $1..$3 are its own arguments
if ! bash -c 'INSTALL_JOBS_SOURCE_ONLY=1; . "$1"; write_inputs "$2" runner_inputs && write_inputs "$3" testapp_inputs && payload_go_mod > "$3/go.mod" && payload_go_sum > "$3/go.sum"' bash "$installer" "$rctx" "$tctx"; then
  echo "FAIL: test_jobs_image.sh: could not write the build inputs with $installer"
  exit 1
fi

for f in "$rctx/Dockerfile" "$rctx/go.mod" "$rctx/go.sum" "$tctx/Dockerfile.testapp" "$tctx/go.mod" "$tctx/go.sum"; do
  if [ ! -s "$f" ]; then
    echo "FAIL: test_jobs_image.sh: build input ${f#"$tmp"/} is missing or empty from $installer"
    rc=1
  fi
done
[ "$rc" = 0 ] || exit 1

if docker build -f "$rctx/Dockerfile" --build-arg VERSION=test -t "$runner_tag" "$rctx" > "$tmp/build-runner.log" 2>&1; then
  echo "PASS: runner image builds from the embedded payload alone"
else
  echo "FAIL: runner image does not build from the embedded payload alone (a missing file means the payload, the input list or the Dockerfile COPY list lacks it; a pull error is a network problem)"
  tail -n 25 "$tmp/build-runner.log"
  rc=1
fi

if docker build -f "$tctx/Dockerfile.testapp" --build-arg VERSION=test -t "$testapp_tag" "$tctx" > "$tmp/build-testapp.log" 2>&1; then
  echo "PASS: testapp image builds from the embedded payload alone"
else
  echo "FAIL: testapp image does not build from the embedded payload alone (a missing file means the payload, the input list or the Dockerfile.testapp COPY list lacks it; a pull error is a network problem)"
  tail -n 25 "$tmp/build-testapp.log"
  rc=1
fi

exit "$rc"
