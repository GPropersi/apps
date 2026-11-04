#!/bin/bash -p
# platform: the forced-command dispatcher, installed on the app host as /usr/local/bin/platform.
#
# The command comes from SSH_ORIGINAL_COMMAND (set by sshd for a forced command), else from "$@".
# It is validated as one unsplit string, split once with read, never eval'd, and dispatched through
# a case allowlist. This script is the only guard for the deploy identity, so it fails closed:
# anything not explicitly accepted is rejected.
#
# Exit codes: 0 accepted and done, 1 accepted but failed (the helper is not installed for deploy, rollback and new-db;
# or `current` found an unreadable or malformed tag file), 2 rejected. deploy, rollback and new-db hand over to their
# helper, whose exit code is the result. `current <app>` is the one read-only arm without a helper.
set -euo pipefail

# ASCII-only ranges and a byte-counted length limit, whatever locale the caller has.
export LC_ALL=C

readonly MAX_LEN=256
readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
readonly TAG_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
# Installed by install-data.sh (a fixed path: the dispatcher takes no override, it is the deploy identity's only guard).
readonly NEW_DB_HELPER='/opt/platform/data/new-db.sh'
# Installed by install-deploy-user.sh (fixed paths, no override, for the same reason).
readonly DEPLOY_HELPER='/opt/platform/deploy/deploy.sh'
readonly DEPLOY_STATE_DIR='/var/lib/platform/deploy'

usage() {
  cat >&2 <<'EOF'
usage: platform deploy <app> <tag> | rollback <app> | current <app> | new-db <app> | ls
EOF
}

# reject <reason-code> <input-length>: fixed message, log reason and length only, exit 2.
reject() {
  usage || true
  logger -t platform "rejected reason=$1 len=$2" || true
  exit 2
}

# run_deploy_helper <args...>: hand over to the deploy helper with a scrubbed environment and the caller's stdin
# (the pull-token line and app.yaml). The helper honours DEPLOY_* test overrides (including DEPLOY_VALIDATOR and
# DEPLOY_SKIP_REGISTRY), which a caller must never be able to set: env -i passes none of them.
run_deploy_helper() {
  if [ ! -f "$DEPLOY_HELPER" ] || [ ! -x "$DEPLOY_HELPER" ]; then
    logger -t platform "deploy helper missing: $DEPLOY_HELPER" || true
    echo "platform: $sub is not installed on this host: run \`make host-deploy-user HOST=<alias> ARGS=\"install --pubkey-file PATH\"\`" >&2
    exit 1
  fi
  exec env -i "PATH=$PATH" "HOME=${HOME:-/}" LC_ALL=C "$DEPLOY_HELPER" "$@"
}

# current_tag <app>: print the live tag, or nothing (rc 0) when the app has no current deploy. Read-only. A tag file
# that exists but cannot be read, is not a regular file, or does not hold exactly one line matching TAG_RE exits 1.
# Only the final `tag` component is checked for a symlink: `current` itself may legitimately be one.
current_tag() {
  local f="$DEPLOY_STATE_DIR/$1/current/tag" lines=()
  if [ ! -e "$f" ] && [ ! -L "$f" ]; then
    return 0
  fi
  if [ -L "$f" ] || [ ! -f "$f" ] || ! mapfile -n 2 -t lines 2>/dev/null <"$f" || [ "${#lines[@]}" -ne 1 ] || ! [[ "${lines[0]}" =~ $TAG_RE ]]; then
    logger -t platform "current failed: unusable tag file for app=$1" || true
    echo "platform: current failed: the recorded tag for $1 is unreadable or malformed" >&2
    exit 1
  fi
  printf '%s\n' "${lines[0]}"
}

# list_apps: one TSV row per labelled app, `app<TAB>state<TAB>health`, sorted by app name (contract: platform/registry/README.md).
# state is `running` only when every container of the app runs, else the most severe non-running state
# (restarting > dead > exited > paused > created; a state outside that list ranks above all and prints verbatim).
# health is the worst across the set (unhealthy > starting > healthy), else none. A docker failure or an unparseable
# row exits 1 with an error line and no rows, so empty output with rc 0 only ever means "no labelled containers".
list_apps() {
  local raw line app state status h r
  local tab=$'\t'
  local -A app_rank=() app_state=() app_hrank=()
  local ps_rc=0
  raw="$(docker ps -a --filter label=platform.app --format "{{.Label \"platform.app\"}}${tab}{{.State}}${tab}{{.Status}}")" || ps_rc=$?
  if [ "$ps_rc" -ne 0 ]; then
    echo "platform: ls failed: docker ps returned an error (rc=$ps_rc)" >&2
    exit 1
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Split on the tab by hand (read would collapse an empty leading field); the column count is checked first.
    if [ "$(awk -F '\t' '{ print NF }' <<<"$line")" -ne 3 ]; then
      echo "platform: ls failed: unparseable docker ps row" >&2
      exit 1
    fi
    app="${line%%"$tab"*}"
    status="${line#*"$tab"}"
    state="${status%%"$tab"*}"
    status="${status#*"$tab"}"
    if ! [[ "$app" =~ $APP_RE ]] || ! [[ "$state" =~ ^[a-z]+$ ]]; then
      echo "platform: ls failed: unparseable docker ps row" >&2
      exit 1
    fi
    case "$state" in
      running) r=0 ;;
      created) r=1 ;;
      paused) r=2 ;;
      exited) r=3 ;;
      dead) r=4 ;;
      restarting) r=5 ;;
      *) r=9 ;;
    esac
    case "$status" in
      *"(unhealthy)"*) h=3 ;;
      *"(health: starting)"*) h=2 ;;
      *"(healthy)"*) h=1 ;;
      *) h=0 ;;
    esac
    # Unknown states tie at rank 9: the lexicographically smaller name wins, so ordering never matters.
    if [ -z "${app_rank[$app]+set}" ] || [ "$r" -gt "${app_rank[$app]}" ] ||
      { [ "$r" -eq 9 ] && [ "${app_rank[$app]}" -eq 9 ] && [[ "$state" < "${app_state[$app]}" ]]; }; then
      app_rank[$app]=$r
      app_state[$app]=$state
    fi
    if [ -z "${app_hrank[$app]+set}" ] || [ "$h" -gt "${app_hrank[$app]}" ]; then
      app_hrank[$app]=$h
    fi
  done <<<"$raw"
  local -a hname=(none healthy starting unhealthy)
  while IFS= read -r app; do
    [ -n "$app" ] || continue
    printf '%s\t%s\t%s\n' "$app" "${app_state[$app]}" "${hname[${app_hrank[$app]}]}"
  done < <(printf '%s\n' "${!app_rank[@]}" | LC_ALL=C sort)
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
    run_deploy_helper deploy "${words[1]}" "${words[2]}"
    ;;
  rollback)
    need_args 1
    valid_app
    run_deploy_helper rollback "${words[1]}"
    ;;
  current)
    need_args 1
    valid_app
    current_tag "${words[1]}"
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
    list_apps
    ;;
  *)
    reject unknown-command "$len"
    ;;
esac
