#!/usr/bin/env bash
# Self-test for lib.sh: the stub harness and expect_* helpers behave as documented.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
. "$here/lib.sh"
t_init

t_stub fakecmd 0 "hello"
run_cmd fakecmd one "two words"
expect_rc "stub exits 0" 0
expect_out_has "stub prints its stdout" "hello"
expect_calls_has "stub logs argv" "fakecmd one two words"
expect_calls_lacks "stub log lacks unrelated call" "othercmd"

t_stub failcmd 7
run_cmd failcmd
expect_rc "stub exit code is configurable" 7

t_reset_calls
expect_eq "reset empties the call log" "$(t_calls)" ""

expect_eq "t_ip4 assembles from pieces" "$(t_ip4 10 1 2 3)" "10"".1.2"".3"
expect_file "temp root exists" "$T_TMP"

# A failing expectation must be counted as a failure (checked on a copy of the counters).
saved_passed="$passed"
run_cmd failcmd
failed_before="$failed"
expect_rc "deliberate mismatch" 0 > /dev/null
expect_eq "mismatch increments failed" "$failed" "$((failed_before + 1))"
failed=$((failed - 1))
passed="$saved_passed"
passed=$((passed + 1))

t_finish
