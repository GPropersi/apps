#!/bin/bash -p
# notifs-key.sh: store one app's 4irl-notifs key set in its host-side secrets directory. Installed by install-data.sh to
# /opt/platform/data/notifs-key.sh (root:root 0755) and run by the `platform notifs-key <app>` dispatcher as the deploy
# user (the same user and secrets root as new-db.sh).
#
# Usage: notifs-key.sh <app>      (stdin: 4 lines - key, access client id, access client secret, base URL)
# Exit: 0 written | 1 refused or failed | 2 usage error. A refusal writes nothing and leaves an existing key set untouched.
# A failure during the final rename phase names the failing file and may leave new credentials beside the old key (the key
# is renamed last); the next successful run converges.
#
# Files, in <secrets root>/<app>/ (mode 0440 via umask 227, group inherited from the setgid secrets root, so no chgrp or
# chmod runs): notifs-key, notifs-access-client-id, notifs-access-client-secret, notifs-base-url. Every file is written to
# a temp file in the same directory first and then renamed; the key is renamed last, so a reader that sees a new key
# always finds the matching credentials already in place.
#
# Refuses (non-zero, nothing written): a name failing the app-name rule, an app with no registry entry (it has never
# deployed), a registry app.yaml without `notifs: true`, a key not matching ^dak_[A-Za-z0-9_-]{43}$, a base URL that is
# not https://, an empty or whitespace-bearing client id or secret, a missing or symlinked secrets directory, a stdin that
# is not exactly 4 lines or does not arrive within the timeout.
#
# Output: only sha256(key) on stdout. The key and the client credentials never appear in an argv, a log line or an error.
#
# Logging: a timestamped line per phase start and end (rc and duration) on stderr and through `logger -t platform`.
#
# Env overrides (tests only; the dispatcher runs this script with a scrubbed environment):
# NOTIFS_KEY_SECRETS_ROOT (default /var/lib/platform/secrets), NOTIFS_KEY_REGISTRY_ROOT (default
# /var/lib/platform/registry), NOTIFS_KEY_LOCK_DIR (default /var/lib/platform/locks), NOTIFS_KEY_LOCK_WAIT (seconds,
# default 30), NOTIFS_KEY_STDIN_TIMEOUT (seconds per stdin line, default 10).
set -euo pipefail

export LC_ALL=C

readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
readonly KEY_RE='^dak_[A-Za-z0-9_-]{43}$'
readonly CRED_RE='^[^[:space:]]{1,512}$'
readonly URL_RE='^https://[^[:space:]]{1,500}$'
SECRETS_ROOT="${NOTIFS_KEY_SECRETS_ROOT:-/var/lib/platform/secrets}"
REGISTRY_ROOT="${NOTIFS_KEY_REGISTRY_ROOT:-/var/lib/platform/registry}"
LOCK_DIR="${NOTIFS_KEY_LOCK_DIR:-/var/lib/platform/locks}"
LOCK_WAIT="${NOTIFS_KEY_LOCK_WAIT:-30}"
STDIN_TIMEOUT="${NOTIFS_KEY_STDIN_TIMEOUT:-10}"

APP=""
APPDIR=""
LOCKFD=""
START=$SECONDS
TMPFILES=()

err() { printf '%s\n' "$1" >&2; }

log() {
  printf '%s notifs-key app=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${APP:-?}" "$*" >&2
  logger -t platform -- "notifs-key app=${APP:-?} $*" 2>/dev/null || true
}

# die <message>: a refusal; nothing was written (or, after the rename phase started, the failed step is named).
die() {
  err "notifs-key: $1"
  log "refused: $1 dur=$((SECONDS - START))s"
  exit 1
}

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
cleanup() {
  local f
  for f in "${TMPFILES[@]}"; do rm -f -- "$f"; done
  return 0
}
trap cleanup EXIT

# read_input: the 4 stdin lines into KEY, CID, CSEC, BASE. Each read is bounded by STDIN_TIMEOUT; a fifth line refuses.
read_input() {
  local extra
  log "phase=stdin start timeout=${STDIN_TIMEOUT}s"
  IFS= read -r -t "$STDIN_TIMEOUT" KEY || die "stdin did not deliver the key line (missing or timed out)"
  IFS= read -r -t "$STDIN_TIMEOUT" CID || die "stdin did not deliver the access client id line"
  IFS= read -r -t "$STDIN_TIMEOUT" CSEC || die "stdin did not deliver the access client secret line"
  IFS= read -r -t "$STDIN_TIMEOUT" BASE || die "stdin did not deliver the base URL line"
  extra=""
  if IFS= read -r -t 1 extra; then
    die "stdin carries more than 4 lines"
  elif [ -n "$extra" ]; then
    die "stdin carries more than 4 lines (unterminated fifth line)"
  fi
  log "phase=stdin end rc=0"
}

validate_input() {
  [[ "$KEY" =~ $KEY_RE ]] || die "the key is not a dak_ key (want $KEY_RE)"
  [[ "$CID" =~ $CRED_RE ]] || die "the access client id is empty or malformed"
  [[ "$CSEC" =~ $CRED_RE ]] || die "the access client secret is empty or malformed"
  [[ "$BASE" =~ $URL_RE ]] || die "the base URL must start with https://"
}

# check_registry: the app has deployed (registry entry exists) and its registry app.yaml opts in with notifs: true.
check_registry() {
  local dir="$REGISTRY_ROOT/$APP" f
  [ -d "$REGISTRY_ROOT" ] && [ ! -L "$REGISTRY_ROOT" ] || die "the registry root is missing or not a directory"
  [ -d "$dir" ] && [ ! -L "$dir" ] || die "app '$APP' has no registry entry (it has never deployed)"
  f="$dir/app.yaml"
  [ -f "$f" ] && [ ! -L "$f" ] || die "app '$APP' has no registry app.yaml"
  [ "$(grep -c '^notifs:' "$f" || true)" = "1" ] || die "app '$APP' must have exactly one notifs: line in its registry app.yaml"
  grep -qxE 'notifs:[[:space:]]+true[[:space:]]*' "$f" || die "app '$APP' does not declare notifs: true"
}

take_lock() {
  local lock old
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || die "the lock directory $LOCK_DIR is missing or not a directory: run \`make host-data HOST=<alias> ARGS=install\`"
  lock="$LOCK_DIR/$APP.lock"
  [ ! -L "$lock" ] || die "the lock path $lock is a symlink"
  old="$(umask)"
  umask 077
  { exec {LOCKFD}>>"$lock"; } 2>/dev/null || { umask "$old"; die "cannot open the lock file $lock"; }
  umask "$old"
  log "phase=lock start wait=${LOCK_WAIT}s"
  if ! flock -w "$LOCK_WAIT" "$LOCKFD"; then
    die "another operation for '$APP' holds the lock after ${LOCK_WAIT}s"
  fi
  log "phase=lock end rc=0"
}

# stage <name> <value>: a temp file in the app directory (umask 227 gives 0440), named by name and pid.
stage() {
  local name="$1" value="$2" tmp
  tmp="$APPDIR/.tmp.$name.$$"
  TMPFILES+=("$tmp")
  (
    umask 227
    set -C
    printf '%s' "$value" >"$tmp"
  ) || die "cannot write a temp file in $APPDIR"
}

# place <name>: atomic rename of the staged temp file over the secret.
place() {
  mv -f -- "$APPDIR/.tmp.$1.$$" "$APPDIR/$1" || die "cannot move $1 into place in $APPDIR (rename phase failed; new credentials may sit beside the old key, rerun to converge)"
}

write_files() {
  local n
  log "phase=write start"
  [ -d "$APPDIR" ] && [ ! -L "$APPDIR" ] || die "the secrets directory for '$APP' is missing or a symlink: run \`platform new-db $APP\` first"
  for n in notifs-key notifs-access-client-id notifs-access-client-secret notifs-base-url; do
    [ ! -L "$APPDIR/$n" ] || die "secret path $APPDIR/$n is a symlink"
    [ ! -e "$APPDIR/$n" ] || [ -f "$APPDIR/$n" ] || die "secret path $APPDIR/$n is not a regular file"
  done
  stage notifs-key "$KEY"
  stage notifs-access-client-id "$CID"
  stage notifs-access-client-secret "$CSEC"
  stage notifs-base-url "$BASE"
  # The key last: a reader that sees the new key finds the matching credentials already in place.
  place notifs-access-client-id
  place notifs-access-client-secret
  place notifs-base-url
  place notifs-key
  log "phase=write end rc=0"
}

main() {
  [ "$#" -eq 1 ] || { err "usage: notifs-key.sh <app>"; exit 2; }
  APP="$1"
  [[ "$LOCK_WAIT" =~ ^[0-9]+$ ]] || { err "notifs-key: NOTIFS_KEY_LOCK_WAIT must be a whole number of seconds"; exit 2; }
  [[ "$STDIN_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || { err "notifs-key: NOTIFS_KEY_STDIN_TIMEOUT must be a positive whole number of seconds"; exit 2; }
  [[ "$APP" =~ $APP_RE ]] || { err "notifs-key: invalid app name (want $APP_RE)"; exit 2; }
  APPDIR="$SECRETS_ROOT/$APP"
  log "start"
  read_input
  validate_input
  check_registry
  take_lock
  # Re-check under the lock: the registry entry may have changed while waiting.
  check_registry
  write_files
  log "end rc=0 dur=$((SECONDS - START))s"
  printf '%s\n' "$(printf '%s' "$KEY" | sha256sum | cut -d' ' -f1)"
}

main "$@"
