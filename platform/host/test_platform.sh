#!/usr/bin/env bash
# Table tests for platform.sh (the forced-command dispatcher).
# Stubs docker/sudo/systemctl (shared call log, asserted empty) and logger (separate log).
# SC2016: payloads are single-quoted on purpose (they must not expand). SC1091: lib.sh is sourced by relative path.
# shellcheck disable=SC1091,SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/platform.sh"

t_init
t_stub docker 0
t_stub sudo 0
t_stub systemctl 0
LOGGER_LOG="$T_TMP/logger.log"
: > "$LOGGER_LOG"
export LOGGER_LOG
# shellcheck disable=SC2016
printf '#!/usr/bin/env bash\nfor a in "$@"; do printf "%%s\\n" "$a" >> "$LOGGER_LOG"; done\n' > "$STUB_BIN/logger"
chmod +x "$STUB_BIN/logger"

# The caller's locale is UTF-8 on purpose: the dispatcher must not depend on it.
run_payload() {
  run_cmd env LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 SSH_ORIGINAL_COMMAND="$1" bash "$script"
}

# reject_case <label> <payload> [<seed>]: exit exactly 2, no stub reached, seed absent from output and log.
reject_case() {
  t_reset_calls
  : > "$LOGGER_LOG"
  run_payload "$2"
  expect_rc "reject: $1" 2
  expect_eq "reject no stub call: $1" "$(t_calls)" ""
  expect_out_has "reject prints usage: $1" "usage: platform"
  if [ -n "${3:-}" ]; then
    expect_out_lacks "reject output lacks seed: $1" "$3"
    if grep -qF -- "$3" "$LOGGER_LOG"; then _fail "reject log lacks seed: $1" "seed in logger argv"; else _pass; fi
  fi
  if grep -q 'reason=' "$LOGGER_LOG"; then _pass; else _fail "reject logs a reason: $1" "no reason= in logger argv"; fi
}

# accept_case <label> <payload> <placeholder-name>: exit exactly 3 from its own placeholder.
accept_case() {
  t_reset_calls
  run_payload "$2"
  expect_rc "accept: $1" 3
  expect_out_has "accept placeholder: $1" "$3 is not implemented"
  expect_eq "accept no stub call: $1" "$(t_calls)" ""
}

accept_case "deploy" "deploy myapp v1.2.3" deploy
accept_case "deploy sha tag" "deploy my-app abc123_DEF.4-5" deploy
accept_case "rollback" "rollback myapp" rollback
accept_case "ls" "ls" ls
accept_case "app min length 2" "rollback ab" rollback
accept_case "tag max length 128" "deploy myapp $(printf 'a%.0s' $(seq 1 128))" deploy

accept_case "app max length 31" "rollback a$(printf 'b%.0s' $(seq 1 30))" rollback
accept_case "longest valid command (app 31, tag 128)" "deploy a$(printf 'b%.0s' $(seq 1 30)) $(printf 'a%.0s' $(seq 1 128))" deploy

reject_case "empty" ""
reject_case "spaces only" "   "
reject_case "unknown command" "ZQXA1reboot"
reject_case "unknown command with args" "shell myapp"
reject_case "uppercase command" "LS"
reject_case "deploy no args" "deploy"
reject_case "deploy one arg" "deploy myapp"
reject_case "deploy extra arg" "deploy myapp v1 extra"
reject_case "rollback extra arg" "rollback myapp v1"
reject_case "rollback no arg" "rollback"
reject_case "new-db extra arg" "new-db myapp v1"
reject_case "ls extra arg" "ls myapp"
reject_case "leading space" " ls"
reject_case "trailing space" "ls "
reject_case "double space" "deploy  myapp v1"
reject_case "tab separator" $'deploy\tmyapp v1'
reject_case "semicolon" "deploy myapp ZQXB2;id" ZQXB2
reject_case "semicolon in app" "deploy ZQXB3;id v1" ZQXB3
reject_case "command substitution" 'deploy myapp $(ZQXB4)' ZQXB4
reject_case "backticks" 'deploy myapp `ZQXB5`' ZQXB5
reject_case "pipe" "ls | ZQXB6" ZQXB6
reject_case "ampersand" "ls && ZQXB7" ZQXB7
reject_case "redirect" "ls > ZQXB8" ZQXB8
reject_case "dotdot path in app" "deploy ../ZQXB9 v1" ZQXB9
reject_case "path in app" "rollback ZQXC1/x" ZQXC1
reject_case "space in arg via quotes" 'deploy "my app" v1'
reject_case "leading dash app" "rollback -ZQXC2" ZQXC2
reject_case "leading dash tag" "deploy myapp -x"
reject_case "dotdot tag" "deploy myapp .."
reject_case "leading dot tag" "deploy myapp .hidden"
reject_case "app too short" "rollback a"
reject_case "app starts with digit" "rollback 1app"
reject_case "app uppercase" "rollback MyApp"
reject_case "app underscore" "rollback my_app"
reject_case "app too long (32)" "rollback a$(printf 'b%.0s' $(seq 1 31))"
reject_case "tag too long (129)" "deploy myapp $(printf 'a%.0s' $(seq 1 129))"
reject_case "over-length 257" "ls $(printf 'a%.0s' $(seq 1 254))"
reject_case "over-length 300" "deploy myapp $(printf 'a%.0s' $(seq 1 300))"
reject_case "unicode in app" "rollback caf$(printf '\303\251')ZQXC3" ZQXC3
reject_case "unicode in tag" "deploy myapp v1$(printf '\303\251')ZQXC4" ZQXC4
reject_case "unicode over-length bytes" "deploy myapp $(printf '\303\251%.0s' $(seq 1 130))"
reject_case "newline after valid command" $'ls\nZQXC5' ZQXC5
reject_case "newline after valid deploy" $'deploy myapp v1\nZQXC6' ZQXC6
reject_case "carriage return" $'ls\rZQXC7' ZQXC7
reject_case "leading newline" $'\nls'
reject_case "trailing newline" $'ls\n'

# The explicit newline check (not just the canonical-form backstop) is what fires, and it logs code and length only.
: > "$LOGGER_LOG"
run_payload $'ls\nZQXC8'
if grep -qF -- 'reason=newline len=8' "$LOGGER_LOG"; then _pass; else _fail "newline reason code and length logged" "$(cat "$LOGGER_LOG")"; fi

# Under a UTF-8 caller locale, non-ASCII is rejected by the dispatcher's own checks (reason codes logged).
: > "$LOGGER_LOG"
run_payload "rollback caf$(printf '\303\251')"
if grep -qF -- 'reason=bad-app' "$LOGGER_LOG"; then _pass; else _fail "unicode app rejected as bad-app" "$(cat "$LOGGER_LOG")"; fi
: > "$LOGGER_LOG"
run_payload "deploy myapp $(printf '\303\251%.0s' $(seq 1 130))"
if grep -qF -- 'reason=too-long len=273' "$LOGGER_LOG"; then _pass; else _fail "unicode over-length counted in bytes" "$(cat "$LOGGER_LOG")"; fi

# A usage printer that fails must still reject with exit 2.
run_cmd env SSH_ORIGINAL_COMMAND="bad" bash -c 'exec 2>&-; exec bash "$0"' "$script"
expect_rc "reject exits 2 even if stderr is closed" 2

# new-db hands over to the installed helper. The dispatcher's helper path is a readonly constant (no override), so the
# test runs a copy whose path points at a stub helper in the scratch tree.
HELPER="$T_TMP/new-db-helper.sh"
HELPER_ARGS="$T_TMP/new-db-helper.args"
copy="$T_TMP/platform-under-test.sh"
sed "s#^readonly NEW_DB_HELPER=.*#readonly NEW_DB_HELPER='$HELPER'#" "$script" > "$copy"
if grep -qF "readonly NEW_DB_HELPER='$HELPER'" "$copy"; then _pass; else _fail "the helper path in the test copy was rewritten"; fi
run_copy() { run_cmd env LC_ALL=en_US.UTF-8 SSH_ORIGINAL_COMMAND="$1" bash "$copy"; }
if grep -qF "readonly NEW_DB_HELPER='/opt/platform/data/new-db.sh'" "$script"; then _pass; else _fail "the real helper path is /opt/platform/data/new-db.sh"; fi

rm -f "$HELPER" "$HELPER_ARGS"
t_reset_calls
run_copy "new-db myapp"
expect_rc "new-db with the helper absent exits 1" 1
expect_out_has "new-db with the helper absent says how to install it" "make host-data"
expect_eq "new-db with the helper absent makes no stub call" "$(t_calls)" ""

printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$#:$1:${NEW_DB_SECRETS_ROOT-unset}" > "%s"\necho "helper ran"\nexit 7\n' "$HELPER_ARGS" > "$HELPER"
chmod 644 "$HELPER"
run_copy "new-db myapp"
expect_rc "new-db with a non-executable helper exits 1" 1
chmod 755 "$HELPER"
NEW_DB_SECRETS_ROOT=/caller/chosen run_copy "new-db my-app"
expect_rc "new-db returns the helper's exit code" 7
expect_out_has "new-db runs the helper" "helper ran"
expect_eq "new-db passes exactly the app name and scrubs the caller's NEW_DB_* environment" "$(cat "$HELPER_ARGS")" "1:my-app:unset"
expect_eq "new-db makes no docker, sudo or systemctl call itself" "$(t_calls)" ""
rm -f "$HELPER_ARGS"
run_copy "new-db My_App"
expect_rc "new-db with an invalid app is rejected before the helper" 2
if [ -e "$HELPER_ARGS" ]; then _fail "an invalid app never reaches the helper"; else _pass; fi
run_copy "new-db myapp extra"
expect_rc "new-db with an extra argument is rejected before the helper" 2
if [ -e "$HELPER_ARGS" ]; then _fail "an extra argument never reaches the helper"; else _pass; fi

# The unset-variable and argv paths.
t_reset_calls
run_cmd env -u SSH_ORIGINAL_COMMAND bash "$script" ls
expect_rc "argv fallback accepts ls" 3
run_cmd env -u SSH_ORIGINAL_COMMAND bash "$script" rollback myapp
expect_rc "argv fallback accepts rollback" 3
run_cmd env -u SSH_ORIGINAL_COMMAND bash "$script"
expect_rc "no command and no args rejects" 2
run_cmd env -u SSH_ORIGINAL_COMMAND bash "$script" 'rollback' 'myapp;id'
expect_rc "argv fallback rejects metacharacters" 2
run_cmd env SSH_ORIGINAL_COMMAND="" bash "$script" ls
expect_rc "empty SSH_ORIGINAL_COMMAND does not fall back to argv" 2
run_cmd env SSH_ORIGINAL_COMMAND="bad" bash "$script" ls
expect_rc "SSH_ORIGINAL_COMMAND wins over argv" 2
expect_eq "no stub reached on argv paths" "$(t_calls)" ""

t_finish
