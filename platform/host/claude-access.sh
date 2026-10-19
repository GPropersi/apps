#!/bin/bash -p
# claude-access: the forced command AND the validating login shell of the `claude` debugging identity, installed
# root-owned as /usr/local/bin/claude-access. It never starts a shell. Its input contract is the one of
# login-shell.sh (the deploy identity's wrapper); the dispatch below replaces that wrapper's exec of the dispatcher.
#
# Input contract (sshd runs `<login shell> -c <command>`; here the forced-command path and the login shell are this
# same file, so the OpenSSH shape is `claude-access -c <this file>`):
#   -c <exact path of this file>  the OpenSSH forced-command shape: the real client command is in
#                                 SSH_ORIGINAL_COMMAND, which must be set and not blank (else exit 2, nothing runs,
#                                 no fallback to argv).
#   -c <any other string>         the Tailscale SSH shape (no forced command): the string is the client command.
#   anything else                 (no -c, -c without an argument, extra arguments, flags) is rejected, exit 2.
# A blank command (empty or whitespace only) is rejected with exit 2 in both shapes.
#
# Accepted commands (validated as one unsplit string, split once with read, never eval'd):
#   ps | stats | status | logs <app> [lines] | restart <app>
# Each is passed, as separate argv words, to the root helper through one fixed sudo call; the helper re-validates
# everything and is the one that checks the platform.app label.
#
# Fail closed: every path that is not explicitly accepted exits 2 before sudo is reached.
# Exit codes: 2 rejected; otherwise the helper's own exit code (it is exec'd).
set -euo pipefail

# ASCII-only classes and byte semantics, whatever locale the caller has.
export LC_ALL=C

readonly SELF=/usr/local/bin/claude-access
readonly HELPER=/usr/local/lib/platform/claude-helper
readonly SUDO=/usr/bin/sudo
readonly LOGGER=/usr/bin/logger
readonly MAX_LEN=256
readonly MAX_LINES=1000
readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
readonly LINES_RE='^[1-9][0-9]{0,3}$'

usage() {
  cat >&2 <<'EOF'
usage: ps | stats | status | logs <app> [lines] | restart <app>
EOF
}

# reject <reason-code> <input-length>: fixed message, log reason and length only, exit 2.
reject() {
  usage || true
  "$LOGGER" -t platform-claude "rejected reason=$1 len=$2" || true
  exit 2
}

[ "$#" -eq 2 ] || reject bad-arguments 0
[ "$1" = "-c" ] || reject bad-arguments 0

if [ "$2" = "$SELF" ]; then
  # OpenSSH shape: the command comes only from SSH_ORIGINAL_COMMAND.
  [ "${SSH_ORIGINAL_COMMAND+set}" = "set" ] || reject no-original-command 0
  cmd="$SSH_ORIGINAL_COMMAND"
else
  # Tailscale SSH shape: the client command is the argument.
  cmd="$2"
fi
len=${#cmd}

# Blank (empty or whitespace only) is never a command.
if [[ "$cmd" =~ ^[[:space:]]*$ ]]; then
  reject blank-command "$len"
fi

# Checks on the unsplit string, before any splitting.
case "$cmd" in *$'\n'* | *$'\r'*) reject newline "$len" ;; esac
[ "$len" -le "$MAX_LEN" ] || reject too-long "$len"

# Split on single spaces only (a tab stays inside a word and fails the regexes below).
IFS=' ' read -r -a words <<<"$cmd"
[ "${#words[@]}" -gt 0 ] || reject empty "$len"

# Canonical form: leading, trailing or repeated spaces are rejected, not normalized.
joined="${words[*]}"
[ "$joined" = "$cmd" ] || reject non-canonical "$len"

sub="${words[0]}"
nargs=$((${#words[@]} - 1))

valid_app() {
  [[ "${words[1]}" =~ $APP_RE ]] || reject bad-app "$len"
}

case "$sub" in
  ps | stats | status)
    [ "$nargs" -eq 0 ] || reject arg-count "$len"
    ;;
  logs)
    { [ "$nargs" -ge 1 ] && [ "$nargs" -le 2 ]; } || reject arg-count "$len"
    valid_app
    if [ "$nargs" -eq 2 ]; then
      [[ "${words[2]}" =~ $LINES_RE ]] || reject bad-lines "$len"
      [ "${words[2]}" -le "$MAX_LINES" ] || reject bad-lines "$len"
    fi
    ;;
  restart)
    [ "$nargs" -eq 1 ] || reject arg-count "$len"
    valid_app
    ;;
  *)
    reject unknown-command "$len"
    ;;
esac

"$LOGGER" -t platform-claude "accepted sub=$sub len=$len" || true
exec "$SUDO" -n "$HELPER" "${words[@]}"
