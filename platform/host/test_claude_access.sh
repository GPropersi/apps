#!/usr/bin/env bash
# Table tests for claude-access.sh (the claude identity's forced command and validating login shell). It mirrors the
# rows of test_login_shell.sh (the input contract) and adds the command allowlist.
# The script has four hard-coded paths (SELF, HELPER, SUDO, LOGGER); each case runs a copy with those lines rewritten to test
# paths: SELF is the copy itself (so the OpenSSH shape `-c <that path>` is the self-invocation sshd performs), HELPER an
# echo helper that prints every argv word, SUDO a fake sudo that logs and runs the rest after -n. Stubs docker/systemctl
# and a shell-ish tool log to the shared call log; on every reject the log (minus logger) must be empty.
# SC2016: payloads are single-quoted on purpose (they must not expand). SC1091: lib.sh is sourced by relative path.
# shellcheck disable=SC1091,SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
source_script="$here/claude-access.sh"

t_init
t_stub docker 0
t_stub systemctl 0
t_stub logger 0
# the real logger is a binary: its stub must not honour BASH_ENV either (the accept path calls it)
sed -i '1s|.*|#!/bin/bash -p|' "$STUB_BIN/logger"

for marker in 'readonly SELF=/usr/local/bin/claude-access' 'readonly HELPER=/usr/local/lib/platform/claude-helper' 'readonly SUDO=/usr/bin/sudo' 'readonly LOGGER=/usr/bin/logger'; do
  if ! grep -qxF -- "$marker" "$source_script"; then
    echo "FAIL: claude-access.sh no longer has the expected line: $marker; update this test"
    exit 1
  fi
done

# The echo helper: one bracketed word per argv word, then the count.
helper="$T_TMP/echo-helper"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "HELPER"; for a in "$@"; do printf "[%%s]" "$a"; done; printf " argc=%%s\\n" "$#"\n'
} > "$helper"
chmod +x "$helper"

# The fake sudo: logs argv, requires -n, then runs the rest.
fakesudo="$T_TMP/fakesudo"
{
  printf '#!/bin/bash -p\n'
  printf 'printf "sudo" >> "$CALL_LOG"; for a in "$@"; do printf " %%s" "$a" >> "$CALL_LOG"; done; printf "\\n" >> "$CALL_LOG"\n'
  printf '[ "$1" = "-n" ] || exit 99\nshift\nexec "$@"\n'
} > "$fakesudo"
chmod +x "$fakesudo"

# make_copy <name> [helper] [sudo]: a copy at $T_TMP/<name> whose SELF is the copy itself; prints its path.
make_copy() {
  local dest="$T_TMP/$1" h="${2:-$helper}" s="${3:-$fakesudo}"
  sed -e "s|^readonly SELF=.*\$|readonly SELF=$dest|" \
      -e "s|^readonly HELPER=.*\$|readonly HELPER=$h|" \
      -e "s|^readonly SUDO=.*\$|readonly SUDO=$s|" \
      -e "s|^readonly LOGGER=.*\$|readonly LOGGER=$STUB_BIN/logger|" "$source_script" > "$dest"
  chmod +x "$dest"
  echo "$dest"
}

wrapper="$(make_copy wrapper)"

# no_tool_ran: the call log holds nothing but logger lines (no sudo, docker or systemctl).
calls_without_logger() { grep -v '^logger ' "$CALL_LOG" || true; }
logger_lines() { grep '^logger ' "$CALL_LOG" || true; }

expect_calls_match() {
  if grep -qE -- "$2" "$CALL_LOG"; then _pass; else _fail "$1" "call log has no line matching: $2"; fi
}

# --- accepted commands: OpenSSH shape, arguments reach the helper as separate argv words ---
ok_case() {
  local want="$1" cmd="$2"
  t_reset_calls
  run_cmd env SSH_ORIGINAL_COMMAND="$cmd" "$wrapper" -c "$wrapper"
  expect_rc "accepted: $cmd" 0
  expect_out_has "accepted argv: $cmd" "$want"
  expect_calls_has "sudo -n with the fixed helper path: $cmd" "sudo -n $helper"
  # exactly one log line: sub and length only, never the app name
  expect_eq "accepted is logged with sub and length only: $cmd" "$(logger_lines)" "logger -t platform-claude accepted sub=${cmd%% *} len=${#cmd}"
}
ok_case "HELPER[ps] argc=1" "ps"
ok_case "HELPER[stats] argc=1" "stats"
ok_case "HELPER[status] argc=1" "status"
ok_case "HELPER[logs][myapp] argc=2" "logs myapp"
ok_case "HELPER[logs][myapp][50] argc=3" "logs myapp 50"
ok_case "HELPER[logs][my-app-2][1000] argc=3" "logs my-app-2 1000"
ok_case "HELPER[restart][myapp] argc=2" "restart myapp"
# name-length boundaries: 2 and 31 characters are accepted (1 and 32 are rejected below)
ok_case "HELPER[restart][ab] argc=2" "restart ab"
app31="a$(printf 'b%.0s' $(seq 1 30))"
ok_case "HELPER[restart][$app31] argc=2" "restart $app31"
ok_case "HELPER[logs][$app31][9] argc=3" "logs $app31 9"

# --- OpenSSH marker with a blank or missing SSH_ORIGINAL_COMMAND: exit 2, nothing runs, no argv fallback ---
blank_case() {
  t_reset_calls
  run_cmd env "$@" "$wrapper" -c "$wrapper"
  expect_rc "marker blank: $1" 2
  expect_out_lacks "marker blank no dispatch: $1" "HELPER"
  expect_eq "marker blank empty call log: $1" "$(calls_without_logger)" ""
}
blank_case "SSH_ORIGINAL_COMMAND="
blank_case "SSH_ORIGINAL_COMMAND= "
blank_case "SSH_ORIGINAL_COMMAND=$(printf ' \t ')"
blank_case $'SSH_ORIGINAL_COMMAND=\n'

t_reset_calls
run_cmd env -u SSH_ORIGINAL_COMMAND "$wrapper" -c "$wrapper"
expect_rc "marker with SSH_ORIGINAL_COMMAND unset" 2
expect_out_lacks "marker unset no dispatch" "HELPER"
expect_eq "marker unset empty call log" "$(calls_without_logger)" ""

# The marker never falls back to argv: extra arguments are rejected outright.
t_reset_calls
run_cmd env SSH_ORIGINAL_COMMAND="ps" "$wrapper" -c "$wrapper" ps
expect_rc "marker plus extra argv" 2
expect_eq "marker plus extra argv empty call log" "$(calls_without_logger)" ""

# --- Spoof row: a client command equal to the marker path is the OpenSSH shape; only the validated env dispatches ---
run_cmd env SSH_ORIGINAL_COMMAND="ps" "$wrapper" -c "$wrapper"
expect_out_has "spoof row dispatches SSH_ORIGINAL_COMMAND only" "HELPER[ps] argc=1"
run_cmd env -u SSH_ORIGINAL_COMMAND "$wrapper" -c "$wrapper"
expect_rc "spoof row without SSH_ORIGINAL_COMMAND is rejected" 2

# --- Tailscale shape: -c <client command>; the dispatched command is the argument, not any inherited env ---
t_reset_calls
run_cmd env -u SSH_ORIGINAL_COMMAND "$wrapper" -c "restart myapp"
expect_rc "tailscale shape, env unset" 0
expect_out_has "tailscale shape dispatches the client command" "HELPER[restart][myapp] argc=2"
run_cmd env SSH_ORIGINAL_COMMAND="restart other" "$wrapper" -c "logs myapp"
expect_out_has "tailscale shape ignores a pre-set env" "HELPER[logs][myapp] argc=2"
expect_out_lacks "tailscale shape does not use the pre-set env" "other"

t_reset_calls
run_cmd env -u SSH_ORIGINAL_COMMAND "$wrapper" -c ""
expect_rc "tailscale shape empty command" 2
run_cmd env -u SSH_ORIGINAL_COMMAND "$wrapper" -c "   "
expect_rc "tailscale shape blank command" 2
expect_eq "tailscale blank empty call log" "$(calls_without_logger)" ""

# --- Argument-shape rejections: no shell, non-zero, empty call log ---
shape_case() {
  t_reset_calls
  run_cmd env SSH_ORIGINAL_COMMAND="ps" "$wrapper" "$@"
  expect_rc "shape reject: $*" 2
  expect_out_lacks "shape reject no dispatch: $*" "HELPER"
  expect_eq "shape reject empty call log: $*" "$(calls_without_logger)" ""
}
shape_case
shape_case -c
shape_case -l
shape_case -i
shape_case -s
shape_case -x ps
shape_case -c ps extra
shape_case ps
shape_case -- -c ps
shape_case -lc ps
shape_case -c ps -c ps

# --- Command rejections through the OpenSSH shape: exit 2, the sudo/docker call log is empty ---
reject_case() {
  local label="$1" cmd="$2"
  t_reset_calls
  run_cmd env SSH_ORIGINAL_COMMAND="$cmd" "$wrapper" -c "$wrapper"
  expect_rc "reject: $label" 2
  expect_out_lacks "reject no dispatch: $label" "HELPER"
  expect_out_has "reject prints usage: $label" "usage:"
  expect_eq "reject empty sudo/docker call log: $label" "$(calls_without_logger)" ""
  expect_calls_has "reject is logged with a reason code: $label" "logger -t platform-claude rejected reason="
  # the log line is reason code and length only: nothing of the input can follow len=<n>
  expect_eq "reject logs exactly one reason/len line: $label" "$(logger_lines | grep -cE '^logger -t platform-claude rejected reason=[a-z-]+ len=[0-9]+$')" "1"
  expect_eq "reject log holds no other logger line: $label" "$(logger_lines | wc -l)" "1"
}
reject_case "unknown command" "frobnicate"
reject_case "shell word" "sh"
reject_case "interactive-looking" "bash -i"
reject_case "id" "id"
reject_case "restart with no app" "restart"
reject_case "restart with two apps" "restart a1 b2"
reject_case "ps with an argument" "ps myapp"
reject_case "stats with an argument" "stats x"
reject_case "status with an argument" "status now"
reject_case "logs with no app" "logs"
reject_case "logs with three args" "logs myapp 5 6"
reject_case "logs lines zero" "logs myapp 0"
reject_case "logs lines negative" "logs myapp -5"
reject_case "logs lines non-integer" "logs myapp abc"
reject_case "logs lines float" "logs myapp 5.5"
reject_case "logs lines leading zero" "logs myapp 05"
reject_case "logs lines over maximum" "logs myapp 1001"
reject_case "logs lines far over maximum" "logs myapp 99999"
reject_case "logs lines huge" "logs myapp 99999999999999999999"
reject_case "uppercase app" "restart MyApp"
reject_case "app starting with a digit" "restart 1app"
reject_case "app too short" "restart a"
reject_case "app too long" "restart a$(printf 'b%.0s' $(seq 1 31))"
reject_case "app with a dot" "restart my.app"
reject_case "app with a slash" "restart ../etc"
reject_case "app with an underscore" "restart my_app"
reject_case "app starting with a dash" "restart --all"
reject_case "docker flag as app" "logs --since"
reject_case "leading space" " ps"
reject_case "trailing space" "ps "
reject_case "double space" "logs  myapp"
reject_case "tab separator" $'logs\tmyapp'
reject_case "newline" $'ps\nid'
reject_case "carriage return" $'ps\rid'
reject_case "semicolon" 'ps;id'
reject_case "semicolon after a word" 'ps ;id'
reject_case "command substitution" 'restart $(id)'
reject_case "backticks" 'restart `id`'
reject_case "pipe" 'ps | id'
reject_case "and" 'ps && id'
reject_case "redirect" 'ps > out'
reject_case "glob" 'restart *'
reject_case "unicode app" "restart caf$(printf '\303\251')"
reject_case "over-length" "logs $(printf 'a%.0s' $(seq 1 300))"
reject_case "case-variant command" "PS"
reject_case "dotdot" "logs ../x"
reject_case "the wrapper path itself as the command" "$wrapper"

# trailing-newline app name: the regex is anchored, so a final newline is not forgiven
reject_case "app with trailing newline" $'restart myapp\n'

# --- The same metacharacter payloads through the Tailscale shape (-c <command>), even under a UTF-8 caller locale ---
meta_case() {
  t_reset_calls
  run_cmd env -u SSH_ORIGINAL_COMMAND LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 "$wrapper" -c "$2"
  expect_rc "tailscale meta reject: $1" 2
  expect_eq "tailscale meta reject empty call log: $1" "$(calls_without_logger)" ""
  expect_out_lacks "tailscale meta reject no echo of payload: $1" "ZQXD"
  expect_calls_lacks "tailscale meta reject: payload marker never reaches the call log: $1" "ZQXD"
  expect_eq "tailscale meta reject logs one reason/len line: $1" "$(logger_lines | grep -cE '^logger -t platform-claude rejected reason=[a-z-]+ len=[0-9]+$')" "1"
}
meta_case "semicolon" 'ps;ZQXD1'
meta_case "command substitution" 'restart myapp $(ZQXD2)'
meta_case "backticks" 'restart myapp `ZQXD3`'
meta_case "pipe" 'ps | ZQXD4'
meta_case "and" 'ps && ZQXD5'
meta_case "redirect" 'ps > ZQXD6'
meta_case "newline" $'ps\nZQXD7'
meta_case "unicode" "restart caf$(printf '\303\251')ZQXD9"
meta_case "shell word" 'sh'
meta_case "interactive-looking" 'bash -i'

# --- Locale and environment ---
# UTF-8 caller locale: a multibyte app name is still rejected (bytes, not characters)
t_reset_calls
run_cmd env LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 SSH_ORIGINAL_COMMAND="restart caf$(printf '\303\251')x" "$wrapper" -c "$wrapper"
expect_rc "UTF-8 caller locale, multibyte app" 2
expect_eq "UTF-8 caller locale empty call log" "$(calls_without_logger)" ""
# the length limit counts bytes: 129 two-byte characters are 258 bytes, over the limit even though under 256 characters
t_reset_calls
run_cmd env LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 SSH_ORIGINAL_COMMAND="logs $(printf '\303\251%.0s' $(seq 1 128))" "$wrapper" -c "$wrapper"
expect_rc "UTF-8 caller locale, over-length in bytes" 2
expect_eq "UTF-8 over-length empty call log" "$(calls_without_logger)" ""

run_cmd env SSH_ORIGINAL_COMMAND="restart myapp" IFS="x" "$wrapper" -c "$wrapper"
expect_out_has "odd IFS does not change the command" "HELPER[restart][myapp] argc=2"

# The shebang is `bash -p`: an inherited BASH_ENV / exported function is ignored.
expect_eq "access shebang is bash -p" "$(head -n1 "$source_script")" "#!/bin/bash -p"
sentinel="$T_TMP/bash-env-sentinel"
bash_env_file="$T_TMP/bash-env.sh"
printf 'touch %q\n' "$sentinel" > "$bash_env_file"
p_helper="$T_TMP/echo-helper-p"
{
  printf '#!/bin/bash -p\n'
  printf 'printf "HELPER[%%s] LC=%%s\\n" "$1" "${LC_ALL-<unset>}"\n'
} > "$p_helper"
chmod +x "$p_helper"
p_wrapper="$(make_copy wrapper-p "$p_helper")"

# positive control: a plain `bash file` run does honour BASH_ENV, so the sentinel mechanism works
rm -f "$sentinel"
run_cmd env SSH_ORIGINAL_COMMAND="ps" BASH_ENV="$bash_env_file" bash "$wrapper" -c "$wrapper"
if [ -e "$sentinel" ]; then _pass; else _fail "control: BASH_ENV is honoured by a plain bash run"; fi

rm -f "$sentinel"
run_cmd env SSH_ORIGINAL_COMMAND="ps" BASH_ENV="$bash_env_file" "$p_wrapper" -c "$p_wrapper"
expect_out_has "BASH_ENV set: the command still dispatches" "HELPER[ps]"
if [ -e "$sentinel" ]; then _fail "BASH_ENV file is not sourced by the wrapper"; else _pass; fi

# (cat is called by name in usage(); logger is an absolute path, so it cannot be shadowed at all)
run_cmd env 'BASH_FUNC_cat%%=() { echo PWNED; }' bash "$wrapper" -c
expect_out_has "control: a plain bash run imports the exported function" "PWNED"
run_cmd env 'BASH_FUNC_logger%%=() { echo PWNED; }' bash "$wrapper" -c
expect_out_lacks "an exported logger function cannot shadow the absolute LOGGER path" "PWNED"
run_cmd env 'BASH_FUNC_cat%%=() { echo PWNED; }' "$p_wrapper" -c
expect_rc "reject path still rejects" 2
expect_out_lacks "exported function is not imported" "PWNED"

# the wrapper pins LC_ALL=C for the helper whatever the caller's locale
run_cmd env LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 SSH_ORIGINAL_COMMAND="ps" "$p_wrapper" -c "$p_wrapper"
expect_out_has "helper sees LC_ALL=C under a UTF-8 caller" "LC=C"

# --- sudo failure propagates (the wrapper execs sudo; the helper's exit code is the caller's) ---
fail_helper="$T_TMP/fail-helper"
printf '#!/usr/bin/env bash\nexit 1\n' > "$fail_helper"
chmod +x "$fail_helper"
fail_wrapper="$(make_copy wrapper-fail "$fail_helper")"
run_cmd env SSH_ORIGINAL_COMMAND="restart myapp" "$fail_wrapper" -c "$fail_wrapper"
expect_rc "the helper's exit code is passed through" 1

# --- The tracked file pins the locale and defines its paths once ---
if grep -qxF 'export LC_ALL=C' "$source_script"; then _pass; else _fail "claude-access exports LC_ALL=C"; fi
expect_eq "SELF defined once" "$(grep -c '^readonly SELF=' "$source_script")" "1"
expect_eq "HELPER defined once" "$(grep -c '^readonly HELPER=' "$source_script")" "1"
expect_eq "no eval in the wrapper" "$(grep -cE '(^|[^a-z_])eval ' "$source_script")" "0"
expect_eq "no stub reached overall (reject paths)" "$(grep -c '^docker\|^systemctl' "$CALL_LOG")" "0"

t_finish
