#!/usr/bin/env bash
# build-arch.sh: map the PLATFORM_BUILD_ARCH variable to a runner label and a docker platform.
#
#   platform/ci/build-arch.sh <arch>
#
# arm64 prints runner=ubuntu-24.04-arm and platform=linux/arm64; amd64 prints runner=ubuntu-24.04 and
# platform=linux/amd64. Anything else (empty included) exits 1 naming the value. Exit 2 on usage.
set -uo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: build-arch.sh <arch>" >&2
  exit 2
fi
case "$1" in
  arm64) echo "runner=ubuntu-24.04-arm"; echo "platform=linux/arm64" ;;
  amd64) echo "runner=ubuntu-24.04"; echo "platform=linux/amd64" ;;
  *) echo "build-arch: PLATFORM_BUILD_ARCH must be arm64 or amd64, got '$1'" >&2; exit 1 ;;
esac
