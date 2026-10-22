#!/usr/bin/env bash
# Table tests for platform.sh (the forced-command dispatcher).
# Stubs docker/sudo/systemctl (shared call log, asserted empty) and logger (separate log).
# SC2016: payloads are single-quoted on purpose (they must not expand). SC1091: lib.sh is sourced by relative path.
# SC2154: out is set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2016,SC2154
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
run_cmd env -u SSH_ORIGINAL_COMMAND bash "$script" deploy myapp v1
expect_rc "argv fallback accepts deploy" 3
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

# platform ls: a docker stub that prints $PS_OUT_FILE and exits $PS_RC, logging its argv like the other stubs.
printf '#!/usr/bin/env bash\nprintf "docker" >> "$CALL_LOG"\nfor a in "$@"; do printf " %%s" "$a" >> "$CALL_LOG"; done\nprintf "\\n" >> "$CALL_LOG"\n[ -z "${PS_OUT_FILE-}" ] || cat "$PS_OUT_FILE"\nexit "${PS_RC:-0}"\n' > "$STUB_BIN/docker"
chmod +x "$STUB_BIN/docker"
ps_file="$T_TMP/ps.out"
ls_case() { # label rc-of-docker ; the rows are in $ps_file
  t_reset_calls
  run_cmd env PS_OUT_FILE="$ps_file" PS_RC="$2" SSH_ORIGINAL_COMMAND=ls bash "$script"
}
tab=$'\t'
rows() { # row... : write each argument as one docker ps line (fields already tab separated)
  printf '%s\n' "$@" > "$ps_file"
}

rows "web${tab}running${tab}Up 2 hours (healthy)" "api${tab}running${tab}Up 3 minutes"
ls_case "two apps" 0
expect_rc "ls: running apps" 0
expect_eq "ls: one row per app, sorted, health folded to a column" "$out" "$(printf 'api\trunning\tnone\nweb\trunning\thealthy')"
expect_calls_has "ls: same label filter as claude-helper ps, stopped containers included" "docker ps -a --filter label=platform.app --format"

rows "web${tab}running${tab}Up 2 hours" "web${tab}running${tab}Up 2 hours" "web${tab}exited${tab}Exited (0) 5 minutes ago"
ls_case "stopped sibling" 0
expect_eq "ls: a stopped sibling makes the app non-running, still one row" "$out" "$(printf 'web\texited\tnone')"

# The severity order restarting > dead > exited > paused > created, in every docker ps ordering of the same set.
states=(created paused exited dead restarting)
perm_ok=1
perms() { # prints all orderings of the states, one per line (space separated)
  local a b c d e
  for a in "${states[@]}"; do for b in "${states[@]}"; do [ "$b" != "$a" ] || continue
    for c in "${states[@]}"; do [ "$c" != "$a" ] && [ "$c" != "$b" ] || continue
      for d in "${states[@]}"; do [ "$d" != "$a" ] && [ "$d" != "$b" ] && [ "$d" != "$c" ] || continue
        for e in "${states[@]}"; do [ "$e" != "$a" ] && [ "$e" != "$b" ] && [ "$e" != "$c" ] && [ "$e" != "$d" ] || continue
          echo "$a $b $c $d $e"
        done; done; done; done; done
}
while read -r -a order; do
  : > "$ps_file"
  for s in "${order[@]}"; do printf 'web\t%s\tx\n' "$s" >> "$ps_file"; done
  ls_case "order ${order[*]}" 0
  [ "$out" = "$(printf 'web\trestarting\tnone')" ] || { perm_ok=0; _fail "ls: restarting wins in order ${order[*]}" "got '$out'"; }
done < <(perms)
expect_eq "ls: all 120 orderings of the five states were run" "$(perms | grep -c .)" "120"
[ "$perm_ok" -eq 0 ] || _pass
for pair in "dead exited dead" "exited paused exited" "paused created paused" "created running created"; do
  read -r s1 s2 want <<<"$pair"
  rows "web${tab}${s1}${tab}x" "web${tab}${s2}${tab}x"
  ls_case "pair $s1 $s2" 0
  expect_eq "ls: $s1 vs $s2 gives $want" "$out" "$(printf 'web\t%s\tnone' "$want")"
  rows "web${tab}${s2}${tab}x" "web${tab}${s1}${tab}x"
  ls_case "pair $s2 $s1" 0
  expect_eq "ls: $s2 vs $s1 gives $want (reversed ordering)" "$out" "$(printf 'web\t%s\tnone' "$want")"
done

# An unknown state ranks above all and is printed verbatim, whatever the order.
rows "web${tab}removing${tab}x" "web${tab}restarting${tab}x"
ls_case "unknown first" 0
expect_eq "ls: an unknown state outranks restarting (unknown first)" "$out" "$(printf 'web\tremoving\tnone')"
rows "web${tab}restarting${tab}x" "web${tab}removing${tab}x"
ls_case "unknown last" 0
expect_eq "ls: an unknown state outranks restarting (unknown last)" "$out" "$(printf 'web\tremoving\tnone')"

rows "web${tab}removing${tab}x" "web${tab}zzz${tab}x"
ls_case "two unknown states" 0
first="$out"
rows "web${tab}zzz${tab}x" "web${tab}removing${tab}x"
ls_case "two unknown states reversed" 0
expect_eq "ls: two unknown states resolve the same in both orders" "$out" "$first"
expect_eq "ls: the lexicographically smaller unknown state wins" "$first" "$(printf 'web\tremoving\tnone')"

# Health: worst across the set; "unhealthy" is never read as "healthy"; no text gives none.
rows "web${tab}running${tab}Up 1 hour (healthy)" "web${tab}running${tab}Up 1 hour (unhealthy)"
ls_case "unhealthy + healthy" 0
expect_eq "ls: unhealthy outranks healthy" "$out" "$(printf 'web\trunning\tunhealthy')"
rows "web${tab}running${tab}Up 1 hour (unhealthy)"
ls_case "unhealthy alone" 0
expect_eq "ls: unhealthy alone is not matched as healthy" "$out" "$(printf 'web\trunning\tunhealthy')"
rows "web${tab}running${tab}Up 1 hour (health: starting)" "web${tab}running${tab}Up 1 hour (healthy)"
ls_case "starting + healthy" 0
expect_eq "ls: starting outranks healthy" "$out" "$(printf 'web\trunning\tstarting')"
rows "web${tab}running${tab}Up 1 hour (health: starting)" "web${tab}running${tab}Up 1 hour (unhealthy)"
ls_case "starting + unhealthy" 0
expect_eq "ls: unhealthy outranks starting" "$out" "$(printf 'web\trunning\tunhealthy')"
rows "web${tab}running${tab}Up 1 hour"
ls_case "no health text" 0
expect_eq "ls: no health text gives none" "$out" "$(printf 'web\trunning\tnone')"

# No labelled containers: empty output, rc 0.
: > "$ps_file"
ls_case "none" 0
expect_rc "ls: no labelled containers exits 0" 0
expect_eq "ls: no labelled containers prints nothing" "$out" ""

# docker ps failing exits 1 with an error line and no rows, even when it printed rows first.
rows "web${tab}running${tab}Up 2 hours"
ls_case "docker fails" 3
expect_rc "ls: docker ps failure exits 1" 1
expect_out_has "ls: docker ps failure prints an error line" "platform: ls failed"
expect_out_lacks "ls: docker ps failure prints no partial rows" "web"

# Unparseable rows exit 1 with no rows (the good row is not printed either).
for bad in "web${tab}running" "web${tab}running${tab}Up${tab}extra" "${tab}running${tab}Up" "Bad_App${tab}running${tab}Up" "web${tab}${tab}Up" "web${tab}Running${tab}Up" "garbage"; do
  rows "good${tab}running${tab}Up" "$bad"
  ls_case "bad row" 0
  expect_rc "ls: unparseable row exits 1: $bad" 1
  expect_out_has "ls: unparseable row prints an error line: $bad" "platform: ls failed"
  expect_out_lacks "ls: unparseable row prints no partial rows: $bad" "good"
done

t_finish
