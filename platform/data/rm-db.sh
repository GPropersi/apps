#!/bin/bash -p
# rm-db.sh: remove one retired app completely: its containers, registry entry, Redis keys and user, Postgres database and
# role, secret files, deploy state and local images. Installed by install-data.sh to /opt/platform/data/rm-db.sh
# (root:root 0755) and run ONLY from an admin session as root (`make host-app-rm`, over ssh with sudo -n). It is not
# reachable through `platform` or `platform-login`, so a leaked CI credential can never destroy data.
#
# Usage: rm-db.sh <app> --confirm <app> [--stop]
# Exit: 0 done | 1 refused or failed (the phase is named; a re-run converges) | 2 usage error
#
# Remove apps/<name>/ by PR first (so nothing redeploys it), then run this. R2 snapshots keep the data until the
# backup retention prunes them; the jobs-status history stays.
#
# Order (every step is idempotent, so a re-run after a failure at any step completes):
#   1. Name validation (APP_RE, the installed reserved-names list, the Postgres identifier rule), and --confirm must equal
#      the app name. Both refuse before any docker call or file change.
#   2. The per-app lock <lock dir>/<app>.lock, the lock new-db.sh and deploy.sh take (restore.sh's take_app_lock): the lock
#      dir is root-owned and sticky and the deploy user also writes it there, so a missing lock is created with noclobber
#      (O_EXCL, mode 0666) and the lock is taken with flock -n on a READ-ONLY descriptor. A held lock exits 1.
#   3. Containers carrying the platform.app=<app> label (a leftover app-<app>-old counts): refused unless --stop, which
#      removes every one of them first.
#   4. The registry dir (the jobs runner stops scheduling the app).
#   5. Redis: every <app>:* key by admin SCAN plus DEL, then ACL DELUSER and ACL SAVE.
#   6. Postgres: DROP DATABASE ... WITH (FORCE), then DROP ROLE.
#   7. secrets/<app>, job-secrets/<app>, the deploy state and the app's local images (this app's repository only). The
#      secrets go after the data stores so new-db's preflight never sees an object without its secret.
#   8. A final re-scan of everything above: exit 1 naming whatever remains.
# Deletes under the deploy-owned dirs run as the deploy user (runuser), never as root following a deploy-controlled path.
#
# Logging: a timestamped line per phase start and end (rc and duration) on stderr and through `logger -t platform`; docker
# error text is logged. Every docker call runs under `timeout`.
#
# Env overrides (tests only, honoured only with RM_DB_TESTING=1): RM_DB_PG_CONTAINER / RM_DB_REDIS_CONTAINER (default platform-data-postgres /
# platform-data-redis), RM_DB_RESERVED_NAMES (/opt/platform/data/reserved-names.txt), RM_DB_SECRETS_ROOT
# (/var/lib/platform/secrets), RM_DB_JOB_SECRETS_ROOT (/var/lib/platform/job-secrets), RM_DB_STATE_ROOT
# (/var/lib/platform/deploy), RM_DB_REGISTRY_ROOT (/var/lib/platform/registry), RM_DB_LOCK_DIR (/var/lib/platform/locks),
# RM_DB_IMAGE_NS (ghcr.io/gpropersi/apps), RM_DB_REDIS_CTR_ADMIN_FILE (the admin file as the Redis container sees it),
# RM_DB_AS_DEPLOY (the command prefix that runs a delete as the deploy user; default "runuser -u deploy --"),
# RM_DB_EXEC_TIMEOUT (seconds per external call, default 30).
set -euo pipefail

export LC_ALL=C

# The RM_DB_* overrides are test hooks and this script runs as root: they are honoured ONLY with RM_DB_TESTING=1 and are
# otherwise unset (named in a warning, never their values), so a leaked environment cannot redirect a root run or switch
# off the run-as-deploy prefix.
if [ "${RM_DB_TESTING:-}" != "1" ]; then
  dropped=""
  for v in $(compgen -v RM_DB_); do
    unset "$v"
    dropped="$dropped $v"
  done
  if [ -n "$dropped" ]; then echo "WARN: ignoring test overrides without RM_DB_TESTING=1:$dropped" >&2; fi
  unset dropped v
fi

readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
PG="${RM_DB_PG_CONTAINER:-platform-data-postgres}"
REDIS="${RM_DB_REDIS_CONTAINER:-platform-data-redis}"
RESERVED_FILE="${RM_DB_RESERVED_NAMES:-/opt/platform/data/reserved-names.txt}"
SECRETS_ROOT="${RM_DB_SECRETS_ROOT:-/var/lib/platform/secrets}"
JOB_SECRETS_ROOT="${RM_DB_JOB_SECRETS_ROOT:-/var/lib/platform/job-secrets}"
STATE_ROOT="${RM_DB_STATE_ROOT:-/var/lib/platform/deploy}"
REGISTRY_ROOT="${RM_DB_REGISTRY_ROOT:-/var/lib/platform/registry}"
LOCK_DIR="${RM_DB_LOCK_DIR:-/var/lib/platform/locks}"
IMAGE_NS="${RM_DB_IMAGE_NS:-ghcr.io/gpropersi/apps}"
REDIS_CTR_ADMIN_FILE="${RM_DB_REDIS_CTR_ADMIN_FILE:-/etc/platform/redis-admin.password}"
EXEC_TIMEOUT="${RM_DB_EXEC_TIMEOUT:-30}"
DEPLOY_PREFIX="${RM_DB_AS_DEPLOY-runuser -u deploy --}"

# Runs redis-cli as the admin user inside the Redis container; identical to new-db.sh's REDIS_ADMIN_SNIPPET (a test
# compares the copies). The password is read from the mounted file inside the container, one trailing newline stripped,
# and handed over through REDISCLI_AUTH: never in an argv.
# shellcheck disable=SC2016 # expanded by the shell inside the container
readonly REDIS_ADMIN_SNIPPET='f="$1"; shift; pw="$(cat "$f"; printf x)"; pw="${pw%x}"; nl="$(printf "\nx")"; nl="${nl%x}"; case "$pw" in *"$nl") pw="${pw%"$nl"}" ;; esac; REDISCLI_AUTH="$pw" exec redis-cli --user admin --no-auth-warning "$@"'

# One SCAN page per call: deletes (or only counts) the keys of one app. Prints the next cursor, then the page's key count.
# Double quotes outside, single quotes inside: redis-cli splits the line like a shell would.
# shellcheck disable=SC2016
readonly SCAN_SCRIPT="local r=redis.call('SCAN',ARGV[1],'MATCH',ARGV[2],'COUNT',1000) local n=0 for _,k in ipairs(r[2]) do if ARGV[3]=='del' then redis.call('DEL',k) end n=n+1 end return {r[1],n}"

APP=""
CONFIRM=""
STOP=0
PGROLE=""
ERRF=""
LOCKFD=""
PHASE_OUT=""
IMAGE_REPO=""
DEPLOY_RUN=()

info() { printf '%s\n' "$1"; }
err() { printf '%s\n' "$1" >&2; }

log() {
  printf '%s rm-db app=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${APP:-?}" "$*" >&2
  logger -t platform -- "rm-db app=${APP:-?} $*" 2>/dev/null || true
}

# die <message> [rc]: a refusal (nothing was changed by this step).
die() {
  err "rm-db: $1"
  log "refused: $1"
  exit "${2:-1}"
}

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
cleanup() {
  [ -z "$ERRF" ] || rm -f -- "$ERRF"
  return 0
}
trap cleanup EXIT

# phase <name> <stdin text> <cmd...>: runs the command under timeout with the text on stdin; sets PHASE_OUT to stdout.
# A non-zero rc (124 = timeout) exits 1 naming the phase.
phase() {
  local name="$1" input="$2" rc=0 start errtext
  shift 2
  log "phase=$name start"
  start=$SECONDS
  : >"$ERRF"
  PHASE_OUT="$(timeout "$EXEC_TIMEOUT" "$@" 2>"$ERRF" <<<"$input")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    errtext="$(head -c 2000 "$ERRF" | tr '\n' ' ')"
    if [ "$rc" -eq 124 ]; then
      log "phase=$name end rc=124 dur=$((SECONDS - start))s FAILED timed out after ${EXEC_TIMEOUT}s"
    else
      log "phase=$name end rc=$rc dur=$((SECONDS - start))s FAILED err=${errtext:-none}"
    fi
    err "rm-db: phase '$name' failed (rc $rc); fix the cause and re-run, it converges. Removal may be partial."
    exit 1
  fi
  log "phase=$name end rc=0 dur=$((SECONDS - start))s"
}

pg_phase() { # <name> <db> <sql>
  phase "$1" "$3" docker exec -i "$PG" psql -X -U postgres -d "$2" -At -v ON_ERROR_STOP=1
}

redis_phase() { # <name> <command text>
  phase "$1" "$2" docker exec -i "$REDIS" sh -c "$REDIS_ADMIN_SNIPPET" sh "$REDIS_CTR_ADMIN_FILE"
}

# ---- 1. arguments and name validation (before any docker call or file change) ----

parse_args() {
  [ "$#" -ge 1 ] || { err "usage: rm-db.sh <app> --confirm <app> [--stop]"; exit 2; }
  APP="$1"
  shift
  local have_confirm=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --confirm)
        [ "$#" -ge 2 ] && [ "$have_confirm" -eq 0 ] || { err "usage: rm-db.sh <app> --confirm <app> [--stop]"; exit 2; }
        CONFIRM="$2"
        have_confirm=1
        shift 2
        ;;
      --stop)
        STOP=1
        shift
        ;;
      *)
        err "usage: rm-db.sh <app> --confirm <app> [--stop]"
        exit 2
        ;;
    esac
  done
  [ "$have_confirm" -eq 1 ] || { err "rm-db: --confirm <app> is required: type the app name again to confirm the removal"; exit 2; }
  [[ "$EXEC_TIMEOUT" =~ ^[0-9]+$ ]] || { err "rm-db: RM_DB_EXEC_TIMEOUT must be a whole number of seconds"; exit 2; }
}

validate_name() {
  local line reserved=""
  [[ "$APP" =~ $APP_RE ]] || die "invalid app name (want $APP_RE)" 1
  [ "$CONFIRM" = "$APP" ] || die "--confirm '$CONFIRM' does not match the app name '$APP'; nothing was changed" 1
  if [ ! -r "$RESERVED_FILE" ] || [ ! -f "$RESERVED_FILE" ]; then
    die "the reserved-names list is missing or unreadable ($RESERVED_FILE): run \`make host-data HOST=<alias> ARGS=install\`" 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in '' | '#'*) continue ;; esac
    reserved+="$line"$'\n'
    [ "$line" != "$APP" ] || die "the name '$APP' is reserved (a platform object, never an app)" 1
  done <"$RESERVED_FILE"
  [ -n "$reserved" ] || die "the reserved-names list has no entries ($RESERVED_FILE): run \`make host-data HOST=<alias> ARGS=install\`" 1
  PGROLE="${APP//-/_}"
  case "$PGROLE" in
    pg_* | postgres | template0 | template1 | public) die "the name '$APP' maps to the refused Postgres identifier '$PGROLE'" 1 ;;
    *) ;;
  esac
  IMAGE_REPO="$IMAGE_NS/$APP"
  if [ -n "$DEPLOY_PREFIX" ]; then read -r -a DEPLOY_RUN <<<"$DEPLOY_PREFIX"; fi
}

# ---- 2. lock ----

take_lock() {
  local lock root
  for root in "$SECRETS_ROOT" "$JOB_SECRETS_ROOT" "$STATE_ROOT" "$REGISTRY_ROOT"; do
    [ -d "$root" ] && [ ! -L "$root" ] || die "the root $root is missing or not a directory: run the installers (host-data, host-deploy-user, host-jobs)" 1
  done
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || die "the lock directory $LOCK_DIR is missing or not a directory: run \`make host-data HOST=<alias> ARGS=install\`" 1
  lock="$LOCK_DIR/$APP.lock"
  [ ! -L "$lock" ] || die "the lock path $lock is a symlink" 1
  # The lock dir is sticky (the deploy user creates its own lock files there), so root never opens one with O_CREAT: a
  # missing lock is created with noclobber (O_EXCL, never follows a symlink; mode 0666 so the deploy user can still open
  # it for append) and the lock is then taken on a READ-ONLY descriptor (flock needs no write access).
  if [ ! -e "$lock" ]; then (umask 0111 && set -o noclobber && : >"$lock") 2>/dev/null || true; fi
  [ -f "$lock" ] && [ ! -L "$lock" ] || die "the lock path $lock is not a regular file" 1
  exec {LOCKFD}<"$lock" || die "cannot open $lock" 1
  log "phase=lock start"
  if ! flock -n "$LOCKFD"; then
    log "phase=lock end rc=1 FAILED another operation holds $lock"
    err "rm-db: another operation (new-db, deploy, restore or rm-db) holds the lock for '$APP'. Nothing was changed."
    exit 1
  fi
  log "phase=lock end rc=0"
}

# ---- health (after the lock, before the steps; a precondition of steps 1-2, not a numbered step) ----

check_healthy() {
  local name
  for name in "$PG" "$REDIS"; do
    phase "health-$name" "" docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name"
    if [ "$PHASE_OUT" != "running|healthy" ]; then
      log "container $name is not healthy (${PHASE_OUT//[^A-Za-z0-9|_-]/?})"
      err "rm-db: phase 'health' failed: container $name is not running and healthy. Nothing was changed."
      exit 1
    fi
  done
}

# ---- steps 3-7 ----

# labelled_containers: sets PHASE_OUT to the names of every container (any state) with this app's label.
labelled_containers() {
  phase "$1" "" docker ps -a --filter "label=platform.app=$APP" --format '{{.Names}}'
}

# step 3
step_containers() {
  local name found
  labelled_containers "containers-list"
  found="$PHASE_OUT"
  [ -n "$found" ] || { info "already: no container labelled platform.app=$APP"; return 0; }
  if [ "$STOP" -eq 0 ]; then
    err "rm-db: containers carry the label platform.app=$APP:"
    while IFS= read -r name; do err "  $name"; done <<<"$found"
    die "refusing to remove an app that has containers (a leftover app-$APP-old counts); re-run with --stop to remove them first. Nothing was changed." 1
  fi
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    phase "container-rm" "" docker rm -f -v -- "$name"
    info "removed: container $name"
  done <<<"$found"
}

# step 4
step_registry() {
  phase "registry-rm" "" "${DEPLOY_RUN[@]}" rm -rf -- "$REGISTRY_ROOT/$APP"
  info "removed: $REGISTRY_ROOT/$APP"
}

# redis_scan <del|count>: walks every page of the app's keys; sets SCAN_TOTAL to the number of keys seen.
redis_scan() {
  local mode="$1" cursor="0" n guard=0
  SCAN_TOTAL=0
  while :; do
    redis_phase "redis-scan-$mode" "EVAL \"$SCAN_SCRIPT\" 0 $cursor $APP:* $mode"
    cursor="$(sed -n '1p' <<<"$PHASE_OUT")"
    n="$(sed -n '2p' <<<"$PHASE_OUT")"
    if ! [[ "$cursor" =~ ^[0-9]+$ ]] || ! [[ "$n" =~ ^[0-9]+$ ]]; then
      log "phase=redis-scan-$mode unexpected reply"
      err "rm-db: phase 'redis-scan-$mode' failed: Redis did not return a cursor and a count (admin auth failed or Redis is loading)."
      exit 1
    fi
    SCAN_TOTAL=$((SCAN_TOTAL + n))
    [ "$cursor" != "0" ] || break
    guard=$((guard + 1))
    [ "$guard" -lt 1000000 ] || { err "rm-db: the Redis scan did not finish"; exit 1; }
  done
}

# step 5
step_redis() {
  redis_scan del
  info "removed: $SCAN_TOTAL Redis key(s) matching $APP:*"
  redis_phase "redis-acl-deluser" "ACL DELUSER $APP"
  [[ "$PHASE_OUT" =~ ^[01]$ ]] || { log "phase=redis-acl-deluser unexpected reply"; err "rm-db: phase 'redis-acl-deluser' failed: Redis did not reply 0 or 1. Re-run to converge."; exit 1; }
  redis_phase "redis-acl-save" "ACL SAVE"
  [ "$PHASE_OUT" = "OK" ] || { log "phase=redis-acl-save unexpected reply"; err "rm-db: phase 'redis-acl-save' failed: Redis did not reply OK. Re-run to converge."; exit 1; }
  info "removed: Redis user $APP"
}

# step 6
step_postgres() {
  pg_phase "postgres-drop-database" postgres "DROP DATABASE IF EXISTS \"$PGROLE\" WITH (FORCE);"
  pg_phase "postgres-drop-role" postgres "DROP ROLE IF EXISTS \"$PGROLE\";"
  info "removed: Postgres database and role $PGROLE"
}

# app_images: sets PHASE_OUT to "<id> <repo> <tag> <digest>" lines for this app's repository only.
app_images() {
  local line id repo tag dig out=""
  phase "$1" "" docker image ls --no-trunc --digests --format '{{.ID}} {{.Repository}} {{.Tag}} {{.Digest}}' "$IMAGE_REPO"
  while read -r id repo tag dig; do
    [ -n "$id" ] && [ "$repo" = "$IMAGE_REPO" ] || continue
    out+="$id $repo $tag $dig"$'\n'
  done <<<"$PHASE_OUT"
  line="${out%$'\n'}"
  PHASE_OUT="$line"
}

# step 7
step_files_and_images() {
  local p id repo tag dig ref listing
  for p in "$SECRETS_ROOT/$APP" "$JOB_SECRETS_ROOT/$APP" "$STATE_ROOT/$APP"; do
    phase "files-rm" "" "${DEPLOY_RUN[@]}" rm -rf -- "$p"
    info "removed: $p"
  done
  app_images "images-list"
  listing="$PHASE_OUT"
  while read -r id repo tag dig; do
    [ -n "$id" ] || continue
    if [ "$tag" != "<none>" ]; then
      ref="$repo:$tag"
    elif [ "$dig" != "<none>" ]; then
      ref="$repo@$dig"
    else
      continue # neither a tag nor a digest: cannot be named without touching every tag of the ID
    fi
    # A failure is judged by the final re-scan (an image already gone through a sibling tag is not an error).
    log "phase=image-rm start ref=$ref"
    if timeout "$EXEC_TIMEOUT" docker rmi -- "$ref" 2>"$ERRF" >/dev/null; then
      log "phase=image-rm end rc=0"
      info "removed: image $ref"
    else
      log "phase=image-rm end rc=1 err=$(head -c 500 "$ERRF" | tr '\n' ' ')"
    fi
  done <<<"$listing"
}

# ---- 8. final re-scan ----

final_scan() {
  local left="" p users pgout roles dbs
  labelled_containers "final-containers"
  [ -z "$PHASE_OUT" ] || left+="containers: ${PHASE_OUT//$'\n'/ }"$'\n'
  for p in "$REGISTRY_ROOT/$APP" "$SECRETS_ROOT/$APP" "$JOB_SECRETS_ROOT/$APP" "$STATE_ROOT/$APP"; do
    if [ -e "$p" ] || [ -L "$p" ]; then left+="path: $p"$'\n'; fi
  done
  redis_scan count
  [ "$SCAN_TOTAL" -eq 0 ] || left+="redis keys: $SCAN_TOTAL matching $APP:*"$'\n'
  redis_phase "final-redis-users" "ACL USERS"
  users="$PHASE_OUT"
  grep -qxF -- "admin" <<<"$users" || { err "rm-db: phase 'final-redis-users' failed: Redis did not return its user list."; exit 1; }
  if grep -qxF -- "$APP" <<<"$users"; then left+="redis user: $APP"$'\n'; fi
  pg_phase "final-postgres" postgres "SELECT (SELECT count(*) FROM pg_roles WHERE rolname = '$PGROLE') || '|' || (SELECT count(*) FROM pg_database WHERE datname = '$PGROLE');"
  pgout="$PHASE_OUT"
  if ! [[ "$pgout" =~ ^([0-9]+)\|([0-9]+)$ ]]; then
    err "rm-db: phase 'final-postgres' failed: unexpected reply from psql."
    exit 1
  fi
  roles="${BASH_REMATCH[1]}"
  dbs="${BASH_REMATCH[2]}"
  [ "$roles" -eq 0 ] || left+="postgres role: $PGROLE"$'\n'
  [ "$dbs" -eq 0 ] || left+="postgres database: $PGROLE"$'\n'
  app_images "final-images"
  [ -z "$PHASE_OUT" ] || left+="images: ${PHASE_OUT//$'\n'/; }"$'\n'
  if [ -n "$left" ]; then
    log "FAILED final re-scan: something remains"
    err "rm-db: the final re-scan found what is left of '$APP':"
    while IFS= read -r p; do [ -z "$p" ] || err "  $p"; done <<<"$left"
    err "rm-db: fix the cause and re-run; each step is idempotent."
    exit 1
  fi
}

main() {
  parse_args "$@"
  validate_name
  log "start stop=$STOP"
  take_lock
  ERRF="$(mktemp)"
  check_healthy
  step_containers
  step_registry
  step_redis
  step_postgres
  step_files_and_images
  final_scan
  log "end rc=0"
  info "rm-db: done $APP (R2 snapshots keep its data until the backup retention prunes them; jobs-status history stays)"
}

main "$@"
