#!/bin/bash -p
# new-db.sh: give one app its own Postgres database and login and its own Redis user, with the credentials written to
# host-side secret files. Installed by install-data.sh to /opt/platform/data/new-db.sh (root:root 0755) and run by the
# `platform new-db <app>` dispatcher as the deploy user (Docker access, no sudo).
#
# Usage: new-db.sh <app>
# Exit: 0 done | 1 refused or failed (the phase is named; nothing half-written) | 2 usage error
#
# What it does, in this order (each phase refuses before changing anything):
#   1. Validates the name (APP_RE, the installed reserved-names list, the Postgres identifier rule) before any docker
#      call or file write. A missing or unreadable list fails closed.
#   2. Takes the per-app lock <lock dir>/<app>.lock (flock, bounded wait); the lock dir is root-owned and sticky
#      (made by install-data.sh), shared with the restore script, which takes the same lock as root.
#   3. Checks both containers are healthy.
#   4. Read-only preflight: classifies the Postgres role/database and the Redis user against their two secret files. An
#      object present with its secret file absent exits 1 before anything is written (no silent password reset).
#   5. Per store: writes the secret file first (atomically), then creates the object, then re-applies every idempotent
#      statement so drift is repaired. A second run prints only "already:" lines and changes no password.
#
# Secrets: <secrets root>/<app>/{db-password,redis-password}, 40 characters [A-Za-z0-9] from /dev/urandom. The secrets
# root is deploy:64323 with the setgid bit (made by install-data.sh), so everything created inside inherits group 64323
# and this script never calls chgrp or chmod for the group (deploy is not a member of it). A password never appears in
# an argv, in stdout, in a log line or in the Postgres container log: SQL and ACL commands go to the container on stdin,
# the Redis admin password is read inside the container from the mounted admin file (one trailing newline stripped,
# as the entrypoint's hash does) and reaches redis-cli only through REDISCLI_AUTH.
#
# Logging: a timestamped line per phase start and end (rc and duration) on stderr and through `logger -t platform`;
# error text from docker is logged with both of the app's passwords masked. Every docker call runs under `timeout`.
#
# Needs bash >= 5.1 (a here-string then travels through a pipe, not a temp file holding a password). A docker call
# that times out kills only the docker client: the psql or redis-cli process may finish inside the container later;
# every statement is idempotent, so a re-run converges.
#
# Env overrides (tests only; the dispatcher runs this script with a scrubbed environment):
# NEW_DB_PG_CONTAINER / NEW_DB_REDIS_CONTAINER (default platform-data-postgres / platform-data-redis),
# NEW_DB_RESERVED_NAMES (default /opt/platform/data/reserved-names.txt), NEW_DB_SECRETS_ROOT
# (default /var/lib/platform/secrets), NEW_DB_LOCK_DIR (default /var/lib/platform/locks), NEW_DB_REDIS_CTR_ADMIN_FILE (the admin file as the Redis container sees it),
# NEW_DB_LOCK_WAIT (seconds, default 30), NEW_DB_EXEC_TIMEOUT (seconds per docker call, default 30).
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
  echo "new-db: needs bash >= 5.1" >&2
  exit 1
fi

export LC_ALL=C

readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
readonly PW_RE='^[A-Za-z0-9]{20,128}$'
readonly PW_LEN=40
PG="${NEW_DB_PG_CONTAINER:-platform-data-postgres}"
REDIS="${NEW_DB_REDIS_CONTAINER:-platform-data-redis}"
RESERVED_FILE="${NEW_DB_RESERVED_NAMES:-/opt/platform/data/reserved-names.txt}"
SECRETS_ROOT="${NEW_DB_SECRETS_ROOT:-/var/lib/platform/secrets}"
LOCK_DIR="${NEW_DB_LOCK_DIR:-/var/lib/platform/locks}"
REDIS_CTR_ADMIN_FILE="${NEW_DB_REDIS_CTR_ADMIN_FILE:-/etc/platform/redis-admin.password}"
LOCK_WAIT="${NEW_DB_LOCK_WAIT:-30}"
EXEC_TIMEOUT="${NEW_DB_EXEC_TIMEOUT:-30}"

# Runs redis-cli as the admin user inside the Redis container; identical to install-data.sh's REDIS_ADMIN_SNIPPET (a
# test compares the two). The password is read from the mounted file inside the container, one trailing newline
# stripped, and handed over through REDISCLI_AUTH: never in an argv.
# shellcheck disable=SC2016 # expanded by the shell inside the container
readonly REDIS_ADMIN_SNIPPET='f="$1"; shift; pw="$(cat "$f"; printf x)"; pw="${pw%x}"; nl="$(printf "\nx")"; nl="${nl%x}"; case "$pw" in *"$nl") pw="${pw%"$nl"}" ;; esac; REDISCLI_AUTH="$pw" exec redis-cli --user admin --no-auth-warning "$@"'

APP=""
PGROLE=""
DB_PW=""
REDIS_PW=""
APPDIR=""
ERRF=""
LOCKFD=""
PHASE_OUT=""
TMPFILES=()

info() { printf '%s\n' "$1"; }
err() { printf '%s\n' "$1" >&2; }

# mask <text>: the text with both of the app's passwords (when known) replaced.
mask() {
  local s="$1" p
  for p in "$DB_PW" "$REDIS_PW"; do
    [ -z "$p" ] || s="${s//"$p"/***}"
  done
  printf '%s' "$s"
}

log() {
  printf '%s new-db app=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${APP:-?}" "$*" >&2
  logger -t platform -- "new-db app=${APP:-?} $*" 2>/dev/null || true
}

# die <message> [rc]: a refusal before any phase ran (nothing was written).
die() {
  err "new-db: $1"
  log "refused: $1"
  exit "${2:-1}"
}

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
cleanup() {
  local f
  for f in "${TMPFILES[@]}"; do rm -f -- "$f"; done
  [ -z "$ERRF" ] || rm -f -- "$ERRF"
  return 0
}
trap cleanup EXIT

# phase <name> <stdin text> <cmd...>: runs the command under timeout with the text on stdin; sets PHASE_OUT to stdout.
# A non-zero rc (124 = timeout) exits 1 naming the phase, with docker's error text masked in the log.
phase() {
  local name="$1" input="$2" rc=0 start errtext
  shift 2
  log "phase=$name start"
  start=$SECONDS
  : >"$ERRF"
  PHASE_OUT="$(timeout "$EXEC_TIMEOUT" "$@" 2>"$ERRF" <<<"$input")" || rc=$?
  if [ "$rc" -ne 0 ]; then
    # Mask the whole text first and truncate afterwards: a password cut at the boundary would no longer match.
    errtext="$(mask "$(head -c 1000000 "$ERRF" | tr '\n' ' ')")"
    errtext="${errtext:0:2000}"
    if [ "$rc" -eq 124 ]; then
      log "phase=$name end rc=124 dur=$((SECONDS - start))s FAILED timed out after ${EXEC_TIMEOUT}s"
    else
      log "phase=$name end rc=$rc dur=$((SECONDS - start))s FAILED err=${errtext:-none}"
    fi
    err "new-db: phase '$name' failed (rc $rc); re-run to converge. Nothing is left half-written."
    exit 1
  fi
  log "phase=$name end rc=0 dur=$((SECONDS - start))s"
}

pg_run() { # <db>
  printf '%s\0' docker exec -i "$PG" psql -X -U postgres -d "$1" -At -v ON_ERROR_STOP=1
}

redis_run() {
  printf '%s\0' docker exec -i "$REDIS" sh -c "$REDIS_ADMIN_SNIPPET" sh "$REDIS_CTR_ADMIN_FILE"
}

# pg_phase <name> <db> <sql>
pg_phase() {
  local -a cmd
  mapfile -d '' -t cmd < <(pg_run "$2")
  phase "$1" "$3" "${cmd[@]}"
}

# redis_phase <name> <command text>
redis_phase() {
  local -a cmd
  mapfile -d '' -t cmd < <(redis_run)
  phase "$1" "$2" "${cmd[@]}"
}

# ---- 1. name validation (before any docker call or file write) ----

validate_name() {
  local line reserved=""
  [[ "$APP" =~ $APP_RE ]] || die "invalid app name (want $APP_RE)" 1
  if [ ! -r "$RESERVED_FILE" ] || [ ! -f "$RESERVED_FILE" ]; then
    die "the reserved-names list is missing or unreadable ($RESERVED_FILE): run \`make host-data HOST=<alias> ARGS=install\`" 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    case "$line" in '' | '#'*) continue ;; esac
    reserved+="$line"$'\n'
    [ "$line" != "$APP" ] || die "the name '$APP' is reserved" 1
  done <"$RESERVED_FILE"
  [ -n "$reserved" ] || die "the reserved-names list has no entries ($RESERVED_FILE): run \`make host-data HOST=<alias> ARGS=install\`" 1
  PGROLE="${APP//-/_}"
  case "$PGROLE" in
    pg_* | postgres | template0 | template1 | public) die "the name '$APP' maps to the refused Postgres identifier '$PGROLE'" 1 ;;
    *) ;;
  esac
}

# ---- 2. lock ----

take_lock() {
  local lock old
  [ -d "$SECRETS_ROOT" ] && [ ! -L "$SECRETS_ROOT" ] || die "the secrets root $SECRETS_ROOT is missing or not a directory: run \`make host-data HOST=<alias> ARGS=install\`" 1
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || die "the lock directory $LOCK_DIR is missing or not a directory: run \`make host-data HOST=<alias> ARGS=install\`" 1
  lock="$LOCK_DIR/$APP.lock"
  [ ! -L "$lock" ] || die "the lock path $lock is a symlink" 1
  # Created under umask 077 and opened for append: the owner can always reopen it for the next run.
  old="$(umask)"
  umask 077
  exec {LOCKFD}>>"$lock"
  umask "$old"
  log "phase=lock start wait=${LOCK_WAIT}s"
  if ! flock -w "$LOCK_WAIT" "$LOCKFD"; then
    log "phase=lock end rc=1 FAILED another new-db for this app holds $lock"
    err "new-db: phase 'lock' failed: another new-db for '$APP' holds the lock after ${LOCK_WAIT}s. Nothing was written."
    exit 1
  fi
  log "phase=lock end rc=0"
}

# ---- 3. health ----

check_healthy() {
  local name
  for name in "$PG" "$REDIS"; do
    phase "health-$name" "" docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name"
    if [ "$PHASE_OUT" != "running|healthy" ]; then
      log "container $name is not healthy (${PHASE_OUT//[^A-Za-z0-9|_-]/?})"
      err "new-db: phase 'health' failed: container $name is not running and healthy. Nothing was written."
      exit 1
    fi
  done
}

# ---- 4. preflight ----

PG_ROLES=0
PG_DBS=0
RD_PRESENT=0
S_DB=0
S_RD=0

# secret_state <path>: 0 absent, 1 a valid regular file; anything else refuses (fail closed).
secret_state() {
  local p="$1" v
  if [ -L "$p" ]; then die "secret path $p is a symlink" 1; fi
  if [ ! -e "$p" ]; then return 1; fi
  [ -f "$p" ] || die "secret path $p is not a regular file" 1
  v="$(<"$p")" || die "cannot read $p" 1
  [[ "$v" =~ $PW_RE ]] || die "secret file $p does not hold a valid password (want $PW_RE); refusing to overwrite it" 1
  return 0
}

preflight() {
  local out problems=0
  [ ! -L "$APPDIR" ] || die "the app secrets path $APPDIR is a symlink" 1
  [ ! -e "$APPDIR" ] || [ -d "$APPDIR" ] || die "the app secrets path $APPDIR is not a directory" 1

  pg_phase "preflight-postgres" postgres "SELECT (SELECT count(*) FROM pg_roles WHERE rolname = '$PGROLE') || '|' || (SELECT count(*) FROM pg_database WHERE datname = '$PGROLE');"
  out="$PHASE_OUT"
  if ! [[ "$out" =~ ^([0-9]+)\|([0-9]+)$ ]]; then
    log "phase=preflight-postgres unexpected output shape"
    err "new-db: phase 'preflight-postgres' failed: unexpected reply from psql. Nothing was written."
    exit 1
  fi
  PG_ROLES="${BASH_REMATCH[1]}"
  PG_DBS="${BASH_REMATCH[2]}"

  redis_phase "preflight-redis" "ACL USERS"
  # redis-cli exits 0 on an error reply (NOAUTH, WRONGPASS, LOADING) and prints the error: only a real user list (the
  # admin user always exists) counts, so an error is never read as "this user is absent".
  if ! grep -qxF -- "admin" <<<"$PHASE_OUT"; then
    log "phase=preflight-redis unexpected reply"
    err "new-db: phase 'preflight-redis' failed: Redis did not return its user list (admin auth failed or Redis is loading). Nothing was written."
    exit 1
  fi
  if grep -qxF -- "$APP" <<<"$PHASE_OUT"; then RD_PRESENT=1; fi

  if secret_state "$APPDIR/db-password"; then S_DB=1; fi
  if secret_state "$APPDIR/redis-password"; then S_RD=1; fi
  log "state postgres_role=$PG_ROLES postgres_db=$PG_DBS db_password_file=$S_DB redis_user=$RD_PRESENT redis_password_file=$S_RD"

  if [ "$((PG_ROLES + PG_DBS))" -gt 0 ] && [ "$S_DB" -eq 0 ]; then
    err "new-db: the Postgres role or database '$PGROLE' exists but $APPDIR/db-password is missing."
    err "  Refusing to reset the password. Restore the file from a backup, or (if the app holds no data) drop the role"
    err "  and database by hand and run new-db again."
    problems=1
  fi
  if [ "$RD_PRESENT" -eq 1 ] && [ "$S_RD" -eq 0 ]; then
    err "new-db: the Redis user '$APP' exists but $APPDIR/redis-password is missing."
    err "  Refusing to reset the password. Restore the file from a backup, or (if the app holds no data) run"
    err "  ACL DELUSER $APP and ACL SAVE as the Redis admin, then run new-db again."
    problems=1
  fi
  if [ "$problems" -ne 0 ]; then
    log "FAILED preflight: an object exists without its secret file; nothing was modified"
    exit 1
  fi
}

# ---- 5. apply ----

gen_password() {
  local pw
  pw="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$PW_LEN" || true)"
  [ "${#pw}" -eq "$PW_LEN" ] || die "could not generate a password" 1
  printf '%s' "$pw"
}

# write_secret <path> <value>: temp file in the same directory (umask 227 gives 0440), then an atomic rename.
write_secret() {
  local dest="$1" value="$2" tmp
  tmp="$APPDIR/.tmp.${dest##*/}.$$"
  TMPFILES+=("$tmp")
  (
    umask 227
    set -C
    printf '%s' "$value" >"$tmp"
  ) || die "cannot write the temp secret file in $APPDIR" 1
  mv -f -- "$tmp" "$dest" || die "cannot move the secret file into place at $dest" 1
}

ensure_appdir() {
  if [ ! -d "$APPDIR" ]; then
    (
      umask 027
      mkdir -- "$APPDIR"
    ) || die "cannot create $APPDIR" 1
    info "changed: $APPDIR/"
  else
    info "already: $APPDIR/"
  fi
}

apply_postgres() {
  local created=0 sql
  if [ "$S_DB" -eq 1 ]; then
    DB_PW="$(<"$APPDIR/db-password")"
    info "already: $APPDIR/db-password"
  else
    DB_PW="$(gen_password)"
    write_secret "$APPDIR/db-password" "$DB_PW"
    info "changed: $APPDIR/db-password"
  fi
  [ "$PG_ROLES" -gt 0 ] && [ "$PG_DBS" -gt 0 ] || created=1

  sql="SELECT 'CREATE ROLE \"$PGROLE\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 3 PASSWORD ''$DB_PW''' WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$PGROLE') \\gexec"$'\n'
  sql+="ALTER ROLE \"$PGROLE\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 3;"
  pg_phase "postgres-role" postgres "$sql"

  sql="SELECT 'CREATE DATABASE \"$PGROLE\" OWNER \"$PGROLE\"' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = '$PGROLE') \\gexec"$'\n'
  sql+="ALTER DATABASE \"$PGROLE\" OWNER TO \"$PGROLE\";"
  pg_phase "postgres-database" postgres "$sql"

  sql="REVOKE CONNECT ON DATABASE \"$PGROLE\" FROM PUBLIC;"$'\n'
  sql+="GRANT CONNECT ON DATABASE \"$PGROLE\" TO \"$PGROLE\";"$'\n'
  sql+="REVOKE CONNECT ON DATABASE postgres, template1 FROM PUBLIC;"
  pg_phase "postgres-grants" postgres "$sql"

  pg_phase "postgres-schema" "$PGROLE" "REVOKE ALL ON SCHEMA public FROM PUBLIC;"

  if [ "$created" -eq 1 ]; then info "changed: postgres role and database $PGROLE"; else info "already: postgres role and database $PGROLE"; fi
}

apply_redis() {
  local created=0 rule
  if [ "$S_RD" -eq 1 ]; then
    REDIS_PW="$(<"$APPDIR/redis-password")"
    info "already: $APPDIR/redis-password"
  else
    REDIS_PW="$(gen_password)"
    write_secret "$APPDIR/redis-password" "$REDIS_PW"
    info "changed: $APPDIR/redis-password"
  fi
  [ "$RD_PRESENT" -eq 1 ] || created=1

  rule="ACL SETUSER $APP on clearselectors resetpass >$REDIS_PW resetkeys ~$APP:* resetchannels -@all +@read +@write +@keyspace +@string +@hash +@list +@set +@sortedset +@stream +@connection -@dangerous -@scripting -@pubsub -scan -randomkey -dbsize"
  redis_phase "redis-acl-setuser" "$rule"
  [ "$PHASE_OUT" = "OK" ] || { log "phase=redis-acl-setuser unexpected reply"; err "new-db: phase 'redis-acl-setuser' failed: Redis did not reply OK. Re-run to converge."; exit 1; }
  redis_phase "redis-acl-save" "ACL SAVE"
  [ "$PHASE_OUT" = "OK" ] || { log "phase=redis-acl-save unexpected reply"; err "new-db: phase 'redis-acl-save' failed: Redis did not reply OK. Re-run to converge."; exit 1; }

  if [ "$created" -eq 1 ]; then info "changed: redis user $APP"; else info "already: redis user $APP"; fi
}

main() {
  [ "$#" -eq 1 ] || { err "usage: new-db.sh <app>"; exit 2; }
  APP="$1"
  [[ "$LOCK_WAIT" =~ ^[0-9]+$ ]] || { err "new-db: NEW_DB_LOCK_WAIT must be a whole number of seconds"; exit 2; }
  [[ "$EXEC_TIMEOUT" =~ ^[0-9]+$ ]] || { err "new-db: NEW_DB_EXEC_TIMEOUT must be a whole number of seconds"; exit 2; }

  validate_name
  APPDIR="$SECRETS_ROOT/$APP"
  log "start"
  take_lock
  ERRF="$(mktemp)"
  check_healthy
  preflight
  ensure_appdir
  apply_postgres
  apply_redis
  log "end rc=0"
  info "new-db: done $APP"
}

main "$@"
