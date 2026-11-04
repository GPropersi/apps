#!/usr/bin/env bash
# install-deploy-user.sh: create the restricted `deploy` SSH identity on the app host (run yourself, not Claude).
#
# `deploy` can only run the validating `platform` dispatcher. Two layers hold it, so it stays safe under both
# OpenSSH and Tailscale SSH:
#   1. its authorized_keys line is `restrict,command="/usr/local/bin/platform" <key>` (an optional from="<pattern>"
#      comes first), read from a root-owned file in a root-owned directory via a `Match User deploy` sshd drop-in;
#   2. its login shell is the root-owned validating wrapper /usr/local/bin/platform-login (login-shell.sh), which
#      accepts only `-c <command>` and hands one unsplit string to the dispatcher. No interactive shell, no fallback.
# The user is in the docker group (root-equivalent, accepted), not in sudo, with a locked password.
# It also installs the deploy helper behind `platform deploy` and `platform rollback`, all root:root and read-only to
# deploy: /opt/platform/deploy/deploy.sh (0755), registry/validate-app-yaml.sh (0755), registry/reserved-names.txt (0644),
# lib/yaml-subset.sh (0755); and creates /var/lib/platform/deploy (deploy:deploy 0755), the helper's state directory.
#
# The dispatcher and the wrapper are embedded below (BEGIN-PAYLOAD/END-PAYLOAD) because the Pi has no checkout:
# `make embed` regenerates them from the tracked sources, and `make lint` fails if they differ.
#
# Usage: install-deploy-user.sh [install|status|verify] [--host ALIAS] [--pubkey-file PATH] [--from PATTERN]
#                               [--admin-user NAME]
#   install   needs --pubkey-file (the public key to authorize; never committed). Idempotent: a second run reports
#             "already" for every item and makes no mutating call. An sshd -t failure restores the previous drop-in
#             (or removes a new one), never reloads, and exits 1: keep a second SSH session open while installing.
#   status    report every check (PASS/FAIL), exit 0
#   verify    the same checks, exit 1 on any FAIL
#   --host    stream this script over one `ssh <alias> bash -s` call (BatchMode, no tty). The local --pubkey-file is
#             read and validated here and its content is forwarded as a quoted argument (--key); the remote
#             re-validates it. The remote account needs passwordless sudo (NOPASSWD): a `sudo -v` in another terminal
#             does not carry over, because sudo timestamps are tty-scoped. Without NOPASSWD, copy the script to the
#             host and run it there directly instead of using --host.
#   --from    optional from="..." pattern/CIDR list for the key (pattern characters only)
#   --admin-user  the administrator account whose effective sshd config must stay unchanged (default: the caller);
#             must match ^[a-z_][a-z0-9_-]{0,31}$
#
# Exit: 0 ok | 1 failed check, sshd -t failure or missing prerequisite | 2 usage error or invalid key/from input
#       (nothing is written). ssh failures pass through ssh's own status (255).
#
# Test overrides (env, test-only): INSTALL_DEPLOY_ROOT (path prefix for every file this script writes),
# INSTALL_DEPLOY_SUDO (the privilege prefix; "sudo -n" by default, none when already root).
set -euo pipefail

export LC_ALL=C
# sshd, useradd and friends live in /usr/sbin, which a non-root ssh user's PATH lacks
export PATH="$PATH:/usr/sbin:/sbin"

readonly DEPLOY_USER="deploy"
readonly DISPATCHER_PATH="/usr/local/bin/platform"
readonly WRAPPER_PATH="/usr/local/bin/platform-login"
readonly KEYS_DIR="/etc/ssh/authorized_keys.d"
readonly KEY_FILE="/etc/ssh/authorized_keys.d/deploy"
readonly DROPIN="/etc/ssh/sshd_config.d/20-deploy.conf"
# The deploy helper and its validator: root-owned and read-only to `deploy`, which only runs them. The layout keeps the
# validator's relative lookups (reserved-names.txt beside it, ../lib/yaml-subset.sh).
readonly HELPER_DIR="/opt/platform/deploy"
readonly HELPER_REGISTRY_DIR="/opt/platform/deploy/registry"
readonly HELPER_LIB_DIR="/opt/platform/deploy/lib"
# Per-app deploy state written by the helper running as `deploy`.
readonly STATE_DIR="/var/lib/platform/deploy"
ROOT="${INSTALL_DEPLOY_ROOT:-}"

# <keytype> <base64> [comment]: no option prefix, no quote, no backslash, no control character.
readonly KEY_RE='(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [A-Za-z0-9@._:+=,/()# -]*)?'
readonly FROM_RE='[A-Za-z0-9.*?:/!,_-]+'

if [ -n "${INSTALL_DEPLOY_SUDO+set}" ]; then
  read -r -a SUDO <<<"$INSTALL_DEPLOY_SUDO"
elif [ "$EUID" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo -n)
fi

FAILURES=0
TMP=""

info() { printf '%s\n' "$1"; }
err() { printf '%s\n' "$1" >&2; }
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
die() { err "install-deploy-user: $1"; exit "${2:-1}"; }

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

# priv <cmd...>: run with privilege; stdin is never forwarded (this script may itself be read from stdin).
priv() { "${SUDO[@]}" "$@" </dev/null; }

# require_privilege: fail early and clearly, before anything is written, when privileged calls cannot work.
require_privilege() {
  priv true || die "no usable privilege (sudo -n failed). Over --host the account needs passwordless sudo; otherwise copy this script to the host and run it there directly"
}

# ---- embedded payloads (regenerated by `make embed`; do not edit between the markers) ----

# BEGIN-PAYLOAD platform/host/platform.sh
payload_platform_sh() {
  cat <<'PLATFORM_PAYLOAD_EOF'
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
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/host/platform.sh

# BEGIN-PAYLOAD platform/host/login-shell.sh
payload_login_shell_sh() {
  cat <<'PLATFORM_PAYLOAD_EOF'
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
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/host/login-shell.sh

# BEGIN-PAYLOAD platform/deploy/deploy.sh
payload_deploy_sh() {
  cat <<'PLATFORM_PAYLOAD_EOF'
#!/bin/bash -p
# deploy.sh: turn (app, tag) into a running, health-checked container, with no caller-controlled flags. To be installed
# by install-deploy-user.sh to /opt/platform/deploy/deploy.sh (root:root 0755) and run by the `platform deploy <app> <tag>`
# dispatcher as the deploy user (Docker access, no sudo).
#
# Usage: deploy.sh deploy <app> <tag>      (stdin: line 1 = registry pull token, the rest = the app's app.yaml)
#        deploy.sh rollback <app>          (no stdin, no registry call: reruns the recorded previous/ deploy from the local image)
# Exit: 0 done | 1 refused or failed (the phase is named) | 2 usage error
#
# Rollback takes the shared app lock first, then reads <state root>/<app>/previous/{tag,digest,app.yaml} (none: exit 1,
# "no previous deploy") and runs validate, preflight, inspect, swap, health and commit against the local image by its recorded
# digest. An image missing from the local daemon fails the inspect phase. Its commit exchanges current/ and previous/, so a
# second rollback returns forward. After a successful deploy or rollback this app's images other than the current and
# previous ones are removed (a failure is only a warning); after a failed deploy the newly pulled image goes too unless it
# is the current or previous one. Image identity is compared by image ID, never by tag.
#
# Everything about how the app runs is fixed here; the caller supplies only the validated name, the tag and app.yaml.
# Phases, none touching the running app until `swap`:
#   input      stdin framing: token line (at most 1 KiB, held in a shell variable, never a file, never exported), then
#              app.yaml (at most 16 KiB) into a private temp dir that is removed on every exit path
#   validate   the installed validate-app-yaml.sh on <tmp>/<app>/app.yaml
#   preflight  the shared per-app lock (flock, bounded wait), secrets dirs, network, curl, state root, registry root,
#              connection.env
#   pull       docker login (token on stdin, private DOCKER_CONFIG) and docker pull; resolves the immutable reference
#              (repo digest, or the image ID under DEPLOY_SKIP_REGISTRY) used by every later phase instead of the tag
#   inspect    architecture, numeric non-zero USER, no traefik.* / platform.* label, exactly one exposed <port>/tcp
#   swap       recover a leftover app-<app>-old, stop and rename the running container, run the new one
#   health     curl on the health path (2xx within the wait) or, with no health_path, the container staying up
#   commit     registry/<app>/app.yaml and deploy state (temp + rename), then the old container is removed
# A swap or health failure removes the new container and restores the old one. A commit failure leaves the new container
# running and the old one in place; the next deploy reconciles registry and state.
#
# Deploy state: <state root>/<app>/{current,previous}/{tag,digest,deployed-at,app.yaml}.
#
# Logging: a timestamped line per phase start and end (rc and duration) on stderr and through `logger -t platform`; error
# text from external commands is logged with the pull token masked. Every external call runs under `timeout`.
#
# Needs bash >= 5.1 (a here-string then travels through a pipe, not a temp file holding the token).
#
# Env overrides (tests only; the dispatcher runs this script with a scrubbed environment, so none is reachable through the
# restricted login; each defaults to the fixed production value): DEPLOY_NETWORK (platform), DEPLOY_SECRETS_ROOT
# (/var/lib/platform/secrets), DEPLOY_JOB_SECRETS_ROOT (/var/lib/platform/job-secrets), DEPLOY_STATE_ROOT
# (/var/lib/platform/deploy), DEPLOY_REGISTRY_ROOT (/var/lib/platform/registry), DEPLOY_LOCK_DIR
# (/var/lib/platform/locks), DEPLOY_CONNECTION_ENV (/opt/platform/data/connection.env), DEPLOY_SKIP_REGISTRY (1 skips
# login and pull and uses the image already in the local daemon), DEPLOY_VALIDATOR
# (/opt/platform/deploy/registry/validate-app-yaml.sh; its yaml reader is ../lib/yaml-subset.sh beside it),
# DEPLOY_LOCK_WAIT (30), DEPLOY_EXEC_TIMEOUT (30, per docker call), DEPLOY_PULL_TIMEOUT (300, login and pull each),
# DEPLOY_STOP_TIMEOUT (30), DEPLOY_STALE_TMP_MIN (60), DEPLOY_HEALTH_WAIT (60), DEPLOY_NOPATH_WAIT (10), DEPLOY_POLL_INTERVAL (1).
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
  echo "deploy: needs bash >= 5.1" >&2
  exit 1
fi

export LC_ALL=C

readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
readonly TAG_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
readonly NET_RE='^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$'
readonly NUM_RE='^[0-9]+$'
readonly HOST_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
readonly TOKEN_MAX=1024
readonly YAML_MAX=16384
readonly REGISTRY_HOST="ghcr.io"
readonly REGISTRY_USER="github-actions"
readonly IMAGE_NS="ghcr.io/gpropersi/apps"

NETWORK="${DEPLOY_NETWORK:-platform}"
SECRETS_ROOT="${DEPLOY_SECRETS_ROOT:-/var/lib/platform/secrets}"
JOB_SECRETS_ROOT="${DEPLOY_JOB_SECRETS_ROOT:-/var/lib/platform/job-secrets}"
STATE_ROOT="${DEPLOY_STATE_ROOT:-/var/lib/platform/deploy}"
REGISTRY_ROOT="${DEPLOY_REGISTRY_ROOT:-/var/lib/platform/registry}"
LOCK_DIR="${DEPLOY_LOCK_DIR:-/var/lib/platform/locks}"
CONNECTION_ENV="${DEPLOY_CONNECTION_ENV:-/opt/platform/data/connection.env}"
SKIP_REGISTRY="${DEPLOY_SKIP_REGISTRY:-0}"
VALIDATOR="${DEPLOY_VALIDATOR:-/opt/platform/deploy/registry/validate-app-yaml.sh}"
LOCK_WAIT="${DEPLOY_LOCK_WAIT:-30}"
EXEC_TIMEOUT="${DEPLOY_EXEC_TIMEOUT:-30}"
PULL_TIMEOUT="${DEPLOY_PULL_TIMEOUT:-300}"
STOP_TIMEOUT="${DEPLOY_STOP_TIMEOUT:-30}"
STALE_TMP_MIN="${DEPLOY_STALE_TMP_MIN:-60}"
HEALTH_WAIT="${DEPLOY_HEALTH_WAIT:-60}"
NOPATH_WAIT="${DEPLOY_NOPATH_WAIT:-10}"
POLL="${DEPLOY_POLL_INTERVAL:-1}"

APP=""
TAG=""
TOKEN=""
TMPD=""
ERRF=""
LOCKFD=""
YAML=""
FLAT=""
MEMCAP=""
PORT=""
HEALTH_PATH=""
PG_HOST=""
PG_PORT=""
RD_HOST=""
RD_PORT=""
IMAGE_REPO=""
REF=""
C_NEW=""
C_OLD=""
PHASE_OUT=""
PHASE_RC=0
CUR_PHASE="start"
CUR_START=0
ORIG_PRESENT=0
RENAMED=0
NEW_RUN=0
SWAP_OPEN=0
MODE="deploy"
PULLED=0

err() { printf '%s\n' "$1" >&2 || true; }

# mask <text>: the text with the pull token (when known) replaced.
mask() {
  local s="$1"
  [ -z "$TOKEN" ] || s="${s//"$TOKEN"/***}"
  printf '%s' "$s"
}

log() {
  local msg
  msg="$(mask "$*")"
  printf '%s deploy app=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${APP:-?}" "$msg" >&2 || true
  logger -t platform -- "deploy app=${APP:-?} $msg" 2>/dev/null || true
}

# fail <phase> <message>: a refusal or failure naming the phase; exit 1.
fail() {
  log "phase=$1 end rc=1 FAILED $2"
  err "deploy: phase '$1' failed: $(mask "$2")"
  exit 1
}

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
cleanup() {
  local rc=$?
  # An interrupted swap or health phase puts the old container back before the temp dir (ERRF) goes.
  if [ "$SWAP_OPEN" -eq 1 ] && [ -n "$TMPD" ]; then
    restore_old
  fi
  # A failed deploy drops the image it pulled unless it is the current or previous one. A commit failure leaves the new
  # container running, so its image is left alone.
  if [ "$rc" -ne 0 ] && [ "$PULLED" -eq 1 ] && [ "$CUR_PHASE" != commit ] && [ -n "$TMPD" ]; then
    PULLED=0
    prune_images new
  fi
  [ -z "$TMPD" ] || rm -rf -- "$TMPD"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT
# A dropped ssh session must not kill a deploy mid-swap (bash dies on SIGPIPE without running the EXIT trap): ignore it, and
# let log/err tolerate the failed write.
trap '' PIPE

step_begin() {
  CUR_PHASE="$1"
  CUR_START=$SECONDS
  log "phase=$1 start"
}
step_end() { log "phase=$CUR_PHASE end rc=0 dur=$((SECONDS - CUR_START))s"; }

# try_phase <timeout> <name> <stdin text> <cmd...>: runs the command under timeout with the text on stdin; sets PHASE_OUT
# (stdout) and PHASE_RC. Never exits; a failure is logged with the masked error text.
try_phase() {
  local tmo="$1" name="$2" input="$3" start errtext lab
  shift 3
  case "${2:-}" in
    image | container | network) lab="${1##*/} $2 ${3:-}" ;;
    *) lab="${1##*/} ${2:-}" ;;
  esac
  lab="${lab%% -*}"
  PHASE_RC=0
  log "phase=$name cmd=$lab start"
  start=$SECONDS
  : >"$ERRF"
  PHASE_OUT="$(timeout "$tmo" "$@" 2>"$ERRF" <<<"$input")" || PHASE_RC=$?
  if [ "$PHASE_RC" -ne 0 ]; then
    errtext="$(mask "$(head -c 1000000 "$ERRF" | tr '\n' ' ') $(printf '%s' "$PHASE_OUT" | head -c 100000 | tr '\n' ' ')")"
    errtext="${errtext:0:2000}"
    if [ "$PHASE_RC" -eq 124 ]; then
      log "phase=$name cmd=$lab end rc=124 dur=$((SECONDS - start))s FAILED timed out after ${tmo}s"
    else
      log "phase=$name cmd=$lab end rc=$PHASE_RC dur=$((SECONDS - start))s FAILED err=${errtext:-none}"
    fi
    return 0
  fi
  log "phase=$name cmd=$lab end rc=0 dur=$((SECONDS - start))s"
}

# phase_t <timeout> <name> <stdin text> <cmd...>: try_phase that exits 1 naming the phase on a failure.
phase_t() {
  local name="$2"
  try_phase "$@"
  if [ "$PHASE_RC" -ne 0 ]; then
    if [ "$PHASE_RC" -eq 124 ]; then
      err "deploy: phase '$name' failed: timed out after ${1}s"
    else
      err "deploy: phase '$name' failed (rc $PHASE_RC); see the log lines above"
    fi
    exit 1
  fi
}

phase() { # <name> <stdin text> <cmd...>
  local name="$1" input="$2"
  shift 2
  phase_t "$EXEC_TIMEOUT" "$name" "$input" "$@"
}

# quiet <cmd...>: rc of the command under the docker timeout, no output and no log line (an existence probe).
quiet() { timeout "$EXEC_TIMEOUT" "$@" >/dev/null 2>&1 </dev/null; }

# ctr_exists <name>: 0 when the container exists, 1 only when the daemon says "No such"; any other probe failure (daemon
# error, timeout) fails the deploy before it touches anything, so a failed probe is never read as "absent".
ctr_exists() {
  local rc=0 errtext
  errtext="$(timeout "$EXEC_TIMEOUT" docker container inspect "$1" 2>&1 >/dev/null </dev/null)" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  case "$errtext" in
    *[Nn]o\ such*) return 1 ;;
  esac
  log "phase=swap probe of $1 failed rc=$rc err=$(printf '%s' "$errtext" | head -c 500 | tr '\n' ' ')"
  fail swap "cannot tell whether container $1 exists (probe rc $rc); nothing was changed"
}

# ---- 1. input ----

# init_tmp: the private temp dir (removed on every exit path), the error file and a private DOCKER_CONFIG.
init_tmp() {
  # A run killed by SIGKILL (OOM, power loss) never ran its EXIT trap and leaves its dir, and the pull token with it while
  # login+pull ran: remove this user's own dirs from dead runs (a live run is minutes old, the limit is an hour).
  find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'platform-deploy.*' -user "$(id -u)" -mmin +"$STALE_TMP_MIN" \
    -exec rm -rf -- {} + 2>/dev/null || true
  TMPD="$(mktemp -d -t platform-deploy.XXXXXX)"
  ERRF="$TMPD/err"
  : >"$ERRF"
  mkdir -m 0700 -- "$TMPD/$APP" "$TMPD/dockercfg"
  YAML="$TMPD/$APP/app.yaml"
  export DOCKER_CONFIG="$TMPD/dockercfg"
}

read_input() {
  local line_rc=0 size
  step_begin input
  init_tmp
  # Line 1 is the token. read -n stops at the newline or after one more byte than allowed.
  IFS= read -r -n $((TOKEN_MAX + 1)) TOKEN || line_rc=$?
  if [ "$line_rc" -ne 0 ]; then
    TOKEN=""
    fail input "stdin has no token line (a token line ending in a newline, then app.yaml, is required)"
  fi
  if [ "${#TOKEN}" -gt "$TOKEN_MAX" ]; then
    TOKEN=""
    fail input "the token line is over $TOKEN_MAX bytes"
  fi
  [ -n "$TOKEN" ] || fail input "the token line is empty"
  head -c $((YAML_MAX + 1)) >"$YAML" || fail input "cannot read app.yaml from stdin"
  size="$(stat -c %s -- "$YAML")"
  [ "$size" -gt 0 ] || fail input "app.yaml is empty or missing"
  [ "$size" -le "$YAML_MAX" ] || fail input "app.yaml is over $YAML_MAX bytes"
  step_end
}

# ---- 2. validate ----

validate() {
  local lib out
  step_begin validate
  [ -f "$VALIDATOR" ] && [ -r "$VALIDATOR" ] || fail validate "the validator $VALIDATOR is missing: run \`make host-deploy-user HOST=<alias> ARGS=install\`"
  lib="$(dirname "$VALIDATOR")/../lib/yaml-subset.sh"
  [ -r "$lib" ] || fail validate "the yaml reader $lib is missing: run \`make host-deploy-user HOST=<alias> ARGS=install\`"
  try_phase "$EXEC_TIMEOUT" validate "" "$VALIDATOR" "$YAML"
  if [ "$PHASE_RC" -ne 0 ]; then
    out="$(printf '%s' "$PHASE_OUT" | head -c 2000 | tr '\n' ' ')"
    fail validate "app.yaml refused: ${out:-validator rc $PHASE_RC}"
  fi
  FLAT="$TMPD/flat.tsv"
  # shellcheck disable=SC1090
  . "$lib"
  ys_flatten <"$YAML" >"$FLAT" 2>"$ERRF" || fail validate "app.yaml is outside the supported YAML subset"
  MEMCAP="$(ys_get "$FLAT" memory_cap)"
  PORT="$(ys_get "$FLAT" port)"
  HEALTH_PATH="$(ys_get "$FLAT" health_path)"
  [[ "$MEMCAP" =~ ^[1-9][0-9]{0,2}m$ ]] || fail validate "memory_cap '$MEMCAP' is not usable"
  [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || fail validate "port '$PORT' is not usable"
  [ "$(ys_get "$FLAT" name)" = "$APP" ] || fail validate "app.yaml name does not match the app '$APP'"
  step_end
}

# ---- 3. preflight ----

take_lock() {
  local lock old
  [ -z "$LOCKFD" ] || return 0 # already held (rollback takes it before reading previous/)
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || fail preflight "the lock directory $LOCK_DIR is missing or not a directory: run \`make host-data HOST=<alias> ARGS=install\`"
  lock="$LOCK_DIR/$APP.lock"
  [ ! -L "$lock" ] || fail preflight "the lock path $lock is a symlink"
  # Created under umask 077 and opened for append: the owner can always reopen it for the next run.
  old="$(umask)"
  umask 077
  exec {LOCKFD}>>"$lock" || { umask "$old"; fail preflight "cannot open the lock file $lock"; }
  umask "$old"
  log "phase=lock start wait=${LOCK_WAIT}s"
  if ! flock -w "$LOCK_WAIT" "$LOCKFD"; then
    log "phase=lock end rc=1 FAILED another run for this app holds $lock"
    err "deploy: phase 'lock' failed: another deploy or rollback for '$APP' holds the lock after ${LOCK_WAIT}s. Nothing was changed."
    exit 1
  fi
  log "phase=lock end rc=0"
}

# env_value <key>: the value of KEY=VALUE from connection.env (last one wins), parsed, never sourced.
env_value() {
  local line v=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$1="*) v="${line#"$1="}" ;; *) ;; esac
  done <"$CONNECTION_ENV"
  printf '%s' "$v"
}

preflight() {
  step_begin preflight
  take_lock
  [ -d "$SECRETS_ROOT/$APP" ] && [ ! -L "$SECRETS_ROOT/$APP" ] || fail preflight "no secrets dir $SECRETS_ROOT/$APP: run \`platform new-db $APP\` first"
  [ -d "$JOB_SECRETS_ROOT/$APP" ] && [ ! -L "$JOB_SECRETS_ROOT/$APP" ] || fail preflight "no job-secrets dir $JOB_SECRETS_ROOT/$APP: run \`platform new-db $APP\` first"
  quiet docker network inspect "$NETWORK" || fail preflight "the docker network '$NETWORK' does not exist"
  command -v curl >/dev/null 2>&1 || fail preflight "curl is not installed"
  [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] && [ -w "$STATE_ROOT" ] || fail preflight "the deploy state root $STATE_ROOT is missing or not writable by this user: run \`make host-deploy-user HOST=<alias> ARGS=install\`"
  [ -d "$REGISTRY_ROOT" ] && [ ! -L "$REGISTRY_ROOT" ] && [ -w "$REGISTRY_ROOT" ] || fail preflight "the registry root $REGISTRY_ROOT is missing or not writable by this user: run \`make host-jobs HOST=<alias> ARGS=install\`"
  [ -f "$CONNECTION_ENV" ] && [ -r "$CONNECTION_ENV" ] || fail preflight "the connection file $CONNECTION_ENV is missing: run \`make host-data HOST=<alias> ARGS=install\`"
  PG_HOST="$(env_value PLATFORM_PG_HOST)"
  PG_PORT="$(env_value PLATFORM_PG_PORT)"
  RD_HOST="$(env_value PLATFORM_REDIS_HOST)"
  RD_PORT="$(env_value PLATFORM_REDIS_PORT)"
  [[ "$PG_HOST" =~ $HOST_RE ]] && [[ "$RD_HOST" =~ $HOST_RE ]] || fail preflight "$CONNECTION_ENV has no valid PLATFORM_PG_HOST / PLATFORM_REDIS_HOST"
  [[ "$PG_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [[ "$RD_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || fail preflight "$CONNECTION_ENV has no valid PLATFORM_PG_PORT / PLATFORM_REDIS_PORT"
  step_end
}

# ---- 4. pull ----

pull() {
  local line ref="" tagged
  step_begin pull
  tagged="$IMAGE_REPO:$TAG"
  if [ "$SKIP_REGISTRY" = 1 ]; then
    log "phase=pull registry skipped (DEPLOY_SKIP_REGISTRY=1): using the local image"
    try_phase "$EXEC_TIMEOUT" pull "" docker image inspect --format '{{.Id}}' "$tagged"
    [ "$PHASE_RC" -eq 0 ] || fail pull "the local image $tagged is not present"
    ref="$PHASE_OUT"
    [[ "$ref" =~ ^sha256:[0-9a-f]{64}$ ]] || fail pull "the local image $tagged has no usable image ID"
  else
    phase_t "$PULL_TIMEOUT" pull "$TOKEN" docker login "$REGISTRY_HOST" --username "$REGISTRY_USER" --password-stdin
    phase_t "$PULL_TIMEOUT" pull "" docker pull "$tagged"
    # The token sits on disk (config.json) only for login+pull: nothing later needs the registry, and a SIGKILL after
    # this point must not leave it behind.
    rm -f -- "$DOCKER_CONFIG/config.json"
    try_phase "$EXEC_TIMEOUT" pull "" docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$tagged"
    [ "$PHASE_RC" -eq 0 ] || fail pull "cannot read the digest of $tagged"
    while IFS= read -r line; do
      if [[ "$line" =~ ^${IMAGE_REPO//./\\.}@sha256:[0-9a-f]{64}$ ]]; then
        ref="$line"
        break
      fi
    done <<<"$PHASE_OUT"
    [ -n "$ref" ] || fail pull "the pull of $tagged yielded no digest"
  fi
  REF="$ref"
  PULLED=1
  log "phase=pull resolved reference $REF"
  step_end
}

# ---- 5. inspect ----

inspect_image() {
  local want_arch got_arch user uid labels k want_ports
  step_begin inspect
  try_phase "$EXEC_TIMEOUT" inspect "" docker version --format '{{.Server.Arch}}'
  [ "$PHASE_RC" -eq 0 ] || fail inspect "cannot read the docker daemon architecture"
  want_arch="$PHASE_OUT"
  try_phase "$EXEC_TIMEOUT" inspect "" docker image inspect --format '{{.Architecture}}' "$REF"
  [ "$PHASE_RC" -eq 0 ] || fail inspect "cannot inspect the image $REF"
  got_arch="$PHASE_OUT"
  { [ -n "$want_arch" ] && [ "$got_arch" = "$want_arch" ]; } || fail inspect "the image architecture '$got_arch' is not the daemon's '$want_arch'"

  try_phase "$EXEC_TIMEOUT" inspect "" docker image inspect --format '{{.Config.User}}' "$REF"
  [ "$PHASE_RC" -eq 0 ] || fail inspect "cannot read the image user"
  user="$PHASE_OUT"
  uid="${user%%:*}"
  [[ "$uid" =~ ^[0-9]{1,9}$ ]] || fail inspect "the image USER '$user' is not a numeric uid"
  [ "$((10#$uid))" -ne 0 ] || fail inspect "the image USER '$user' is root"

  # shellcheck disable=SC2016 # a Go template, not a shell expansion
  try_phase "$EXEC_TIMEOUT" inspect "" docker image inspect --format '{{range $k, $v := .Config.Labels}}{{println $k}}{{end}}' "$REF"
  [ "$PHASE_RC" -eq 0 ] || fail inspect "cannot read the image labels"
  labels="$PHASE_OUT"
  while IFS= read -r k; do
    k="${k,,}"
    case "$k" in
      traefik.* | platform.*) fail inspect "the image carries a reserved label ($k)" ;;
      *) ;;
    esac
  done <<<"$labels"

  # shellcheck disable=SC2016 # a Go template, not a shell expansion
  try_phase "$EXEC_TIMEOUT" inspect "" docker image inspect --format '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "$REF"
  [ "$PHASE_RC" -eq 0 ] || fail inspect "cannot read the image exposed ports"
  want_ports="$PORT/tcp"
  [ "$PHASE_OUT" = "$want_ports" ] || fail inspect "the image must expose exactly $want_ports (it exposes: ${PHASE_OUT:-nothing})"
  step_end
}

# ---- 6. swap ----

# restore_old: undo a failed swap or health phase. Best effort; each step is logged.
restore_old() {
  local bad=0
  SWAP_OPEN=0
  log "restoring the previous container"
  # The new container is removed only when the name is known to be ours: no original existed, or it was renamed away.
  if [ "$NEW_RUN" -eq 1 ] && { [ "$ORIG_PRESENT" -eq 0 ] || [ "$RENAMED" -eq 1 ]; }; then
    try_phase "$EXEC_TIMEOUT" swap "" docker rm -f -v "$C_NEW"
    [ "$PHASE_RC" -eq 0 ] || bad=1
  fi
  if [ "$RENAMED" -eq 1 ]; then
    try_phase "$EXEC_TIMEOUT" swap "" docker rename "$C_OLD" "$C_NEW"
    [ "$PHASE_RC" -eq 0 ] || bad=1
  fi
  if [ "$ORIG_PRESENT" -eq 1 ]; then
    try_phase "$EXEC_TIMEOUT" swap "" docker start "$C_NEW"
    [ "$PHASE_RC" -eq 0 ] || bad=1
  fi
  if [ "$bad" -eq 1 ]; then
    err "deploy: THE PREVIOUS CONTAINER MAY NOT BE RESTORED: check app-$APP and app-$APP-old by hand; the next deploy reconciles"
  fi
}

# fail_restore <phase> <message>: restore the old container, then fail.
fail_restore() {
  restore_old
  fail "$1" "$2"
}

# swap_step <cmd...>: a swap-phase docker call; on failure restore and fail.
swap_step() {
  try_phase "$EXEC_TIMEOUT" swap "" "$@"
  [ "$PHASE_RC" -eq 0 ] || fail_restore swap "$2 failed (rc $PHASE_RC)"
}

swap() {
  step_begin swap
  C_NEW="app-$APP"
  C_OLD="app-$APP-old"
  ORIG_PRESENT=0
  RENAMED=0
  NEW_RUN=0
  SWAP_OPEN=1
  # A leftover -old from an interrupted deploy: restore it when the live name is free, else drop it.
  if ctr_exists "$C_OLD"; then
    if ctr_exists "$C_NEW"; then
      swap_step docker rm -f -v "$C_OLD"
    else
      swap_step docker rename "$C_OLD" "$C_NEW"
    fi
  fi
  if ctr_exists "$C_NEW"; then
    ORIG_PRESENT=1
    try_phase $((STOP_TIMEOUT + 10)) swap "" docker stop -t "$STOP_TIMEOUT" "$C_NEW"
    [ "$PHASE_RC" -eq 0 ] || fail_restore swap "stopping $C_NEW failed (rc $PHASE_RC)"
    swap_step docker rename "$C_NEW" "$C_OLD"
    RENAMED=1
  fi
  local -a run=(docker run -d --name "$C_NEW" --label "platform.app=$APP" --network "$NETWORK" --network-alias "$APP"
    --group-add 64323 --group-add 64324 --cap-drop ALL --security-opt no-new-privileges:true --read-only --tmpfs /tmp
    --memory "$MEMCAP" --memory-swap "$MEMCAP" --pids-limit 256 --restart unless-stopped
    -v "$SECRETS_ROOT/$APP:/run/platform/secrets:ro" -v "$JOB_SECRETS_ROOT/$APP:/run/platform/job-secrets:ro"
    -e "DB_HOST=$PG_HOST" -e "DB_PORT=$PG_PORT" -e "DB_NAME=${APP//-/_}" -e "DB_USER=${APP//-/_}"
    -e "DB_PASSWORD_FILE=/run/platform/secrets/db-password"
    -e "REDIS_HOST=$RD_HOST" -e "REDIS_PORT=$RD_PORT" -e "REDIS_USER=$APP"
    -e "REDIS_PASSWORD_FILE=/run/platform/secrets/redis-password" -e "REDIS_KEY_PREFIX=$APP:"
    -e "JOBS_SECRET_FILE=/run/platform/job-secrets/jobs-secret"
    "$REF")
  NEW_RUN=1
  swap_step "${run[@]}"
  step_end
}

# ---- 7. health ----

container_status() {
  try_phase "$EXEC_TIMEOUT" health "" docker inspect --format '{{.State.Status}}' "$C_NEW"
  [ "$PHASE_RC" -eq 0 ] || return 1
  [ "$PHASE_OUT" = running ]
}

health() {
  local ip="" code i deadline url
  step_begin health
  if [ -z "$HEALTH_PATH" ]; then
    log "phase=health no health_path: the container must stay running for ${NOPATH_WAIT}s"
    for ((i = 0; i < NOPATH_WAIT; i++)); do
      container_status || fail_restore health "the container is not running"
      sleep "$POLL"
    done
    container_status || fail_restore health "the container is not running after ${NOPATH_WAIT}s"
    step_end
    return 0
  fi
  deadline=$((SECONDS + HEALTH_WAIT))
  while true; do
    container_status || fail_restore health "the container is not running"
    try_phase "$EXEC_TIMEOUT" health "" docker inspect --format "{{(index .NetworkSettings.Networks \"$NETWORK\").IPAddress}}" "$C_NEW"
    ip=""
    [ "$PHASE_RC" -ne 0 ] || ip="$PHASE_OUT"
    if [[ "$ip" =~ ^[0-9.]+$ ]]; then
      url="http://$ip:$PORT$HEALTH_PATH"
      try_phase 10 health "" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url"
      code="$PHASE_OUT"
      if [ "$PHASE_RC" -eq 0 ] && [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
        step_end
        return 0
      fi
      log "phase=health probe ${HEALTH_PATH} -> ${code:-no reply}"
    fi
    [ "$SECONDS" -lt "$deadline" ] || fail_restore health "no 2xx from ${HEALTH_PATH} within ${HEALTH_WAIT}s"
    sleep "$POLL"
  done
}

# ---- 8. commit ----

# put_file <dest> <src>: copy next to the destination, then an atomic rename.
put_file() {
  local dest="$1" src="$2" tmp
  tmp="${dest%/*}/.tmp.${dest##*/}.$$"
  cp -- "$src" "$tmp" || return 1
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

# Known crash window (accepted): a SIGKILL or power loss between "mv prev previous" / "mv current gone" and "mv new current"
# in commit_state can leave previous/ equal to current/ after the recovery below (the older real previous is lost). The
# next successful deploy restores a good previous/.
# clear_stale <base>: leftovers of an interrupted commit (other pids' .new/.prev/.old/.gone dirs), removed under the lock. A
# missing current/ or previous/ is first put back from a leftover .gone / .old, which is the directory a crash orphaned.
clear_stale() {
  local base="$1" d
  if [ ! -d "$base/current" ]; then
    for d in "$base"/.gone.*; do
      [ -d "$d" ] || continue
      mv -- "$d" "$base/current" && break
    done
  fi
  # previous/ is orphaned by a deploy commit (.old) or by a rollback exchange (.gone) that died between its moves.
  if [ ! -d "$base/previous" ] && [ -d "$base/current" ]; then
    for d in "$base"/.old.* "$base"/.gone.*; do
      [ -d "$d" ] || continue
      mv -- "$d" "$base/previous" && break
    done
  fi
  rm -rf -- "$base"/.new.* "$base"/.prev.* "$base"/.old.* "$base"/.gone.*
}

# rollback_state: exchange current/ and previous/ (three moves, each undone on a later failure). Returns 1 with the state
# as it was, so a failed rollback never loses either version.
rollback_state() {
  local base="$STATE_ROOT/$APP" gone="$STATE_ROOT/$APP/.gone.$$"
  clear_stale "$base"
  [ -d "$base/current" ] && [ -d "$base/previous" ] || return 1
  mv -- "$base/current" "$gone" || return 1
  if ! mv -- "$base/previous" "$base/current"; then
    mv -- "$gone" "$base/current" || true
    return 1
  fi
  if ! mv -- "$gone" "$base/previous"; then
    mv -- "$base/current" "$base/previous" || true
    mv -- "$gone" "$base/current" || true
    return 1
  fi
  return 0
}

# commit_state: <state>/<app>/current becomes the new deploy, previous the old current when the tag differs. Returns 1
# with every move undone, so previous is never advanced by a failed commit.
commit_state() {
  local base="$STATE_ROOT/$APP" new prev old gone cur_tag="" advance=0 s1=0 s2=0 s3=0
  new="$base/.new.$$"
  prev="$base/.prev.$$"
  old="$base/.old.$$"
  gone="$base/.gone.$$"
  mkdir -p -- "$base" || return 1
  clear_stale "$base"
  rm -rf -- "$new" "$prev" "$old" "$gone"
  mkdir -- "$new" || return 1
  { printf '%s\n' "$TAG" >"$new/tag" &&
      printf '%s\n' "$REF" >"$new/digest" &&
      date -u +%Y-%m-%dT%H:%M:%SZ >"$new/deployed-at" &&
      cp -- "$YAML" "$new/app.yaml"; } || { rm -rf -- "$new"; return 1; }
  if [ -d "$base/current" ]; then
    [ ! -f "$base/current/tag" ] || cur_tag="$(<"$base/current/tag")"
    if [ "$cur_tag" != "$TAG" ]; then
      advance=1
      cp -a -- "$base/current" "$prev" || { rm -rf -- "$new" "$prev"; return 1; }
    fi
  fi
  if [ "$advance" -eq 1 ]; then
    if [ -d "$base/previous" ]; then
      mv -- "$base/previous" "$old" || { rm -rf -- "$new" "$prev"; return 1; }
      s1=1
    fi
    if mv -- "$prev" "$base/previous"; then s2=1; else
      [ "$s1" -eq 0 ] || mv -- "$old" "$base/previous" || true
      rm -rf -- "$new" "$prev"
      return 1
    fi
  fi
  if [ -d "$base/current" ]; then
    if mv -- "$base/current" "$gone"; then s3=1; else
      state_undo "$base" "$old" "$s1" "$s2" "$s3" "$gone"
      rm -rf -- "$new" "$prev"
      return 1
    fi
  fi
  if ! mv -- "$new" "$base/current"; then
    state_undo "$base" "$old" "$s1" "$s2" "$s3" "$gone"
    rm -rf -- "$new" "$prev"
    return 1
  fi
  rm -rf -- "$old" "$gone"
  return 0
}

# state_undo <base> <old> <s1> <s2> <s3> <gone>: reverse the moves already done by commit_state.
state_undo() {
  local base="$1" old="$2" s1="$3" s2="$4" s3="$5" gone="$6"
  [ "$s3" -eq 0 ] || mv -- "$gone" "$base/current" || true
  [ "$s2" -eq 0 ] || rm -rf -- "$base/previous"
  [ "$s1" -eq 0 ] || mv -- "$old" "$base/previous" || true
}

commit() {
  local regdir="$REGISTRY_ROOT/$APP" rc
  step_begin commit
  SWAP_OPEN=0
  if ! { (umask 022 && mkdir -p -- "$regdir") && (umask 022 && put_file "$regdir/app.yaml" "$YAML"); }; then
    log "phase=commit the registry write failed; the new container keeps running, the old one is not removed"
    fail commit "cannot write $regdir/app.yaml; the next deploy reconciles"
  fi
  # Ordering (accepted): the registry app.yaml is written before rollback_state, so a failed state exchange leaves
  # "platform current" recording the newer failed tag while the older version runs; the next deploy reconciles.
  rc=0
  if [ "$MODE" = rollback ]; then
    (umask 022 && rollback_state) || rc=$?
  else
    (umask 022 && commit_state) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    log "phase=commit the deploy-state write failed; the new container keeps running, the old one is not removed"
    fail commit "cannot write the deploy state under $STATE_ROOT/$APP; the next deploy reconciles"
  fi
  if [ "$RENAMED" -eq 1 ]; then
    try_phase "$EXEC_TIMEOUT" commit "" docker rm -f -v "$C_OLD"
    [ "$PHASE_RC" -eq 0 ] || log "phase=commit warning: could not remove $C_OLD; the next deploy removes it"
  fi
  step_end
}

# ---- rollback: load the previous deploy ----

load_previous() {
  local p="$STATE_ROOT/$APP/previous" size
  step_begin previous
  { [ -d "$p" ] && [ ! -L "$p" ] && [ -f "$p/tag" ] && [ -f "$p/digest" ] && [ -f "$p/app.yaml" ]; } || fail previous "no previous deploy"
  TAG="$(<"$p/tag")"
  REF="$(<"$p/digest")"
  [[ "$TAG" =~ $TAG_RE ]] || fail previous "the recorded previous tag is not usable"
  [[ "$REF" =~ ^sha256:[0-9a-f]{64}$ || "$REF" =~ ^${IMAGE_REPO//./\\.}@sha256:[0-9a-f]{64}$ ]] || fail previous "the recorded previous image reference is not usable"
  cp -- "$p/app.yaml" "$YAML" || fail previous "cannot read the recorded previous app.yaml"
  size="$(stat -c %s -- "$YAML")"
  { [ "$size" -gt 0 ] && [ "$size" -le "$YAML_MAX" ]; } || fail previous "the recorded previous app.yaml is empty or over $YAML_MAX bytes"
  log "phase=previous rolling back to tag=$TAG ref=$REF"
  step_end
}

# ---- cleanup ----

# prune_images <all|new>: remove this app's local images other than the current and previous deploys' (compared by image
# ID, resolved from the recorded references). `new` removes only the image REF resolves to, when it is neither. Only this
# app's repository is listed, and a plain `docker rmi` (no -f) refuses an image a container uses. A failure is a warning.
prune_images() {
  local mode="$1" keep=" " only="" f d id repo tag dig ref gone=" " listing
  for f in current previous; do
    [ -d "$STATE_ROOT/$APP/$f" ] || continue
    d="$(<"$STATE_ROOT/$APP/$f/digest")" || d=""
    if ! { [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || [[ "$d" =~ ^${IMAGE_REPO//./\\.}@sha256:[0-9a-f]{64}$ ]]; }; then
      log "phase=cleanup warning: $f/digest is not a usable reference; no image was removed"
      return 0
    fi
    try_phase "$EXEC_TIMEOUT" cleanup "" docker image inspect --format '{{.Id}}' "$d"
    if [ "$PHASE_RC" -eq 0 ]; then
      keep+="$PHASE_OUT "
    else
      case "$(head -c 2000 "$ERRF")" in
        *[Nn]o\ such*) ;; # the recorded image is simply not local
        *)
          log "phase=cleanup warning: cannot resolve the $f image; no image was removed"
          return 0
          ;;
      esac
    fi
  done
  if [ "$mode" = new ]; then
    try_phase "$EXEC_TIMEOUT" cleanup "" docker image inspect --format '{{.Id}}' "$REF"
    if [ "$PHASE_RC" -ne 0 ]; then
      log "phase=cleanup warning: cannot resolve the pulled image; it was not removed"
      return 0
    fi
    only="$PHASE_OUT"
    case "$keep" in *" $only "*) return 0 ;; *) ;; esac
  fi
  try_phase "$EXEC_TIMEOUT" cleanup "" docker image ls --no-trunc --digests --format '{{.ID}} {{.Repository}} {{.Tag}} {{.Digest}}' "$IMAGE_REPO"
  if [ "$PHASE_RC" -ne 0 ]; then
    log "phase=cleanup warning: cannot list the images of $IMAGE_REPO; none was removed"
    return 0
  fi
  listing="$PHASE_OUT"
  while read -r id repo tag dig; do
    [ -n "$id" ] && [ "$repo" = "$IMAGE_REPO" ] || continue
    case "$keep" in *" $id "*) continue ;; *) ;; esac
    [ -z "$only" ] || [ "$id" = "$only" ] || continue
    if [ "$tag" != "<none>" ]; then
      ref="$repo:$tag"
    elif [ "$dig" != "<none>" ]; then
      case "$gone" in *" $id "*) continue ;; *) ;; esac
      ref="$repo@$dig"
    else
      continue
    fi
    try_phase "$EXEC_TIMEOUT" cleanup "" docker rmi "$ref"
    if [ "$PHASE_RC" -eq 0 ]; then
      gone+="$id "
    else
      log "phase=cleanup warning: could not remove $ref"
    fi
  done <<<"$listing"
  log "phase=cleanup done (mode $mode)"
}

main() {
  case "${1:-}" in
    deploy) [ "$#" -eq 3 ] || { err "usage: deploy.sh deploy <app> <tag> | deploy.sh rollback <app>"; exit 2; } ;;
    rollback) [ "$#" -eq 2 ] || { err "usage: deploy.sh deploy <app> <tag> | deploy.sh rollback <app>"; exit 2; } ;;
    *) err "usage: deploy.sh deploy <app> <tag> | deploy.sh rollback <app>"; exit 2 ;;
  esac
  MODE="$1"
  APP="$2"
  TAG="${3:-}"
  [[ "$APP" =~ $APP_RE ]] || { err "deploy: invalid app name (want $APP_RE)"; exit 2; }
  [ "$MODE" = rollback ] || [[ "$TAG" =~ $TAG_RE ]] || { err "deploy: invalid tag (want $TAG_RE)"; exit 2; }
  IMAGE_REPO="$IMAGE_NS/$APP"
  [[ "$NETWORK" =~ $NET_RE ]] || { err "deploy: DEPLOY_NETWORK is not a valid network name"; exit 2; }
  local v
  for v in "$LOCK_WAIT" "$EXEC_TIMEOUT" "$PULL_TIMEOUT" "$STOP_TIMEOUT" "$STALE_TMP_MIN" "$HEALTH_WAIT" "$NOPATH_WAIT"; do
    [[ "$v" =~ $NUM_RE ]] || { err "deploy: a DEPLOY_* wait or timeout is not a whole number of seconds"; exit 2; }
  done
  # timeout 0 would disable the limit, so the two docker call limits need at least 1.
  [[ "$EXEC_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ && "$PULL_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]] || { err "deploy: DEPLOY_EXEC_TIMEOUT and DEPLOY_PULL_TIMEOUT must be 1 to 99999 seconds"; exit 2; }
  if [ "$MODE" = rollback ]; then
    log "start rollback"
    init_tmp
    take_lock
    clear_stale "$STATE_ROOT/$APP"
    load_previous
    validate
    preflight
  else
    log "start tag=$TAG"
    read_input
    validate
    preflight
    pull
  fi
  inspect_image
  swap
  health
  commit
  prune_images all
  log "end rc=0"
  if [ "$MODE" = rollback ]; then
    printf 'rollback: done %s %s\n' "$APP" "$TAG"
  else
    printf 'deploy: done %s %s\n' "$APP" "$TAG"
  fi
}

main "$@"
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/deploy/deploy.sh

# BEGIN-PAYLOAD platform/registry/validate-app-yaml.sh
payload_validate_app_yaml_sh() {
  cat <<'PLATFORM_PAYLOAD_EOF'
#!/usr/bin/env bash
# validate-app-yaml.sh: fail-closed validator for the per-app registry file apps/<name>/app.yaml.
#
#   platform/registry/validate-app-yaml.sh <file>...
#
# Exit 0: every file is valid. Exit 1: at least one problem; one "file: reason" line per problem on stdout.
# Exit 2: usage (no file given). The schema is documented in platform/registry/README.md; anything it does not
# list is an error (unknown key, wrong type, bad value, reserved name), never a guess.
#
# The file is read with platform/lib/yaml-subset.sh, so it must stay in that small YAML subset. Cron schedules
# must be quoted (a leading "*" is otherwise a YAML alias, which the subset refuses).
# shellcheck disable=SC1091
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/yaml-subset.sh
. "$here/../lib/yaml-subset.sh"

APP_RE='^[a-z][a-z0-9-]{1,30}$'
JOB_RE='^[a-z][a-z0-9_-]{0,62}$'
TEMPLATES=" go-react go-htmx fastapi-react flask node-hono "
TOP_KEYS=" schema_version name owner purpose template memory_cap port health_path access jobs "
TOP_REQUIRED="schema_version name owner purpose template memory_cap port"
JOB_KEYS=" name schedule timeout catch_up "
RESERVED_FILE="$here/reserved-names.txt"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <app.yaml>..." >&2
  exit 2
fi

problems=0
file=""
flat=""
stderr_file=""
reserved=""
trap 'rm -f "$flat" "$stderr_file"' EXIT

err() {
  printf '%s: %s\n' "$file" "$1"
  problems=$((problems + 1))
}

# reserved_names: the names in reserved-names.txt (comments and blank lines dropped).
reserved_names() {
  awk '{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); if ($0 != "" && $0 !~ /^#/) print }' "$RESERVED_FILE"
}

# top_keys: the distinct top-level keys of the flattened file.
top_keys() { awk -F '\t' '{ p = $1; sub(/[\/\[].*/, "", p); if (p != "" && !(p in s)) { s[p] = 1; print p } }' "$flat"; }

# has_below <path>: some flattened path sits under <path> (a child key, a list item).
has_below() { awk -F '\t' -v a="$1/" -v b="$1[" 'index($1, a) == 1 || index($1, b) == 1 { f = 1 } END { exit f ? 0 : 1 }' "$flat"; }

# job_indexes: the distinct N of jobs[N] paths.
job_indexes() { awk -F '\t' '$1 ~ /^jobs\[[0-9]+\]/ { p = $1; sub(/^jobs\[/, "", p); sub(/\].*/, "", p); if (!(p in s)) { s[p] = 1; print p } }' "$flat"; }

# job_keys <n>: the rest of every path under jobs[n]/ (a key, or key/deeper for a nested value).
job_keys() { awk -F '\t' -v p="jobs[$1]/" 'index($1, p) == 1 { print substr($1, length(p) + 1) }' "$flat"; }

# raw_checks: type checks the flattened form cannot make because quoting is gone after flattening.
raw_checks() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && err "$line"
  done < <(awk '
    {
      s = $0
      sub(/^[ ]*(-[ ]+)?/, "", s)
      if (match(s, /^(port|schema_version|catch_up):[ ]*["\047]/)) {
        k = s; sub(/:.*/, "", k)
        printf("%s must be an unquoted value, not a string (line %d)\n", k, NR)
      }
      if (match(s, /^schedule:[ ]*[^ "\047]/)) {
        printf("schedule must be a quoted cron string (line %d)\n", NR)
      }
    }' "$file")
}

# cron_field_ok <field>: a comma list of items; item = "*", a number or a range, with an optional /step.
# Strict grammar, the same one the runner's Go parser accepts (shared fixture cron-cases.table): numbers
# without leading zeros, N-M with N <= M, a /step (>= 1, at most the field's max minus min) only after "*" or a range.
CRON_NUM='(0|[1-9][0-9]{0,5})'
CRON_ITEM="(\\*|${CRON_NUM}(-${CRON_NUM})?)(/${CRON_NUM})?"
CRON_RE="^${CRON_ITEM}(,${CRON_ITEM})*\$"
CRON_NAMES=(minute hour day-of-month month day-of-week)
CRON_MIN=(0 0 1 1 0)
CRON_MAX=(59 23 31 12 7)

# cron_field_problem <index> <field>: prints the reason and returns 1 when the field is not valid.
cron_field_problem() {
  local idx="$1" field="$2" lo hi item base step a b
  lo="${CRON_MIN[$idx]}"
  hi="${CRON_MAX[$idx]}"
  [[ "$field" =~ $CRON_RE ]] || { echo "is not a cron field"; return 1; }
  local -a items
  IFS=',' read -r -a items <<< "$field"
  for item in "${items[@]}"; do
    base="${item%%/*}"
    step=""
    [ "$base" = "$item" ] || step="${item#*/}"
    if [ "$base" = "*" ]; then
      :
    elif [[ "$base" == *-* ]]; then
      a="${base%-*}"
      b="${base#*-}"
      if [ "$a" -lt "$lo" ] || [ "$a" -gt "$hi" ] || [ "$b" -lt "$lo" ] || [ "$b" -gt "$hi" ]; then
        echo "is out of range (must be $lo-$hi)"
        return 1
      fi
      if [ "$a" -gt "$b" ]; then echo "has a reversed range '$base'"; return 1; fi
    else
      if [ -n "$step" ]; then echo "has a step '/$step' on a single number"; return 1; fi
      if [ "$base" -lt "$lo" ] || [ "$base" -gt "$hi" ]; then
        echo "is out of range (must be $lo-$hi)"
        return 1
      fi
    fi
    if [ -n "$step" ]; then
      if [ "$step" -lt 1 ]; then echo "has a step of zero"; return 1; fi
      if [ "$step" -gt $((hi - lo)) ]; then echo "has a step '/$step' larger than the range $lo-$hi"; return 1; fi
    fi
  done
  return 0
}

check_schedule() {
  local where="$1" sched="$2" i reason
  local -a fields
  read -r -a fields <<< "$sched"
  for i in "${!fields[@]}"; do
    # A sixth or later field has no name or range; only its shape is checked before the count error below.
    if [ "$i" -ge 5 ]; then
      [[ "${fields[$i]}" =~ $CRON_RE ]] || { err "$where schedule field '${fields[$i]}' is not a cron field"; return; }
      continue
    fi
    if ! reason="$(cron_field_problem "$i" "${fields[$i]}")"; then
      err "$where schedule ${CRON_NAMES[$i]} field '${fields[$i]}' $reason"
      return
    fi
  done
  [ "${#fields[@]}" -eq 5 ] || err "$where schedule must have exactly 5 fields"
}

check_timeout() {
  local where="$1" v="$2" n unit
  if ! [[ "$v" =~ ^[0-9]{1,6}(s|m|h)$ ]]; then
    err "$where timeout '$v' must look like 30s, 2m or 1h"
    return
  fi
  unit="${v: -1}"
  n=$((10#${v%?}))
  [ "$n" -ge 1 ] || { err "$where timeout must be greater than zero"; return; }
  case "$unit" in
    s) [ "$n" -le 3600 ] || err "$where timeout '$v' is over the 1h maximum" ;;
    m) [ "$n" -le 60 ] || err "$where timeout '$v' is over the 1h maximum" ;;
    h) [ "$n" -le 1 ] || err "$where timeout '$v' is over the 1h maximum" ;;
    *) err "$where timeout '$v' has an unknown unit" ;;
  esac
}

check_name() {
  local name="$1" dir pg
  if ! [[ "$name" =~ $APP_RE ]]; then
    err "name '$name' must match $APP_RE"
    return
  fi
  dir="$(basename "$(cd "$(dirname "$file")" && pwd -L)")"
  [ "$name" = "$dir" ] || err "name '$name' must equal the parent directory name '$dir'"
  if grep -qxF -- "$name" <<< "$reserved"; then
    err "name '$name' is reserved"
  fi
  pg="${name//-/_}"
  case "$pg" in
    pg_* | postgres | template0 | template1 | public)
      err "name '$name' maps to the refused Postgres identifier '$pg'"
      ;;
    *) ;;
  esac
}

check_job() {
  local i="$1" k rest v where
  local seen_keys=" "
  where="jobs[$i]"
  while IFS= read -r rest; do
    k="${rest%%/*}"
    if [ "$k" != "$rest" ]; then
      err "$where/$k must be a scalar"
      continue
    fi
    case "$JOB_KEYS" in
      *" $k "*) ;;
      *) err "$where has unknown key '$k'"; continue ;;
    esac
    seen_keys="$seen_keys$k "
  done < <(job_keys "$i")
  case "$seen_keys" in *" name "*) ;; *) err "$where is missing required key 'name'" ;; esac
  case "$seen_keys" in *" timeout "*) ;; *) err "$where is missing required key 'timeout'" ;; esac
  case "$seen_keys" in
    *" name "*)
      v="$(ys_get "$flat" "jobs[$i]/name")"
      [[ "$v" =~ $JOB_RE ]] || err "$where name '$v' must match $JOB_RE"
      ;;
    *) ;;
  esac
  case "$seen_keys" in
    *" timeout "*) check_timeout "$where" "$(ys_get "$flat" "jobs[$i]/timeout")" ;;
    *) ;;
  esac
  case "$seen_keys" in
    *" schedule "*)
      v="$(ys_get "$flat" "jobs[$i]/schedule")"
      if [ -n "$v" ]; then check_schedule "$where" "$v"; else err "$where schedule must not be empty"; fi
      ;;
    *) ;;
  esac
  case "$seen_keys" in
    *" catch_up "*)
      v="$(ys_get "$flat" "jobs[$i]/catch_up")"
      case "$v" in true | false) ;; *) err "$where catch_up '$v' must be true or false" ;; esac
      ;;
    *) ;;
  esac
}

check_jobs() {
  local i names="" n
  if [ -n "$(ys_get "$flat" jobs)" ]; then
    err "jobs must be a list of maps, not a scalar"
    return
  fi
  if ys_has "$flat" "jobs[]"; then
    err "jobs items must be maps (name, schedule, timeout, catch_up), not plain values"
  fi
  if [ -z "$(job_indexes)" ]; then
    err "jobs is present but has no entries (omit the key instead)"
    return
  fi
  for i in $(job_indexes); do
    check_job "$i"
    names="$names$(ys_get "$flat" "jobs[$i]/name")"$'\n'
  done
  n="$(printf '%s' "$names" | grep -v '^$' | sort | uniq -d)"
  [ -z "$n" ] || err "duplicate job name '$(echo "$n" | head -n 1)'"
}

check_scalar_keys() {
  local k v
  for k in $TOP_KEYS; do
    [ "$k" = jobs ] && continue
    ys_has "$flat" "$k" || continue
    if has_below "$k"; then
      err "$k must be a scalar value"
      continue
    fi
    v="$(ys_get "$flat" "$k")"
    [ -n "$v" ] || { err "$k must not be empty"; continue; }
    case "$k" in
      schema_version) [ "$v" = 1 ] || err "schema_version '$v' must be 1" ;;
      name) check_name "$v" ;;
      owner)
        if [[ "$v" == *@* ]]; then
          err "owner must be a short handle, not an email address"
        elif ! [[ "$v" =~ $APP_RE ]]; then
          err "owner '$v' must match $APP_RE"
        fi
        ;;
      purpose)
        if [[ "$v" =~ ^[[:space:]]*$ ]]; then
          err "purpose must not be only whitespace"
        elif [ "${#v}" -gt 120 ]; then
          err "purpose is ${#v} characters, the maximum is 120"
        fi
        ;;
      template)
        case "$TEMPLATES" in *" $v "*) ;; *) err "template '$v' is not one of:$TEMPLATES" ;; esac
        ;;
      memory_cap)
        if ! [[ "$v" =~ ^[1-9][0-9]{0,2}m$ ]]; then
          err "memory_cap '$v' must be a number of MiB with the unit m, like 64m"
        elif [ "${v%m}" -lt 16 ] || [ "${v%m}" -gt 512 ]; then
          err "memory_cap '$v' must be between 16m and 512m"
        fi
        ;;
      port)
        if ! [[ "$v" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$v" -gt 65535 ]; then
          err "port '$v' must be an integer from 1 to 65535"
        fi
        ;;
      health_path)
        if [[ "$v" != /* ]]; then
          err "health_path '$v' must start with /"
        elif ! [[ "$v" =~ ^/[A-Za-z0-9._~/%-]*$ ]]; then
          err "health_path '$v' may only contain letters, digits and . _ ~ / % -"
        fi
        ;;
      access)
        case "$v" in family | public | restricted) ;; *) err "access '$v' must be family, public or restricted" ;; esac
        ;;
      *) err "internal: no rule for key $k" ;;
    esac
  done
}

validate_one() {
  local k rc=0
  file="$1"
  if [ -L "$file" ]; then
    err "must be a regular file, not a symlink"
    return
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    err "not a readable file"
    return
  fi
  if [ ! -r "$RESERVED_FILE" ]; then
    err "reserved-names.txt is missing, cannot validate (fails closed)"
    return
  fi
  reserved="$(reserved_names)"
  if [ -z "$reserved" ]; then
    err "reserved-names.txt has no entries, cannot validate (fails closed)"
    return
  fi
  raw_checks
  flat="$(mktemp)"
  stderr_file="$(mktemp)"
  ys_flatten < "$file" > "$flat" 2> "$stderr_file" || rc=$?
  if [ "$rc" -ne 0 ]; then
    err "not valid app.yaml syntax: $(head -n 1 "$stderr_file")"
    rm -f "$flat" "$stderr_file"
    return
  fi
  rm -f "$stderr_file"
  for k in $(top_keys); do
    case "$TOP_KEYS" in *" $k "*) ;; *) err "unknown key '$k'" ;; esac
  done
  for k in $TOP_REQUIRED; do
    ys_has "$flat" "$k" || err "missing required key '$k'"
  done
  check_scalar_keys
  if ys_has "$flat" jobs; then check_jobs; fi
  rm -f "$flat"
}

for f in "$@"; do
  validate_one "$f"
done

[ "$problems" -eq 0 ]
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/registry/validate-app-yaml.sh

# BEGIN-PAYLOAD platform/registry/reserved-names.txt
payload_reserved_names_txt() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# App names the platform refuses (one per line; blank lines and # comments are ignored).
# Read by validate-app-yaml.sh in the repo, and on the host by `platform new-db` through the copy that
# install-data.sh installs.
#
# Rule beyond this list: an app's Postgres identifier is its name with "-" replaced by "_"; that identifier
# must not start with pg_ or equal postgres, template0, template1 or public. Both the validator and new-db
# apply it, so the two cannot diverge.
postgres
redis
valkey
pgbouncer
traefik
cloudflared
socket-proxy
down-page
status
platform
runner
jobs
backup
admin
health
default
www
ingress-livetest
ingress-livetest-sibling
ingress-livetest-curl
ingress-livetest-hostile
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/registry/reserved-names.txt

# BEGIN-PAYLOAD platform/lib/yaml-subset.sh
payload_yaml_subset_sh() {
  cat <<'PLATFORM_PAYLOAD_EOF'
#!/usr/bin/env bash
# yaml-subset.sh: a tiny reader for the YAML subset that compose.yaml and dynamic.yml are written in. Source it
# from a test; do not run it.
#
#   . "$here/yaml-subset.sh"
#   ys_flatten < compose.yaml > flat.tsv   # rc 3 (reason on stderr) when the file leaves the subset
#   ys_get flat.tsv services/traefik/image
#   ys_list flat.tsv services/traefik/networks      # the values of services/traefik/networks[]
#   ys_has flat.tsv services/traefik/read_only
#   ys_children flat.tsv services/traefik/environment   # direct child keys
#
# Paths join keys with "/" (not ".") so that a path in a test never looks like a hostname to the secrets scan.
# The subset (anything else is refused, so a file that drifts out of it fails the tests instead of being
# misread):
#   - 2-space indentation, spaces only, "key: value" maps, "- value" lists indented two under their key;
#   - "- key: value" list items (maps in lists), whose further keys sit two deeper than the dash;
#   - scalars are plain or fully quoted ("..." or '...', no backslash and no inner quote of the same kind);
#   - whole-line "#" comments only (an unquoted value may not contain " #");
#   - no flow collections ([..] or {..}) as values, anchors, aliases, tags, block scalars, "---", merge keys.
#
# Output lines are "path<TAB>value": maps give "a/b<TAB>" for the key itself and "a/b/c<TAB>v" for scalars, lists
# give "a/b[]<TAB>v" per scalar item, list-of-map items give "a/b[0]/url<TAB>v". Duplicate paths are refused.

ys_flatten() {
  awk '
    function fail(msg) { printf("yaml-subset: line %d: %s\n", NR, msg) > "/dev/stderr"; bad = 1; exit 3 }
    function trim(s) { sub(/^ +/, "", s); sub(/ +$/, "", s); return s }
    function scalar(v,   q) {
      if (v ~ /^["\047]/) {
        q = substr(v, 1, 1)
        if (length(v) < 2 || substr(v, length(v), 1) != q) fail("unterminated quoted scalar")
        v = substr(v, 2, length(v) - 2)
        if (index(v, q) > 0) fail("inner quote of the same kind in a quoted scalar")
        if (index(v, "\\") > 0) fail("backslash in a quoted scalar")
        return v
      }
      if (v ~ /^[\[{&*!|>%@`]/) fail("flow collection, anchor, alias, tag or block scalar: " substr(v, 1, 1))
      if (v ~ /^<</) fail("merge key")
      if (v ~ / #/) fail("trailing comment in an unquoted value")
      if (v ~ /:$/ || v ~ /: /) fail("colon inside an unquoted value (inline map)")
      return v
    }
    function pathof(depth,   i, p) {
      p = ""
      for (i = 0; i <= depth; i++) {
        if (part[i] == "") continue
        if (substr(part[i], 1, 1) == "[") p = p part[i]
        else p = (p == "" ? "" : p "/") part[i]
      }
      return p
    }
    function emit(p, v) {
      if (p !~ /\[\]$/) {
        if (p in seen) fail("duplicate path " p)
        seen[p] = 1
      }
      printf("%s\t%s\n", p, v)
    }
    function setkey(depth, indent, rest,   key, val, m) {
      if (!match(rest, /^[A-Za-z0-9_.-]+:( |$)/)) fail("not a plain key: value line")
      key = substr(rest, 1, RLENGTH - 1)
      sub(/:$/, "", key)
      sub(/: $/, "", key)
      val = trim(substr(rest, RLENGTH + 1))
      if (index(key, ":") > 0) fail("colon in key")
      part[depth] = key
      for (m = depth + 1; m < 64; m++) { part[m] = ""; nlist[m] = 0 }
      lastdepth = depth
      if (val == "") { emit(pathof(depth), ""); kind[depth] = "k" }
      else { emit(pathof(depth), scalar(val)); kind[depth] = "s" }
    }
    /\t/ { fail("tab character") }
    /\r/ { fail("carriage return") }
    /^[ ]*$/ { next }
    /^[ ]*#/ { next }
    /^---/ || /^\.\.\./ { fail("document marker") }
    {
      line = $0
      match(line, /^ */); indent = RLENGTH
      if (indent % 2 != 0) fail("odd indentation")
      rest = substr(line, indent + 1)
      depth = indent / 2
      if (depth > 0 && kind[depth - 1] == "s") fail("indented under a scalar value")
      if (depth > lastdepth + 1) fail("indentation jumps more than one level")
      if (rest == "-" || rest ~ /^- /) {
        if (depth == 0) fail("list at top level")
        item = trim(substr(rest, 2))
        if (item == "") fail("empty list item")
        if (kind[depth - 1] != "k") fail("list item not under a key")
        if (item ~ /^[A-Za-z0-9_.-]+: / || item ~ /^[A-Za-z0-9_.-]+:$/) {
          nlist[depth]++
          part[depth] = "[" (nlist[depth] - 1) "]"
          for (m = depth + 1; m < 64; m++) { part[m] = ""; nlist[m] = 0 }
          kind[depth] = "m"
          lastdepth = depth
          setkey(depth + 1, indent + 2, item)
        } else {
          emit(pathof(depth - 1) "[]", scalar(item))
          part[depth] = ""
          kind[depth] = "i"
          lastdepth = depth
        }
        next
      }
      if (depth > 0 && kind[depth - 1] == "i") fail("key after a list item")
      setkey(depth, indent, rest)
    }
    BEGIN { lastdepth = -1 }
  '
}

# ys_flatten reads the YAML on stdin; these helpers take the flattened file.

ys_get() { awk -F '\t' -v p="$2" '$1 == p { print substr($0, length(p) + 2); exit }' "$1"; }
ys_has() { awk -F '\t' -v p="$2" '$1 == p { f = 1 } END { exit f ? 0 : 1 }' "$1"; }
ys_list() { awk -F '\t' -v p="$2[]" '$1 == p { print substr($0, length(p) + 2) }' "$1"; }
ys_children() {
  awk -F '\t' -v p="$2/" 'index($1, p) == 1 { rest = substr($1, length(p) + 1); sub(/[\/\[].*/, "", rest); if (rest != "" && !(rest in s)) { s[rest] = 1; print rest } }' "$1"
}
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/lib/yaml-subset.sh

# ---- input validation (shared by the local and the remote side) ----

# check_key <line>: exactly one bare public-key line; exits 2 otherwise.
check_key() {
  local key="$1"
  [ -n "$key" ] || die "empty public key" 2
  case "$key" in
    *$'\n'* | *$'\r'* | *'"'* | *"'"* | *\\* | *'`'* | *'$'*) die "public key must be one line without quotes, backslashes or newlines" 2 ;;
  esac
  [[ "$key" =~ ^${KEY_RE}$ ]] || die "not a bare one-line public key (<keytype> <base64> [comment], no option prefix)" 2
}

# check_from <pattern>: pattern/CIDR characters only; exits 2 otherwise.
check_from() {
  [[ "$1" =~ ^${FROM_RE}$ ]] || die "--from may contain only pattern/CIDR characters" 2
}

# read_key_file <path>: prints the validated key line.
read_key_file() {
  local file="$1" lines=()
  { [ -f "$file" ] && [ -r "$file" ]; } || die "cannot read public key file: $file" 2
  mapfile -t lines < "$file"
  [ "${#lines[@]}" -eq 1 ] || die "public key file must hold exactly one line" 2
  check_key "${lines[0]}"
  printf '%s\n' "${lines[0]}"
}

# ---- rendered contents ----

# key_line <key> <from>: the authorized_keys line.
key_line() {
  local prefix=""
  [ -z "$2" ] || prefix="from=\"$2\","
  printf '%srestrict,command="%s" %s\n' "$prefix" "$DISPATCHER_PATH" "$1"
}

render_dropin() {
  cat <<EOF
# Managed by platform/host/install-deploy-user.sh. Do not edit by hand; re-run the installer.
# The Match block ends at this file's end, so it cannot swallow later directives or other drop-ins.
Match User $DEPLOY_USER
    AuthorizedKeysFile $KEY_FILE
    PermitTTY no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    GatewayPorts no
    PermitUserRC no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    AuthorizedKeysCommand none
EOF
}

# The effective sshd settings the deploy user must have: one list, used by install (before the reload) and verify.
deploy_directives() {
  printf '%s\n' \
    "authorizedkeysfile $KEY_FILE" \
    "permittty no" \
    "allowtcpforwarding no" \
    "allowagentforwarding no" \
    "allowstreamlocalforwarding no" \
    "x11forwarding no" \
    "permittunnel no" \
    "gatewayports no" \
    "permituserrc no" \
    "permituserenvironment no" \
    "passwordauthentication no" \
    "kbdinteractiveauthentication no" \
    "authenticationmethods publickey" \
    "authorizedkeyscommand none"
}

# group_set <user>: the user's groups, sorted and space-separated (id -nG order is not stable).
group_set() {
  id -nG "$1" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//'
}

# ---- file helpers ----

# file_meta <path>: "<owner>:<group> <octal mode>".
file_meta() { stat -c '%U:%G %a' -- "$1"; }

# place_file <src> <dest> <mode>: copy, own as root, chmod, then atomic rename. Reports already/changed.
place_file() {
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest" && [ "$(file_meta "$dest")" = "root:root $mode" ]; then
    info "already: $dest"
    return 0
  fi
  priv cp -- "$src" "$dest.new"
  priv chown root:root "$dest.new"
  priv chmod "$mode" "$dest.new"
  priv mv -f -- "$dest.new" "$dest"
  info "changed: $dest"
}

# place_dir <path> <mode> [<owner:group>, default root:root]
place_dir() {
  local dir="$1" mode="$2" owner="${3:-root:root}"
  if [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(file_meta "$dir")" = "$owner $mode" ]; then
    info "already: $dir/"
    return 0
  fi
  priv mkdir -p -- "$dir"
  priv chown "$owner" "$dir"
  priv chmod "$mode" "$dir"
  info "changed: $dir/"
}

# sshd_effective <user>: the effective sshd config for the user, sorted.
sshd_effective() {
  priv sshd -T -C "user=$1,host=localhost,addr=127.0.0.1" | sort
}

# ---- install ----

ensure_user() {
  local entry shell groups
  getent group docker >/dev/null || die "the docker group does not exist; install Docker first (make host-base)"
  entry="$(getent passwd "$DEPLOY_USER" || true)"
  if [ -z "$entry" ]; then
    priv useradd --create-home --shell "$WRAPPER_PATH" --groups docker --comment "platform deploy" "$DEPLOY_USER"
    priv passwd -l "$DEPLOY_USER"
    info "changed: user $DEPLOY_USER created (locked password, docker group, login shell $WRAPPER_PATH)"
    return 0
  fi
  local changed=0 uid
  # Fail closed: refuse a uid 0 account and any group beyond its own and docker, before changing anything.
  uid="$(id -u "$DEPLOY_USER")"
  { [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ne 0 ]; } || die "$DEPLOY_USER uid is not a nonzero number ('$uid'); fix the account and re-run"
  groups=" $(id -nG "$DEPLOY_USER") "
  case "$groups" in
    *" sudo "*) die "$DEPLOY_USER is in the sudo group; remove it (gpasswd -d $DEPLOY_USER sudo) and re-run" ;;
  esac
  case "$(group_set "$DEPLOY_USER")" in
    "$DEPLOY_USER docker") ;;
    "$DEPLOY_USER") priv usermod -aG docker "$DEPLOY_USER"; changed=1 ;;
    *) die "$DEPLOY_USER is in groups other than its own and docker ($(id -nG "$DEPLOY_USER")); remove the extra groups and re-run" ;;
  esac
  shell="${entry##*:}"
  if [ "$shell" != "$WRAPPER_PATH" ]; then
    priv usermod --shell "$WRAPPER_PATH" "$DEPLOY_USER"
    changed=1
  fi
  local status
  status="$(priv passwd -S "$DEPLOY_USER" | awk '{print $2}')"
  case "$status" in
    L | LK) ;;
    *) priv passwd -l "$DEPLOY_USER"; changed=1 ;;
  esac
  if [ "$changed" -eq 1 ]; then info "changed: user $DEPLOY_USER"; else info "already: user $DEPLOY_USER"; fi
}

reload_sshd() {
  priv systemctl reload ssh || priv systemctl reload sshd || die "sshd reload failed; the drop-in is in place but not active: reload sshd by hand"
}

# deploy_missing: prints each required directive the deploy user's effective sshd config lacks (global settings that
# come first in the config win over a Match block, so the drop-in alone proves nothing).
deploy_missing() {
  local eff d
  eff="$(sshd_effective "$DEPLOY_USER")" || { echo "(cannot read the effective sshd config for $DEPLOY_USER)"; return 0; }
  while IFS= read -r d; do
    grep -qxF "$d" <<<"$eff" || printf '%s\n' "$d"
  done < <(deploy_directives)
}

install_dropin() {
  local dest="$ROOT$DROPIN" new backup="" before after missing syntax_ok had=0
  new="$TMP/dropin.new"
  render_dropin > "$new"
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$new" "$dest" && [ "$(file_meta "$dest")" = "root:root 644" ]; then
    info "already: $dest"
    return 0
  fi
  before="$(sshd_effective "$ADMIN")" || die "cannot read the effective sshd config for $ADMIN (is sshd installed?)"
  [ -d "$(dirname "$dest")" ] || priv mkdir -p -- "$(dirname "$dest")"
  if [ -e "$dest" ]; then
    had=1
    backup="$TMP/dropin.backup"
    cp -- "$dest" "$backup"
  fi
  place_file "$new" "$dest" 644
  after="$(sshd_effective "$ADMIN" || true)"
  missing=""
  syntax_ok=1
  priv sshd -t || syntax_ok=0
  if [ "$syntax_ok" -eq 1 ]; then missing="$(deploy_missing)"; fi
  if [ "$syntax_ok" -eq 0 ] || [ "$after" != "$before" ] || [ -n "$missing" ]; then
    if [ "$had" -eq 1 ]; then
      place_file "$backup" "$dest" 644 >/dev/null
    else
      priv rm -f -- "$dest"
    fi
    [ -z "$missing" ] || err "install-deploy-user: the deploy user's effective sshd config lacks (an earlier global setting wins?): $(tr '\n' ';' <<<"$missing")"
    die "sshd -t failed, the administrator's effective sshd config changed, or the deploy user's effective config is not restricted; the previous drop-in state is restored and sshd was not reloaded"
  fi
  reload_sshd
  info "changed: sshd reloaded"
}

do_install() {
  # KEY and FROM were validated in main before dispatch.
  require_privilege
  TMP="$(mktemp -d)"

  payload_platform_sh > "$TMP/platform"
  payload_login_shell_sh > "$TMP/platform-login"
  payload_deploy_sh > "$TMP/deploy.sh"
  payload_validate_app_yaml_sh > "$TMP/validate-app-yaml.sh"
  payload_reserved_names_txt > "$TMP/reserved-names.txt"
  payload_yaml_subset_sh > "$TMP/yaml-subset.sh"
  key_line "$KEY" "$FROM" > "$TMP/key"

  # The install directory belongs to the system (/usr/local/bin): created only if absent, never re-owned.
  [ -d "$(dirname "$ROOT$DISPATCHER_PATH")" ] || priv mkdir -p -- "$(dirname "$ROOT$DISPATCHER_PATH")"
  place_file "$TMP/platform" "$ROOT$DISPATCHER_PATH" 755
  place_file "$TMP/platform-login" "$ROOT$WRAPPER_PATH" 755
  ensure_user
  # The helper tree is root:root, never writable by deploy; the state directory is deploy's own (after ensure_user).
  [ -d "$ROOT/opt/platform" ] || priv mkdir -p -- "$ROOT/opt/platform"
  place_dir "$ROOT$HELPER_DIR" 755
  place_dir "$ROOT$HELPER_REGISTRY_DIR" 755
  place_dir "$ROOT$HELPER_LIB_DIR" 755
  place_file "$TMP/deploy.sh" "$ROOT$HELPER_DIR/deploy.sh" 755
  place_file "$TMP/validate-app-yaml.sh" "$ROOT$HELPER_REGISTRY_DIR/validate-app-yaml.sh" 755
  place_file "$TMP/reserved-names.txt" "$ROOT$HELPER_REGISTRY_DIR/reserved-names.txt" 644
  place_file "$TMP/yaml-subset.sh" "$ROOT$HELPER_LIB_DIR/yaml-subset.sh" 755
  [ -d "$ROOT/var/lib/platform" ] || priv mkdir -p -- "$ROOT/var/lib/platform"
  place_dir "$ROOT$STATE_DIR" 755 "$DEPLOY_USER:$DEPLOY_USER"
  place_dir "$ROOT$KEYS_DIR" 755
  place_file "$TMP/key" "$ROOT$KEY_FILE" 644
  install_dropin
  info "install-deploy-user: done"
}

# ---- status / verify ----

# check_owned <label> <path> <mode>: exists as a regular non-symlink root:root file/dir with exactly this mode.
check_owned() {
  local label="$1" path="$2" mode="$3" owner="${4:-root:root}" meta
  if [ ! -e "$path" ]; then fail "$label missing: $path"; return 1; fi
  if [ -L "$path" ]; then fail "$label is a symlink: $path"; return 1; fi
  meta="$(file_meta "$path")"
  if [ "$meta" = "$owner $mode" ]; then pass "$label owner/mode ($meta)"; else fail "$label owner/mode is '$meta', want '$owner $mode'"; return 1; fi
}

check_payload() {
  local label="$1" path="$2" fn="$3"
  if [ -f "$path" ] && "$fn" | cmp -s - "$path"; then pass "$label bytes equal the embedded payload"; else fail "$label bytes differ from the embedded payload"; fi
}

do_checks() {
  local path entry shell groups uid status eff

  check_owned "dispatcher" "$ROOT$DISPATCHER_PATH" 755 || true
  check_payload "dispatcher" "$ROOT$DISPATCHER_PATH" payload_platform_sh
  check_owned "login wrapper" "$ROOT$WRAPPER_PATH" 755 || true
  check_payload "login wrapper" "$ROOT$WRAPPER_PATH" payload_login_shell_sh
  check_owned "helper directory" "$ROOT$HELPER_DIR" 755 || true
  check_owned "helper registry directory" "$ROOT$HELPER_REGISTRY_DIR" 755 || true
  check_owned "helper lib directory" "$ROOT$HELPER_LIB_DIR" 755 || true
  check_owned "deploy helper" "$ROOT$HELPER_DIR/deploy.sh" 755 || true
  check_payload "deploy helper" "$ROOT$HELPER_DIR/deploy.sh" payload_deploy_sh
  check_owned "app.yaml validator" "$ROOT$HELPER_REGISTRY_DIR/validate-app-yaml.sh" 755 || true
  check_payload "app.yaml validator" "$ROOT$HELPER_REGISTRY_DIR/validate-app-yaml.sh" payload_validate_app_yaml_sh
  check_owned "reserved names" "$ROOT$HELPER_REGISTRY_DIR/reserved-names.txt" 644 || true
  check_payload "reserved names" "$ROOT$HELPER_REGISTRY_DIR/reserved-names.txt" payload_reserved_names_txt
  check_owned "yaml reader" "$ROOT$HELPER_LIB_DIR/yaml-subset.sh" 755 || true
  check_payload "yaml reader" "$ROOT$HELPER_LIB_DIR/yaml-subset.sh" payload_yaml_subset_sh
  check_owned "deploy state directory" "$ROOT$STATE_DIR" 755 "$DEPLOY_USER:$DEPLOY_USER" || true
  check_owned "keys directory" "$ROOT$KEYS_DIR" 755 || true
  check_owned "key file" "$ROOT$KEY_FILE" 644 || true

  path="$ROOT$KEY_FILE"
  if [ -f "$path" ]; then
    local lines=()
    mapfile -t lines < "$path"
    if [ "${#lines[@]}" -eq 1 ] && [[ "${lines[0]}" =~ ^(from=\"${FROM_RE}\",)?restrict,command=\"${DISPATCHER_PATH}\"\ ${KEY_RE}$ ]]; then
      pass "key file is exactly one restrict,command line"
    else
      fail "key file is not exactly one 'restrict,command=\"$DISPATCHER_PATH\" <key>' line"
    fi
  fi

  path="$ROOT$DROPIN"
  check_owned "sshd drop-in" "$path" 644 || true
  if [ -f "$path" ] && render_dropin | cmp -s - "$path"; then pass "sshd drop-in content is the intended directive set"; else fail "sshd drop-in content differs from the intended directive set"; fi

  entry="$(getent passwd "$DEPLOY_USER" || true)"
  if [ -z "$entry" ]; then
    fail "user $DEPLOY_USER does not exist"
  else
    shell="${entry##*:}"
    if [ "$shell" = "$WRAPPER_PATH" ]; then pass "login shell is $WRAPPER_PATH"; else fail "login shell is '$shell', want $WRAPPER_PATH"; fi
    groups=" $(id -nG "$DEPLOY_USER") "
    case "$groups" in *" docker "*) pass "$DEPLOY_USER is in the docker group" ;; *) fail "$DEPLOY_USER is not in the docker group" ;; esac
    case "$groups" in *" sudo "*) fail "$DEPLOY_USER is in the sudo group" ;; *) pass "$DEPLOY_USER is not in the sudo group" ;; esac
    if [ "$(group_set "$DEPLOY_USER")" = "$DEPLOY_USER docker" ]; then pass "$DEPLOY_USER has exactly its own group and docker"; else fail "$DEPLOY_USER is in groups other than its own and docker ($(id -nG "$DEPLOY_USER"))"; fi
    uid="$(id -u "$DEPLOY_USER" 2>/dev/null || true)"
    if [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ne 0 ]; then pass "$DEPLOY_USER uid is nonzero"; else fail "$DEPLOY_USER uid is not a nonzero number ('$uid')"; fi
    status="$(priv passwd -S "$DEPLOY_USER" 2>/dev/null | awk '{print $2}' || true)"
    case "$status" in L | LK) pass "password is locked" ;; *) fail "password is not locked (status '$status')" ;; esac
  fi

  if eff="$(sshd_effective "$DEPLOY_USER" 2>/dev/null)"; then
    local d
    while IFS= read -r d; do
      if grep -qxF "$d" <<<"$eff"; then pass "effective '$d' for $DEPLOY_USER"; else fail "effective '$d' is not set for $DEPLOY_USER"; fi
    done < <(deploy_directives)
  else
    fail "cannot read the effective sshd config for $DEPLOY_USER"
  fi
  if eff="$(sshd_effective "$ADMIN" 2>/dev/null)"; then
    if grep -qF "$KEY_FILE" <<<"$eff"; then fail "the administrator's effective sshd config references the deploy key file"; else pass "administrator's effective sshd config does not reference the deploy key file"; fi
  else
    fail "cannot read the effective sshd config for $ADMIN"
  fi
}

do_report() {
  require_privilege
  do_checks
  if [ "$FAILURES" -gt 0 ]; then
    printf 'install-deploy-user: %d check(s) failed\n' "$FAILURES"
    [ "$1" = "status" ] || exit 1
  else
    printf 'install-deploy-user: all checks passed\n'
  fi
}

# ---- main ----

main() {
  local cmd="install" host="" keyfile="" ADMIN_ARG=""
  KEY=""
  FROM=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      install | status | verify) cmd="$1"; shift ;;
      --host) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "missing value for --host" 2; host="$2"; shift 2 ;;
      --pubkey-file) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "missing value for --pubkey-file" 2; keyfile="$2"; shift 2 ;;
      --key) [ "$#" -ge 2 ] || die "missing value for --key" 2; KEY="$2"; shift 2 ;;
      --from) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "missing value for --from" 2; FROM="$2"; shift 2 ;;
      --admin-user) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "missing value for --admin-user" 2; ADMIN_ARG="$2"; shift 2 ;;
      -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  case "$host" in -*) die "refusing option-looking --host: $host" 2 ;; esac
  if [ -n "$keyfile" ] && [ -n "$KEY" ]; then die "give --pubkey-file or --key, not both" 2; fi
  [ -z "$keyfile" ] || KEY="$(read_key_file "$keyfile")"
  [ -z "$KEY" ] || check_key "$KEY"
  [ -z "$FROM" ] || check_from "$FROM"
  [ -z "$ADMIN_ARG" ] || [[ "$ADMIN_ARG" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "--admin-user must be a plain account name (^[a-z_][a-z0-9_-]{0,31}\$)" 2
  if [ "$cmd" = "install" ] && [ -z "$KEY" ]; then die "install needs --pubkey-file" 2; fi

  if [ -n "$host" ]; then
    local remote="bash -s -- $cmd"
    [ -z "$KEY" ] || remote+=" --key $(printf '%q' "$KEY")"
    [ -z "$FROM" ] || remote+=" --from $(printf '%q' "$FROM")"
    [ -z "$ADMIN_ARG" ] || remote+=" --admin-user $(printf '%q' "$ADMIN_ARG")"
    exec ssh -o BatchMode=yes -- "$host" "$remote" < "${BASH_SOURCE[0]}"
  fi

  ADMIN="${ADMIN_ARG:-$(id -un)}"
  case "$cmd" in
    install) do_install ;;
    status | verify) do_report "$cmd" ;;
  esac
}

main "$@"
exit 0
