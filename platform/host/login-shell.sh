#!/bin/bash -p
# platform-login: the validating login shell of the deploy identity, installed root-owned as
# /usr/local/bin/platform-login. It never starts a shell: it accepts only `-c <command>` and hands the command,
# as one unsplit string, to the dispatcher (/usr/local/bin/platform), which is the only guard.
#
# Input contract (sshd runs `<login shell> -c <command>`):
#   -c <exact dispatcher path>  the OpenSSH forced-command shape: the real client command is in
#                               SSH_ORIGINAL_COMMAND, which must be set and not blank (else exit 2, nothing runs,
#                               no fallback to argv).
#   -c <any other string>       the Tailscale SSH shape (no forced command): the string is the client command and is
#                               exported as SSH_ORIGINAL_COMMAND, overwriting any inherited value.
#   anything else               (no -c, -c without an argument, extra arguments, flags) is rejected, exit 2.
# A blank command (empty or whitespace only) is rejected with exit 2 in both shapes.
#
# Fail closed: every path that is not explicitly accepted exits 2 before the dispatcher is reached.
# Exit codes: 2 rejected; otherwise the dispatcher's own exit code (it is exec'd).
set -euo pipefail

# ASCII-only classes and byte semantics, whatever locale the caller has.
export LC_ALL=C

readonly DISPATCHER=/usr/local/bin/platform

reject() {
  echo "platform-login: $1" >&2
  logger -t platform "login-shell rejected reason=$1" || true
  exit 2
}

[ "$#" -eq 2 ] || reject bad-arguments
[ "$1" = "-c" ] || reject bad-arguments

if [ "$2" = "$DISPATCHER" ]; then
  # OpenSSH shape: the command comes only from SSH_ORIGINAL_COMMAND.
  [ "${SSH_ORIGINAL_COMMAND+set}" = "set" ] || reject no-original-command
  cmd="$SSH_ORIGINAL_COMMAND"
else
  # Tailscale SSH shape: the client command is the argument.
  cmd="$2"
fi

# Blank (empty or whitespace only) is never a command.
if [[ "$cmd" =~ ^[[:space:]]*$ ]]; then
  reject blank-command
fi

export SSH_ORIGINAL_COMMAND="$cmd"
exec "$DISPATCHER"
