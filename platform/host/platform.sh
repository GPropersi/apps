#!/bin/bash -p
# platform: the forced-command dispatcher, installed on the app host as /usr/local/bin/platform.
#
# The command comes from SSH_ORIGINAL_COMMAND (set by sshd for a forced command), else from "$@".
# It is validated as one unsplit string, split once with read, never eval'd, and dispatched through
# a case allowlist. This script is the only guard for the deploy identity, so it fails closed:
# anything not explicitly accepted is rejected.
#
# Exit codes: 0 accepted and done, 2 rejected, 3 accepted but the subcommand is not implemented yet.
set -euo pipefail

# ASCII-only ranges and a byte-counted length limit, whatever locale the caller has.
export LC_ALL=C

readonly MAX_LEN=256
readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
readonly TAG_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'

usage() {
  cat >&2 <<'EOF'
usage: platform deploy <app> <tag> | rollback <app> | new-db <app> | ls
EOF
}

# reject <reason-code> <input-length>: fixed message, log reason and length only, exit 2.
reject() {
  usage || true
  logger -t platform "rejected reason=$1 len=$2" || true
  exit 2
}

not_implemented() {
  echo "platform: $1 is not implemented yet" >&2
  exit 3
}

if [ "${SSH_ORIGINAL_COMMAND+set}" = "set" ]; then
  cmd="$SSH_ORIGINAL_COMMAND"
else
  cmd="$*"
fi
len=${#cmd}

# Checks on the unsplit string, before any splitting.
[ "$len" -gt 0 ] || reject empty "$len"
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

need_args() {
  [ "$nargs" -eq "$1" ] || reject arg-count "$len"
}
valid_app() {
  [[ "${words[1]}" =~ $APP_RE ]] || reject bad-app "$len"
}
valid_tag() {
  [[ "${words[2]}" =~ $TAG_RE ]] || reject bad-tag "$len"
}

case "$sub" in
  deploy)
    need_args 2
    valid_app
    valid_tag
    not_implemented deploy
    ;;
  rollback)
    need_args 1
    valid_app
    not_implemented rollback
    ;;
  new-db)
    need_args 1
    valid_app
    not_implemented new-db
    ;;
  ls)
    need_args 0
    not_implemented ls
    ;;
  *)
    reject unknown-command "$len"
    ;;
esac
