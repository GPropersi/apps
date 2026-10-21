#!/bin/bash -p
# platform: the forced-command dispatcher, installed on the app host as /usr/local/bin/platform.
#
# The command comes from SSH_ORIGINAL_COMMAND (set by sshd for a forced command), else from "$@".
# It is validated as one unsplit string, split once with read, never eval'd, and dispatched through
# a case allowlist. This script is the only guard for the deploy identity, so it fails closed:
# anything not explicitly accepted is rejected.
#
# Exit codes: 0 accepted and done, 1 accepted but the helper is not installed (new-db), 2 rejected, 3 accepted but the
# subcommand is not implemented yet. new-db hands over to its helper, whose exit code is the result.
set -euo pipefail

# ASCII-only ranges and a byte-counted length limit, whatever locale the caller has.
export LC_ALL=C

readonly MAX_LEN=256
readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
readonly TAG_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
# Installed by install-data.sh (a fixed path: the dispatcher takes no override, it is the deploy identity's only guard).
readonly NEW_DB_HELPER='/opt/platform/data/new-db.sh'

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
    if [ ! -f "$NEW_DB_HELPER" ] || [ ! -x "$NEW_DB_HELPER" ]; then
      logger -t platform "new-db helper missing: $NEW_DB_HELPER" || true
      echo "platform: new-db is not installed on this host: run \`make host-data HOST=<alias> ARGS=install\`" >&2
      exit 1
    fi
    # Scrubbed environment: the helper honours NEW_DB_* test overrides, which a caller must never be able to set.
    exec env -i "PATH=$PATH" "HOME=${HOME:-/}" LC_ALL=C "$NEW_DB_HELPER" "${words[1]}"
    ;;
  ls)
    need_args 0
    not_implemented ls
    ;;
  *)
    reject unknown-command "$len"
    ;;
esac
