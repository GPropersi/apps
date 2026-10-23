#!/usr/bin/env bash
# The skip contract of test_backup_live.sh, proven without docker or restic: with restic absent from PATH the live test
# exits 0 with a loud banner; under REQUIRE_DOCKER=1 the same skip is a failure (exit 1). A stub docker answers every call,
# so the restic check is the one that decides. Also: BR2LIVE_SKIP=1 skips (exit 0) and fails under REQUIRE_DOCKER=1.
# SC1091: lib.sh is sourced by relative path. SC2034: rc and out are set by run_live and read by lib.sh's expect_* helpers.
# shellcheck disable=SC1091,SC2034
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"

t_init

bash_bin="$(command -v bash)"
bin="$T_TMP/pathdir"
mkdir -p "$bin"
for tool in dirname basename; do
  ln -s "$(command -v "$tool")" "$bin/$tool"
done
printf '#!/bin/sh\nexit 0\n' > "$bin/docker"
chmod +x "$bin/docker"

# run_live <label> [VAR=val...]: the live test with a PATH that holds only the stub docker, dirname and basename.
run_live() {
  shift
  rc=0
  out="$(env -i PATH="$bin" HOME="$T_TMP" "$@" "$bash_bin" "$here/test_backup_live.sh" 2>&1)" || rc=$?
}

run_live "restic absent"
expect_rc "restic absent: the live test exits 0" 0
expect_out_has "restic absent: loud skip banner" "SKIPPED: restic is not on PATH"

run_live "restic absent, REQUIRE_DOCKER" REQUIRE_DOCKER=1
expect_rc "restic absent under REQUIRE_DOCKER=1: exit 1" 1
expect_out_has "restic absent under REQUIRE_DOCKER=1: says why" "restic is not on PATH"

run_live "opt out" BR2LIVE_SKIP=1
expect_rc "BR2LIVE_SKIP=1: exit 0" 0
expect_out_has "BR2LIVE_SKIP=1: banner" "SKIPPED: BR2LIVE_SKIP=1"

run_live "opt out, REQUIRE_DOCKER" BR2LIVE_SKIP=1 REQUIRE_DOCKER=1
expect_rc "BR2LIVE_SKIP=1 under REQUIRE_DOCKER=1: exit 1" 1

t_finish
