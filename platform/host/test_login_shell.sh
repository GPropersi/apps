#!/usr/bin/env bash
# Table tests for login-shell.sh (the deploy identity's validating login shell).
# The wrapper has one hard-coded dispatcher path; each case runs a copy with that single line rewritten to a test
# dispatcher (an echo stub, or the real platform.sh). Stubs docker/sudo/systemctl/shell tools log to the shared call
# log, which must stay empty on every path: the wrapper never starts a shell or a tool of its own.
# SC2016: payloads are single-quoted on purpose (they must not expand). SC1091: lib.sh is sourced by relative path.
# shellcheck disable=SC1091,SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
source_wrapper="$here/login-shell.sh"
real_dispatcher="$here/platform.sh"

t_init
t_stub docker 0
t_stub sudo 0
t_stub systemctl 0
t_stub logger 0

marker_line='readonly DISPATCHER=/usr/local/bin/platform'
if ! grep -qxF -- "$marker_line" "$source_wrapper"; then
  echo "FAIL: login-shell.sh no longer has the expected DISPATCHER line; update this test"
  exit 1
fi

# make_wrapper <name> <dispatcher-path>: a copy whose DISPATCHER is the given path; prints the copy's path.
make_wrapper() {
  local dest="$T_TMP/$1"
  sed "s|^$marker_line\$|readonly DISPATCHER=$2|" "$source_wrapper" > "$dest"
  if grep -qxF -- "$marker_line" "$dest"; then echo "rewrite failed" >&2; exit 1; fi
  echo "$dest"
}

# An echo dispatcher: prints the command it was handed and how many argv words it got.
echo_dispatcher="$T_TMP/echo-dispatcher"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "GOT[%%s] argc=%%s\\n" "${SSH_ORIGINAL_COMMAND-<unset>}" "$#"\n'
} > "$echo_dispatcher"
chmod +x "$echo_dispatcher"

echo_wrapper="$(make_wrapper wrapper-echo "$echo_dispatcher")"
real_wrapper="$(make_wrapper wrapper-real "$real_dispatcher")"

# no_shell_started: the call log stays empty (no docker/sudo/systemctl/logger-free tool use beyond logger).
# logger is allowed (rejections are logged); anything else in the log is a failure.
calls_without_logger() { grep -v '^logger ' "$CALL_LOG" || true; }

# --- OpenSSH shape: -c <forced-command path> with SSH_ORIGINAL_COMMAND ---
run_cmd env SSH_ORIGINAL_COMMAND="rollback myapp" bash "$echo_wrapper" -c "$echo_dispatcher"
expect_rc "openssh shape dispatches" 0
expect_out_has "openssh shape passes SSH_ORIGINAL_COMMAND unsplit" "GOT[rollback myapp] argc=0"

# Through the real dispatcher: a valid command reaches the placeholder (exit 3), proving end-to-end dispatch.
run_cmd env SSH_ORIGINAL_COMMAND="ls" bash "$real_wrapper" -c "$real_dispatcher"
expect_rc "openssh shape reaches the real dispatcher" 3
expect_out_has "real dispatcher placeholder ran" "ls is not implemented"

# A non-matching command over the key returns the dispatcher usage error, never a shell.
run_cmd env SSH_ORIGINAL_COMMAND="bash" bash "$real_wrapper" -c "$real_dispatcher"
expect_rc "openssh shape non-matching command" 2
expect_out_has "non-matching command prints dispatcher usage" "usage: platform"

# --- OpenSSH marker with a blank or missing SSH_ORIGINAL_COMMAND: exit 2, nothing runs, no argv fallback ---
blank_case() {
  t_reset_calls
  run_cmd env "$@" bash "$echo_wrapper" -c "$echo_dispatcher"
  expect_rc "marker blank: $1" 2
  expect_out_lacks "marker blank no dispatch: $1" "GOT["
  expect_eq "marker blank empty call log: $1" "$(calls_without_logger)" ""
}
blank_case "SSH_ORIGINAL_COMMAND="
blank_case "SSH_ORIGINAL_COMMAND= "
blank_case "SSH_ORIGINAL_COMMAND=$(printf ' \t ')"
blank_case $'SSH_ORIGINAL_COMMAND=\n'

t_reset_calls
run_cmd env -u SSH_ORIGINAL_COMMAND bash "$echo_wrapper" -c "$echo_dispatcher"
expect_rc "marker with SSH_ORIGINAL_COMMAND unset" 2
expect_out_lacks "marker unset no dispatch" "GOT["
expect_eq "marker unset empty call log" "$(calls_without_logger)" ""

# The marker never falls back to argv: extra arguments are rejected outright.
run_cmd env SSH_ORIGINAL_COMMAND="ls" bash "$echo_wrapper" -c "$echo_dispatcher" ls
expect_rc "marker plus extra argv" 2
expect_out_lacks "marker plus extra argv no dispatch" "GOT["

# --- Spoof row: a client command equal to the marker path is the OpenSSH shape; only the validated env dispatches ---
run_cmd env SSH_ORIGINAL_COMMAND="ls" bash "$echo_wrapper" -c "$echo_dispatcher"
expect_out_has "spoof row dispatches SSH_ORIGINAL_COMMAND only" "GOT[ls] argc=0"
run_cmd env -u SSH_ORIGINAL_COMMAND bash "$echo_wrapper" -c "$echo_dispatcher"
expect_rc "spoof row without SSH_ORIGINAL_COMMAND is rejected" 2

# --- Tailscale shape: -c <client command>; the string is exported over any inherited value ---
run_cmd env -u SSH_ORIGINAL_COMMAND bash "$echo_wrapper" -c "rollback myapp"
expect_rc "tailscale shape, env unset" 0
expect_out_has "tailscale shape dispatches the client command" "GOT[rollback myapp] argc=0"
run_cmd env SSH_ORIGINAL_COMMAND="deploy other v9" bash "$echo_wrapper" -c "rollback myapp"
expect_out_has "tailscale shape overwrites a pre-set env" "GOT[rollback myapp] argc=0"
expect_out_lacks "tailscale shape ignores the pre-set env" "other"

# Blank client commands are rejected in the tailscale shape too.
run_cmd env -u SSH_ORIGINAL_COMMAND bash "$echo_wrapper" -c ""
expect_rc "tailscale shape empty command" 2
run_cmd env -u SSH_ORIGINAL_COMMAND bash "$echo_wrapper" -c "   "
expect_rc "tailscale shape blank command" 2
expect_out_lacks "tailscale blank no dispatch" "GOT["

# --- Argument-shape rejections: no shell, non-zero, empty call log ---
shape_case() {
  t_reset_calls
  run_cmd env SSH_ORIGINAL_COMMAND="ls" bash "$echo_wrapper" "$@"
  expect_rc "shape reject: $*" 2
  expect_out_lacks "shape reject no dispatch: $*" "GOT["
  expect_eq "shape reject empty call log: $*" "$(calls_without_logger)" ""
}
shape_case
shape_case -c
shape_case -l
shape_case -i
shape_case -s
shape_case -x ls
shape_case -c ls extra
shape_case ls
shape_case -- -c ls
shape_case -lc ls
shape_case -c ls -c ls

# --- Metacharacter payloads via -c are rejected by the real dispatcher, even under a UTF-8 caller locale ---
meta_case() {
  t_reset_calls
  run_cmd env -u SSH_ORIGINAL_COMMAND LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 bash "$real_wrapper" -c "$2"
  expect_rc "meta reject: $1" 2
  expect_eq "meta reject empty call log: $1" "$(calls_without_logger)" ""
  expect_out_lacks "meta reject no echo of payload: $1" "ZQXD"
}
meta_case "semicolon" 'ls;ZQXD1'
meta_case "command substitution" 'rollback myapp $(ZQXD2)'
meta_case "backticks" 'rollback myapp `ZQXD3`'
meta_case "pipe" 'ls | ZQXD4'
meta_case "and" 'ls && ZQXD5'
meta_case "redirect" 'ls > ZQXD6'
meta_case "newline" $'ls\nZQXD7'
meta_case "carriage return" $'ls\rZQXD8'
meta_case "unicode" "rollback caf$(printf '\303\251')ZQXD9"
meta_case "shell word" 'sh'
meta_case "interactive-looking" 'bash -i'
meta_case "dotdot" 'deploy ../ZQXE1 v1'

# --- The wrapper is not sensitive to a hostile inherited environment ---
run_cmd env SSH_ORIGINAL_COMMAND="rollback myapp" IFS="x" bash "$echo_wrapper" -c "$echo_dispatcher"
expect_out_has "odd IFS does not change the command" "GOT[rollback myapp] argc=0"

# The shebang is `bash -p`, so an inherited BASH_ENV / exported function is ignored by the wrapper and the dispatcher.
# The scripts are executed directly (not via `bash file`) so the shebang applies; the stub dispatchers use it too.
expect_eq "wrapper shebang is bash -p" "$(head -n1 "$source_wrapper")" "#!/bin/bash -p"
expect_eq "dispatcher shebang is bash -p" "$(head -n1 "$real_dispatcher")" "#!/bin/bash -p"
p_dispatcher="$T_TMP/echo-dispatcher-p"
{
  printf '#!/bin/bash -p\n'
  printf 'printf "GOT[%%s] argc=%%s LC=%%s\\n" "${SSH_ORIGINAL_COMMAND-<unset>}" "$#" "${LC_ALL-<unset>}"\n'
} > "$p_dispatcher"
chmod +x "$p_dispatcher"
p_wrapper="$(make_wrapper wrapper-p "$p_dispatcher")"
chmod +x "$p_wrapper"
sentinel="$T_TMP/bash-env-sentinel"
bash_env_file="$T_TMP/bash-env.sh"
printf 'touch %q\n' "$sentinel" > "$bash_env_file"

# positive control: a plain `bash file` run does honour BASH_ENV, so the sentinel mechanism works
rm -f "$sentinel"
run_cmd env SSH_ORIGINAL_COMMAND="rollback myapp" BASH_ENV="$bash_env_file" bash "$echo_wrapper" -c "$echo_dispatcher"
if [ -e "$sentinel" ]; then _pass; else _fail "control: BASH_ENV is honoured by a plain bash run"; fi

rm -f "$sentinel"
run_cmd env SSH_ORIGINAL_COMMAND="rollback myapp" BASH_ENV="$bash_env_file" "$p_wrapper" -c "$p_dispatcher"
expect_out_has "BASH_ENV set: the command still dispatches" "GOT[rollback myapp] argc=0"
if [ -e "$sentinel" ]; then _fail "BASH_ENV file is not sourced by the wrapper or the dispatcher"; else _pass; fi

# an exported function shadowing a tool the wrapper calls (logger on a reject path) is not imported
run_cmd env 'BASH_FUNC_logger%%=() { echo PWNED; }' bash "$echo_wrapper" -c
expect_out_has "control: a plain bash run imports the exported function" "PWNED"
run_cmd env 'BASH_FUNC_logger%%=() { echo PWNED; }' "$p_wrapper" -c
expect_rc "reject path still rejects" 2
expect_out_lacks "exported function is not imported" "PWNED"

# the wrapper pins LC_ALL=C for the dispatcher whatever the caller's locale (behavioural, not a source grep)
run_cmd env LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 SSH_ORIGINAL_COMMAND="rollback myapp" "$p_wrapper" -c "$p_dispatcher"
expect_out_has "dispatcher sees LC_ALL=C under a UTF-8 caller" "LC=C"

# The tracked wrapper exports LC_ALL=C and names the dispatcher exactly once.
if grep -qxF 'export LC_ALL=C' "$source_wrapper"; then _pass; else _fail "wrapper exports LC_ALL=C"; fi
expect_eq "DISPATCHER defined once" "$(grep -c '^readonly DISPATCHER=' "$source_wrapper")" "1"
expect_eq "no stub reached overall" "$(calls_without_logger)" ""

t_finish
