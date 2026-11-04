#!/usr/bin/env bash
# Tests for build-arch.sh: arm64 and amd64 map, anything else (empty included) fails naming the value.
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/build-arch.sh"

t_init

run_cmd "$script" arm64
expect_rc "arm64" 0
expect_eq "arm64 output" "$out" "runner=ubuntu-24.04-arm
platform=linux/arm64"

run_cmd "$script" amd64
expect_rc "amd64" 0
expect_eq "amd64 output" "$out" "runner=ubuntu-24.04
platform=linux/amd64"

run_cmd "$script" ""
expect_rc "empty" 1

run_cmd "$script" riscv64
expect_rc "unknown arch" 1
expect_out_has "unknown arch is named" "riscv64"

run_cmd "$script" ARM64
expect_rc "case matters" 1

run_cmd "$script"
expect_rc "usage" 2

t_finish
