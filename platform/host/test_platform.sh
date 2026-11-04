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

# The dispatcher's helper and state paths are readonly constants (no override), so the tests run a copy whose paths point
# at a stub helper and a state tree in the scratch dir. The real paths are asserted below.
HELPER="$T_TMP/new-db-helper.sh"
HELPER_ARGS="$T_TMP/new-db-helper.args"
DEPLOY_STUB="$T_TMP/deploy-helper.sh"
DEPLOY_REC="$T_TMP/deploy-helper.rec"
STATE_TREE="$T_TMP/state-tree"
copy="$T_TMP/platform-under-test.sh"
sed -e "s#^readonly NEW_DB_HELPER=.*#readonly NEW_DB_HELPER='$HELPER'#" \
  -e "s#^readonly DEPLOY_HELPER=.*#readonly DEPLOY_HELPER='$DEPLOY_STUB'#" \
  -e "s#^readonly DEPLOY_STATE_DIR=.*#readonly DEPLOY_STATE_DIR='$STATE_TREE'#" "$script" > "$copy"
if grep -qF "readonly NEW_DB_HELPER='$HELPER'" "$copy" && grep -qF "readonly DEPLOY_HELPER='$DEPLOY_STUB'" "$copy" &&
  grep -qF "readonly DEPLOY_STATE_DIR='$STATE_TREE'" "$copy"; then _pass; else _fail "the helper and state paths in the test copy were rewritten"; fi
run_copy() { run_cmd env LC_ALL=en_US.UTF-8 SSH_ORIGINAL_COMMAND="$1" bash "$copy"; }
if grep -qF "readonly NEW_DB_HELPER='/opt/platform/data/new-db.sh'" "$script"; then _pass; else _fail "the real helper path is /opt/platform/data/new-db.sh"; fi
if grep -qF "readonly DEPLOY_HELPER='/opt/platform/deploy/deploy.sh'" "$script"; then _pass; else _fail "the real deploy helper path is /opt/platform/deploy/deploy.sh"; fi
if grep -qF "readonly DEPLOY_STATE_DIR='/var/lib/platform/deploy'" "$script"; then _pass; else _fail "the real deploy state path is /var/lib/platform/deploy"; fi

# The stub records its argv, its stdin and every DEPLOY_* variable it can see.
# (The record path is baked in: the dispatcher scrubs the environment, so the stub cannot be told where to write.)
cat > "$DEPLOY_STUB" <<EOF
#!/usr/bin/env bash
{
  printf 'args=%s\n' "\$*"
  cat > "$DEPLOY_REC.stdin"
  printf 'env=%s\n' "\$(env | grep '^DEPLOY_' | sort | tr '\n' ',')"
} > "$DEPLOY_REC"
echo "deploy helper ran"
exit 0
EOF
chmod 755 "$DEPLOY_STUB"

# feed_stdin <env args...>: run with a fixed two-line stdin (a token line, then a yaml line), like a deploy over ssh.
feed_stdin() { printf 'tok-ZQXD1\nname: demo\n\n' | env "$@"; }

# accept_case <label> <payload> <expected helper argv>: the helper runs once with exactly these arguments, no stub is hit.
accept_case() {
  t_reset_calls
  rm -f "$DEPLOY_REC"
  run_cmd feed_stdin LC_ALL=en_US.UTF-8 SSH_ORIGINAL_COMMAND="$2" bash "$copy"
  expect_rc "accept: $1" 0
  expect_out_has "accept runs the helper: $1" "deploy helper ran"
  expect_eq "accept helper argv: $1" "$(grep '^args=' "$DEPLOY_REC")" "args=$3"
  expect_eq "accept no stub call: $1" "$(t_calls)" ""
}

long_tag="$(printf 'a%.0s' $(seq 1 128))"
long_app="a$(printf 'b%.0s' $(seq 1 30))"
accept_case "deploy" "deploy myapp v1.2.3" "deploy myapp v1.2.3"
accept_case "deploy sha tag" "deploy my-app abc123_DEF.4-5" "deploy my-app abc123_DEF.4-5"
accept_case "rollback" "rollback myapp" "rollback myapp"
accept_case "app min length 2" "rollback ab" "rollback ab"
accept_case "tag max length 128" "deploy myapp $long_tag" "deploy myapp $long_tag"

accept_case "app max length 31" "rollback $long_app" "rollback $long_app"
accept_case "longest valid command (app 31, tag 128)" "deploy $long_app $long_tag" "deploy $long_app $long_tag"

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

# new-db hands over to the installed helper (the copy and stub are set up above).
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

# deploy and rollback: stdin reaches the helper unchanged, and no DEPLOY_* variable does, hook by hook. DEPLOY_VALIDATOR
# and DEPLOY_SKIP_REGISTRY would let a caller swap the validator or skip the registry login, so each is asserted alone.
t_reset_calls
rm -f "$DEPLOY_REC"
run_cmd feed_stdin LC_ALL=en_US.UTF-8 SSH_ORIGINAL_COMMAND="deploy myapp v1" bash "$copy"
printf 'tok-ZQXD1\nname: demo\n\n' > "$T_TMP/stdin.expected"
if cmp -s "$T_TMP/stdin.expected" "$DEPLOY_REC.stdin"; then _pass; else _fail "deploy passes stdin through byte for byte (token line, yaml, trailing blank line)"; fi
hooks=(DEPLOY_NETWORK DEPLOY_SECRETS_ROOT DEPLOY_JOB_SECRETS_ROOT DEPLOY_STATE_ROOT DEPLOY_REGISTRY_ROOT DEPLOY_LOCK_DIR
  DEPLOY_CONNECTION_ENV DEPLOY_SKIP_REGISTRY DEPLOY_VALIDATOR DEPLOY_LOCK_WAIT DEPLOY_EXEC_TIMEOUT DEPLOY_PULL_TIMEOUT
  DEPLOY_STOP_TIMEOUT DEPLOY_HEALTH_WAIT DEPLOY_NOPATH_WAIT DEPLOY_POLL_INTERVAL DEPLOY_HELPER DEPLOY_STATE_DIR)
for hook in "${hooks[@]}"; do
  rm -f "$DEPLOY_REC"
  run_cmd feed_stdin "$hook=/caller/chosen-ZQXD2" LC_ALL=en_US.UTF-8 SSH_ORIGINAL_COMMAND="deploy myapp v1" bash "$copy"
  expect_rc "deploy with $hook set runs the helper" 0
  expect_eq "deploy scrubs $hook" "$(grep '^env=' "$DEPLOY_REC")" "env="
  rm -f "$DEPLOY_REC"
  run_cmd feed_stdin "$hook=/caller/chosen-ZQXD2" LC_ALL=en_US.UTF-8 SSH_ORIGINAL_COMMAND="rollback myapp" bash "$copy"
  expect_eq "rollback scrubs $hook" "$(grep '^env=' "$DEPLOY_REC")" "env="
done
rm -f "$DEPLOY_REC"
all_env=()
for hook in "${hooks[@]}"; do all_env+=("$hook=/caller/chosen-ZQXD2"); done
run_cmd feed_stdin "${all_env[@]}" LC_ALL=en_US.UTF-8 SSH_ORIGINAL_COMMAND="deploy myapp v1" bash "$copy"
expect_eq "deploy with every DEPLOY_* hook set: the helper sees none" "$(grep '^env=' "$DEPLOY_REC")" "env="
if grep -q 'ZQXD2' "$DEPLOY_REC"; then _fail "no caller-chosen value reaches the helper"; else _pass; fi

# A missing or non-executable helper exits 1 and names the install command; nothing is run, nothing is hit.
rm -f "$DEPLOY_REC"
chmod 644 "$DEPLOY_STUB"
t_reset_calls
run_cmd feed_stdin LC_ALL=en_US.UTF-8 SSH_ORIGINAL_COMMAND="deploy myapp v1" bash "$copy"
expect_rc "deploy with a non-executable helper exits 1" 1
if grep -q 'deploy helper missing' "$LOGGER_LOG"; then _pass; else _fail "a missing helper is logged"; fi
expect_out_has "deploy with a non-executable helper names the install command" "make host-deploy-user"
mv "$DEPLOY_STUB" "$DEPLOY_STUB.off"
run_cmd feed_stdin LC_ALL=en_US.UTF-8 SSH_ORIGINAL_COMMAND="rollback myapp" bash "$copy"
expect_rc "rollback with the helper absent exits 1" 1
expect_out_has "rollback with the helper absent names the install command" "make host-deploy-user"
expect_eq "a missing helper makes no stub call and runs nothing" "$(t_calls)" ""
if [ -e "$DEPLOY_REC" ]; then _fail "a missing helper is never run"; else _pass; fi
# Invalid input is still a rejection (exit 2) with no helper call, also with the helper absent.
run_copy "deploy My_App v1"
expect_rc "deploy with an invalid app exits 2 before the helper check" 2
run_copy "deploy myapp -bad"
expect_rc "deploy with an invalid tag exits 2 before the helper check" 2
mv "$DEPLOY_STUB.off" "$DEPLOY_STUB"
chmod 755 "$DEPLOY_STUB"
rm -f "$DEPLOY_REC"
run_copy "deploy My_App v1"
expect_rc "deploy with an invalid app exits 2" 2
run_copy "deploy myapp -bad"
expect_rc "deploy with an invalid tag exits 2" 2
run_copy "rollback My_App"
expect_rc "rollback with an invalid app exits 2" 2
if [ -e "$DEPLOY_REC" ]; then _fail "an invalid name or tag never reaches the helper"; else _pass; fi

# rm-db is not a command (app removal is admin-only through a make target).
reject_case "rm-db is unknown" "rm-db myapp"
reject_case "rm-db with no argument is unknown" "rm-db"

# current <app>: the live tag, or nothing. Read-only, fixed path, fail closed.
cur_dir() { printf '%s/%s/current' "$STATE_TREE" "$1"; }
mkdir -p "$(cur_dir myapp)"
printf 'v1.2.3\n' > "$(cur_dir myapp)/tag"
t_reset_calls
run_copy "current myapp"
expect_rc "current prints the live tag" 0
expect_eq "current output is the tag" "$out" "v1.2.3"
expect_eq "current makes no stub call" "$(t_calls)" ""
printf 'abc123' > "$(cur_dir myapp)/tag"
run_copy "current myapp"
expect_rc "current accepts a tag file without a trailing newline" 0
expect_eq "current prints a tag file without a trailing newline" "$out" "abc123"
run_copy "current other-app"
expect_rc "current with no state for the app exits 0" 0
expect_eq "current with no state prints nothing" "$out" ""
mkdir -p "$(cur_dir emptyapp)"
run_copy "current emptyapp"
expect_rc "current with a current/ dir but no tag file exits 0" 0
expect_eq "current with no tag file prints nothing" "$out" ""
before_tree="$(find "$STATE_TREE" -exec /usr/bin/stat -c '%n %a %s %Y' {} + | sort)"
run_copy "current myapp"
expect_eq "current writes nothing" "$(find "$STATE_TREE" -exec /usr/bin/stat -c '%n %a %s %Y' {} + | sort)" "$before_tree"
run_copy "current My_App"
expect_rc "current with an invalid app exits 2" 2
expect_out_has "current invalid app prints usage" "usage: platform"
run_copy "current ../myapp"
expect_rc "current with a path in the app exits 2" 2
run_copy "current myapp extra"
expect_rc "current with an extra argument exits 2" 2
run_copy "current"
expect_rc "current with no argument exits 2" 2
# Unreadable: the tag path is a directory (holds for root too).
mkdir -p "$(cur_dir dirapp)/tag"
run_copy "current dirapp"
expect_rc "current with a directory as the tag file exits 1" 1
expect_out_has "current with a directory says why" "current failed"
# Malformed content fails closed, with no partial output.
bad_tag_case() { # label content
  mkdir -p "$(cur_dir badapp)"
  printf '%b' "$2" > "$(cur_dir badapp)/tag"
  run_copy "current badapp"
  expect_rc "current rejects a malformed tag: $1" 1
  expect_out_lacks "current prints no malformed tag: $1" "ZQXD3"
}
bad_tag_case "leading dot" ".ZQXD3\n"
bad_tag_case "space inside" "ZQXD3 x\n"
bad_tag_case "two lines" "ZQXD3\nv2\n"
bad_tag_case "empty file" ""
bad_tag_case "blank line" "\n"
bad_tag_case "too long (129)" "$(printf 'a%.0s' $(seq 1 129))ZQXD3\n"
bad_tag_case "shell metacharacter" "ZQXD3;id\n"
bad_tag_case "carriage return" "ZQXD3\r\n"
mkdir -p "$(cur_dir symapp)"
ln -sf "$(cur_dir myapp)/tag" "$(cur_dir symapp)/tag"
run_copy "current symapp"
expect_rc "current refuses a symlinked tag file" 1
expect_out_lacks "current prints nothing for a symlinked tag file" "abc123"
mkdir -p "$(cur_dir dangling)"
ln -sf /nonexistent-zqxd4 "$(cur_dir dangling)/tag"
run_copy "current dangling"
expect_rc "current refuses a dangling symlinked tag file" 1
if [ "$(id -u)" -ne 0 ]; then
  mkdir -p "$(cur_dir noperm)"
  printf 'v9\n' > "$(cur_dir noperm)/tag"
  chmod 000 "$(cur_dir noperm)/tag"
  run_copy "current noperm"
  expect_rc "current with an unreadable tag file exits 1" 1
  chmod 644 "$(cur_dir noperm)/tag"
fi
# The real dispatcher reads only the fixed production path: a caller cannot point it elsewhere.
run_cmd env LC_ALL=C DEPLOY_STATE_DIR="$STATE_TREE" SSH_ORIGINAL_COMMAND="current myapp" bash "$script"
if [ -d /var/lib/platform/deploy/myapp ]; then _pass; else expect_eq "DEPLOY_STATE_DIR in the caller's environment is ignored" "$out" ""; fi

# The unset-variable and argv paths.
t_reset_calls
run_cmd feed_stdin -u SSH_ORIGINAL_COMMAND bash "$copy" deploy myapp v1
expect_rc "argv fallback accepts deploy" 0
run_cmd feed_stdin -u SSH_ORIGINAL_COMMAND bash "$copy" rollback myapp
expect_rc "argv fallback accepts rollback" 0
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
