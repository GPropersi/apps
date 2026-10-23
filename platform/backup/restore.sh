#!/usr/bin/env bash
# platform-restore (root, run by hand). Restores from the restic repository that backup.sh writes.
#
# Usage:
#   restore.sh list
#   restore.sh app <app> --into <db> [--snapshot <id>|latest] [--keep]
#   restore.sh secrets <app> [--snapshot <id>|latest] [--keep]
#   restore.sh host-files [--snapshot <id>|latest] [--keep]
#   restore.sh full --confirm-destroy [--snapshot <id>|latest] [--keep]
# Exit codes: 0 ok, 1 failed (the step is named), 2 usage or refused (nothing was changed).
#
# Safety: every refusal is fail-closed and happens before the first mutating call. `app` only creates a NEW database
# beside the live one; `secrets` and `host-files` never overwrite a differing file; `full` refuses unless the Postgres
# cluster holds only postgres and templates and Redis holds no key and no ACL user except default, admin and health.
# `full` also validates the whole restored snapshot (globals.sql, dump names, Redis files, every app secrets directory,
# the Redis image and /data mount) before it places the first secret. No override and no flag relaxes those refusals.
# If `app` fails during pg_restore the half-restored database --into is left behind: DROP it before a retry.
#
# Credentials: /etc/platform/backup.env is read by this script itself with the same literal KEY=VALUE reader as
# backup.sh (never sourced), so it works under `sudo -n` with a stripped environment.
#
# Test overrides are honoured ONLY when PLATFORM_BACKUP_TESTING=1; otherwise every PLATFORM_BACKUP_* / PLATFORM_RESTORE_*
# variable is ignored (unset, named in a warning) and the production values apply.
# Shared overrides (the same names and meaning as backup.sh, all optional, each read once at startup, default = the
# production value, an unparsable value exits 2). A restore needs the same values the backup ran with:
#   PLATFORM_BACKUP_ENV_FILE PLATFORM_BACKUP_ENV_OWNER PLATFORM_BACKUP_ROOT
#   PLATFORM_BACKUP_LOG_DIR PLATFORM_BACKUP_LOCK PLATFORM_BACKUP_SECRETS_ROOT PLATFORM_BACKUP_LOCK_DIR
#   PLATFORM_BACKUP_PG_ADMIN_FILE
#   PLATFORM_BACKUP_REDIS_ADMIN_FILE PLATFORM_BACKUP_PG_CONTAINER PLATFORM_BACKUP_REDIS_CONTAINER
# (PLATFORM_BACKUP_DEADLINE_SECS is not read here.) Restore-only test overrides:
#   PLATFORM_RESTORE_ALLOW_NONROOT   unset: require EUID 0. Only the value 1 bypasses that check (it does not relax the
#                                    env-file owner check)
#   PLATFORM_RESTORE_CHOWN           chown   (the chown command; tests stub it)
#   PLATFORM_RESTORE_COMPOSE         /opt/platform/data/compose.yaml   (the data stack's compose file)
#   PLATFORM_RESTORE_INSTALL_DATA    /opt/platform/data/install-data.sh   (run as `verify` at the end of `full`; when the
#                                    file is absent the step is skipped and logged)
#
# Known limits: `timeout` kills only the host `docker exec` client, so a psql, pg_restore or redis-cli process inside the
# container can outlive a timeout; every restore step runs into a NEW database or a stack that was refused unless empty,
# so a re-run after a clean-up converges.
set -euo pipefail

export LC_ALL=C

ENV_KEYS=(RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION DISCORD_WEBHOOK)
RESTIC_REPOSITORY=""
RESTIC_PASSWORD=""
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
# RESTIC_* and AWS_* are exported for restic and the S3 SDK (DISCORD_WEBHOOK is never exported: a restore does not use it,
# it is only masked in logs). All are set by read_backup_env, so shellcheck sees no direct use.
# shellcheck disable=SC2034
AWS_DEFAULT_REGION=""
DISCORD_WEBHOOK=""
ENV_READ_ERROR=""

SCRUB_ENV=(RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND RESTIC_REPOSITORY_FILE RESTIC_FROM_REPOSITORY
  RESTIC_FROM_PASSWORD_FILE RESTIC_FROM_PASSWORD_COMMAND RESTIC_FROM_REPOSITORY_FILE RESTIC_KEY_HINT RESTIC_CACHE_DIR
  RESTIC_COMPRESSION RESTIC_PACK_SIZE RESTIC_READ_CONCURRENCY AWS_SESSION_TOKEN AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE
  AWS_CONFIG_FILE AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_REGION AWS_ENDPOINT_URL AWS_ENDPOINT_URL_S3)

# In-container path of the Redis admin password file (the data stack mounts it there; same constant as new-db.sh).
REDIS_CTR_ADMIN_FILE=/etc/platform/redis-admin.password
# Identical to backup.sh's, new-db.sh's and install-data.sh's REDIS_ADMIN_SNIPPET (a test compares them).
# shellcheck disable=SC2016 # expanded by the shell inside the container
readonly REDIS_ADMIN_SNIPPET='f="$1"; shift; pw="$(cat "$f"; printf x)"; pw="${pw%x}"; nl="$(printf "\nx")"; nl="${nl%x}"; case "$pw" in *"$nl") pw="${pw%"$nl"}" ;; esac; REDISCLI_AUTH="$pw" exec redis-cli --user admin --no-auth-warning "$@"'

readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
readonly DB_RE='^[a-z][a-z0-9_]{1,30}$'
readonly SNAP_RE='^(latest|[0-9a-f]{8,64})$'
readonly SECRETS_GID=64323
readonly ADMIN_GID=64322
# Bounded polls (each one pause of POLL_PAUSE seconds): 60 x 2s = 120s per wait.
readonly POLL_MAX=60
readonly POLL_PAUSE=2

CMD=""
APP=""
INTO=""
SNAP="latest"
CONFIRM=0
KEEP=0
PGROLE=""
RDIR=""
WORK=""
LOG_FILE=""
TIMED_LAST_FILE="/dev/null"
TIMED_PID=""
LOADER_UP=0
# The one-shot loader's name is derived from the Redis container (set in load_overrides), never a shared constant, so a
# restore aimed at one stack can never stop, replace or remove the loader of another.
LOADER_NAME=""
STEP=""
SNAP_ID=""
SNAP_TIME=""
APPLOCKFD=""
REDIS_IMAGE=""
REDIS_MOUNT=""

# ---- masking and logging ----

# mask_text <text>: replaces every secret value with *** (values loaded from backup.env; empty values skipped).
mask_text() {
  local s="$1" v
  for v in "$RESTIC_REPOSITORY" "$RESTIC_PASSWORD" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$DISCORD_WEBHOOK"; do
    if [ -n "$v" ]; then s=${s//"$v"/***}; fi
  done
  printf '%s' "$s"
}

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_epoch() { date +%s; }

# log <text>: timestamped, masked, to stdout (journald when run under systemd-run) and the dated file log.
log() {
  local line
  line="$(now_iso) restore $(mask_text "$*")"
  printf '%s\n' "$line"
  if [ -n "$LOG_FILE" ]; then printf '%s\n' "$line" >> "$LOG_FILE" 2> /dev/null || true; fi
}

# init_logging: appends to the dated log of backup.sh. The directory is NEVER created here (install-backup does).
init_logging() {
  LOG_FILE="$LOG_DIR/$(date -u +%Y-%m-%d).log"
  if ! (umask 027 && : >> "$LOG_FILE") 2> /dev/null; then
    LOG_FILE=""
    echo "WARN: cannot write a file log under $LOG_DIR; logging to stdout only" >&2
  else
    chmod 0640 -- "$LOG_FILE" 2> /dev/null || true
  fi
  return 0
}

# ---- overrides ----

# ov_path <target-var> <OVERRIDE_NAME> <default>: absolute path without whitespace.
ov_path() {
  local name="$2" v
  if [ -n "${!name+x}" ]; then v="${!name}"; else v="$3"; fi
  if [[ "$v" != /* ]] || [[ "$v" == *[[:space:]]* ]]; then
    echo "FATAL: $name must be an absolute path without whitespace" >&2
    exit 2
  fi
  printf -v "$1" '%s' "$v"
}

ov_name() { # <target-var> <OVERRIDE_NAME> <default>: a container name
  local name="$2" v
  if [ -n "${!name+x}" ]; then v="${!name}"; else v="$3"; fi
  if [[ ! "$v" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "FATAL: $name is not a valid container name" >&2
    exit 2
  fi
  printf -v "$1" '%s' "$v"
}

# gate_test_overrides: fail closed (same function as backup.sh). The PLATFORM_BACKUP_* / PLATFORM_RESTORE_* overrides are
# test hooks (a different chown, data root, env file, ...); they are honoured only with PLATFORM_BACKUP_TESTING=1 and are
# otherwise unset (named in a warning, never their values), so a caller environment that leaks through sudo -E / env_keep
# cannot redirect a root run.
gate_test_overrides() {
  local v dropped=""
  if [ "${PLATFORM_BACKUP_TESTING:-}" = "1" ]; then return 0; fi
  for v in $(compgen -v PLATFORM_); do
    case "$v" in
      PLATFORM_BACKUP_* | PLATFORM_RESTORE_*) unset "$v"; dropped="$dropped $v" ;;
      *) ;;
    esac
  done
  if [ -n "$dropped" ]; then echo "WARN: ignoring test overrides without PLATFORM_BACKUP_TESTING=1:$dropped" >&2; fi
  return 0
}

load_overrides() {
  gate_test_overrides
  ov_path ENV_FILE PLATFORM_BACKUP_ENV_FILE /etc/platform/backup.env
  ov_path BACKUP_ROOT PLATFORM_BACKUP_ROOT /var/lib/platform/backup
  ov_path LOG_DIR PLATFORM_BACKUP_LOG_DIR /var/log/platform-backup
  ov_path LOCK_FILE PLATFORM_BACKUP_LOCK /run/platform-backup.lock
  ov_path SECRETS_ROOT PLATFORM_BACKUP_SECRETS_ROOT /var/lib/platform/secrets
  ov_path LOCK_DIR PLATFORM_BACKUP_LOCK_DIR /var/lib/platform/locks
  ov_path PG_ADMIN_FILE PLATFORM_BACKUP_PG_ADMIN_FILE /etc/platform/postgres-admin.password
  ov_path REDIS_ADMIN_FILE PLATFORM_BACKUP_REDIS_ADMIN_FILE /etc/platform/redis-admin.password
  ov_name PG_CONTAINER PLATFORM_BACKUP_PG_CONTAINER platform-data-postgres
  ov_name REDIS_CONTAINER PLATFORM_BACKUP_REDIS_CONTAINER platform-data-redis
  ENV_OWNER="0:0"
  if [ -n "${PLATFORM_BACKUP_ENV_OWNER+x}" ]; then
    if [[ ! "$PLATFORM_BACKUP_ENV_OWNER" =~ ^[0-9]+:[0-9]+$ ]]; then
      echo "FATAL: PLATFORM_BACKUP_ENV_OWNER must match uid:gid (digits)" >&2
      exit 2
    fi
    ENV_OWNER="$PLATFORM_BACKUP_ENV_OWNER"
  fi
  CHOWN="chown"
  if [ -n "${PLATFORM_RESTORE_CHOWN+x}" ]; then
    if [[ ! "$PLATFORM_RESTORE_CHOWN" =~ ^[A-Za-z0-9_./-]+$ ]]; then
      echo "FATAL: PLATFORM_RESTORE_CHOWN must be a command name or path without spaces" >&2
      exit 2
    fi
    CHOWN="$PLATFORM_RESTORE_CHOWN"
  fi
  ov_path COMPOSE_FILE PLATFORM_RESTORE_COMPOSE /opt/platform/data/compose.yaml
  ov_path INSTALL_DATA PLATFORM_RESTORE_INSTALL_DATA /opt/platform/data/install-data.sh
  LOADER_NAME="$REDIS_CONTAINER-restore-loader"
  # No `-p`: the project is the compose file's own `name:` (platform-data for the installed stack). A hard-coded project
  # silently selected no container when the file under test carries another name (the live test caught `compose stop`
  # doing nothing while the loader mounted a running Redis's volume). load_env removes COMPOSE_PROJECT_NAME; an inherited
  # COMPOSE_FILE is ignored by compose because -f is given.
  DC=(docker compose -f "$COMPOSE_FILE")
}

# ---- literal env reader (BYTE-IDENTICAL in every script that carries a copy: backup.sh, restore.sh, install-backup.sh) ----
# BEGIN shared-env-reader
# read_backup_env <file> <expected uid:gid>: refuses (return 1, message in ENV_READ_ERROR, never a value) a symlink or
# non-regular file, a wrong owner, a mode other than 0600, a CR, a line without "=", an unknown or duplicate key and a
# value starting with a quote. Each line splits at the FIRST "="; the value is everything after it, with no quote,
# backslash, whitespace or comment processing. Blank lines and lines starting with "#" are skipped. Never sources.
read_backup_env() {
  local f="$1" want_owner="$2" line key val st n=0 seen=" " k
  ENV_READ_ERROR=""
  for k in RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION DISCORD_WEBHOOK; do
    printf -v "$k" '%s' ""
  done
  if [ -L "$f" ]; then ENV_READ_ERROR="env file is a symlink"; return 1; fi
  if [ ! -f "$f" ]; then ENV_READ_ERROR="env file is missing or not a regular file"; return 1; fi
  if ! st="$(stat -c '%u:%g %a' -- "$f" 2>/dev/null)"; then ENV_READ_ERROR="cannot stat env file"; return 1; fi
  if [ "${st%% *}" != "$want_owner" ]; then ENV_READ_ERROR="env file owner is not $want_owner"; return 1; fi
  if [ "${st##* }" != "600" ]; then ENV_READ_ERROR="env file mode is not 0600"; return 1; fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in *$'\r'*) ENV_READ_ERROR="env file line $n contains a CR"; return 1 ;; esac
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in *=*) ;; *) ENV_READ_ERROR="env file line $n has no ="; return 1 ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      RESTIC_REPOSITORY | RESTIC_PASSWORD | AWS_ACCESS_KEY_ID | AWS_SECRET_ACCESS_KEY | AWS_DEFAULT_REGION | DISCORD_WEBHOOK) ;;
      *) ENV_READ_ERROR="env file line $n has an unknown key"; return 1 ;;
    esac
    case "$seen" in *" $key "*) ENV_READ_ERROR="env file repeats key $key"; return 1 ;; esac
    case "$val" in '"'* | "'"*) ENV_READ_ERROR="env file value for $key starts with a quote"; return 1 ;; esac
    seen="$seen$key "
    printf -v "$key" '%s' "$val"
  done < "$f"
  return 0
}
# END shared-env-reader

# ---- exit paths ----

# refuse <message>: a refusal before any mutating call (exit 2).
refuse() {
  log "refused: $1"
  echo "restore: $1" >&2
  exit 2
}

# fail <step> <message> [rc]: a failure that names its step (exit 1 unless told otherwise), with the last output lines.
fail() {
  local detail=""
  STEP="$1"
  if [ -s "$TIMED_LAST_FILE" ]; then detail="$(tail -n 3 "$TIMED_LAST_FILE" 2> /dev/null | tr '\n' ' ')"; detail="$(mask_text "${detail:0:500}")"; fi
  log "FAILED step=$1 $2${detail:+ last-output=$detail}"
  echo "restore: step '$1' failed: $2" >&2
  exit "${3:-1}"
}

kill_timed_child() {
  if [ -n "${TIMED_PID:-}" ]; then
    if command -v pkill > /dev/null 2>&1; then pkill -TERM -P "$TIMED_PID" 2> /dev/null || true; fi
    kill -TERM "$TIMED_PID" 2> /dev/null || true
  fi
  return 0
}

on_signal() {
  trap - TERM INT
  log "signal $1 received during step=${STEP:-unknown}"
  kill_timed_child
  exit 1
}

# on_exit: removes the one-shot Redis loader if one is left, the restore dir (unless --keep) and the work dir.
on_exit() {
  local rc=$?
  trap - EXIT TERM INT
  set +e
  if [ "$LOADER_UP" -eq 1 ]; then
    timeout -s KILL 60 docker rm -f "$LOADER_NAME" > /dev/null 2>&1
    log "cleanup: removed the one-shot Redis loader"
  fi
  if [ -n "$RDIR" ] && [ -d "$RDIR" ]; then
    if [ "$KEEP" -eq 1 ]; then
      log "restore dir kept at $RDIR (root-only; holds restored dumps and secrets: delete it when done)"
    else
      rm -rf -- "$RDIR"
    fi
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf -- "$WORK"; fi
  log "end cmd=${CMD:-?} rc=$rc"
  exit "$rc"
}

# ---- timed ----

# timed <label> <secs> <cmd...>: runs the command under timeout with stdin from /dev/null, logs start/end (rc, duration)
# and its masked output line by line (also kept in $TIMED_LAST_FILE); TIMED OUT at 124/137. The lock fd is closed in
# the child so an orphan can never keep the lock held.
timed() {
  local label="$1" secs="$2" t0 rc=0 line
  shift 2
  : > "$TIMED_LAST_FILE" 2> /dev/null || true
  t0="$(now_epoch)"
  (
    set +e
    exec 9>&-
    if [ -n "$APPLOCKFD" ]; then eval "exec $APPLOCKFD>&-"; fi
    timeout -s TERM -k 30 "$secs" "$@" < /dev/null 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
      line="$(mask_text "$line")"
      log "$label: $line"
      printf '%s\n' "$line" >> "$TIMED_LAST_FILE" 2> /dev/null
    done
    exit "${PIPESTATUS[0]}"
  ) &
  TIMED_PID=$!
  log "phase=$label start timeout=${secs}s"
  wait "$TIMED_PID" || rc=$?
  TIMED_PID=""
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then log "phase=$label TIMED OUT after ${secs}s"; fi
  log "phase=$label end rc=$rc dur=$(($(now_epoch) - t0))s"
  return "$rc"
}

# timed_io <label> <secs> <stdin-file|-> <stdout-file|-> <cmd...>: timed, with the command's stdin and stdout redirected
# on the host side (binary-safe, never through $()). "-" for stdin is /dev/null; "-" for stdout leaves it in the log.
timed_io() {
  local label="$1" secs="$2" in="$3" out="$4"
  shift 4
  # shellcheck disable=SC2016 # the body is a literal for sh -c
  timed "$label" "$secs" sh -c 'i="$1"; o="$2"; shift 2; if [ "$i" = - ]; then i=/dev/null; fi; exec < "$i"; if [ "$o" != - ]; then exec > "$o"; fi; exec "$@"' sh "$in" "$out" "$@"
}

# step_io <step> <secs> <in> <out> <cmd...>: timed_io that fails the run, naming the step, on a non-zero rc.
step_io() {
  local step="$1" secs="$2" in="$3" out="$4" rc=0
  shift 4
  STEP="$step"
  timed_io "$step" "$secs" "$in" "$out" "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then fail "$step" "command failed (rc=$rc)"; fi
  return 0
}

# ---- startup checks ----

usage() {
  cat >&2 << 'EOF'
usage: restore.sh list
       restore.sh app <app> --into <db> [--snapshot <id>|latest] [--keep]
       restore.sh secrets <app> [--snapshot <id>|latest] [--keep]
       restore.sh host-files [--snapshot <id>|latest] [--keep]
       restore.sh full --confirm-destroy [--snapshot <id>|latest] [--keep]
EOF
  exit 2
}

parse_args() {
  CMD="${1:-}"
  [ "$#" -ge 1 ] || usage
  shift
  case "$CMD" in
    list) [ "$#" -eq 0 ] || usage ;;
    app | secrets)
      [ "$#" -ge 1 ] || usage
      APP="$1"
      shift
      ;;
    host-files | full) ;;
    *) usage ;;
  esac
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --snapshot)
        [ "$#" -ge 2 ] || usage
        SNAP="$2"
        shift 2
        ;;
      --keep)
        KEEP=1
        shift
        ;;
      --into)
        [ "$CMD" = app ] && [ "$#" -ge 2 ] || usage
        INTO="$2"
        shift 2
        ;;
      --confirm-destroy)
        [ "$CMD" = full ] || usage
        CONFIRM=1
        shift
        ;;
      *) usage ;;
    esac
  done
  [[ "$SNAP" =~ $SNAP_RE ]] || { echo "restore: --snapshot must be latest or a hex snapshot id" >&2; exit 2; }
  if [ "$CMD" = app ] && [ -z "$INTO" ]; then usage; fi
  if [ "$CMD" = full ] && [ "$CONFIRM" -ne 1 ]; then
    echo "restore: full replaces the data layer: it needs --confirm-destroy and an empty stack" >&2
    exit 2
  fi
  return 0
}

require_root() {
  if [ "$EUID" -eq 0 ]; then return 0; fi
  if [ "${PLATFORM_RESTORE_ALLOW_NONROOT:-}" = "1" ]; then return 0; fi
  echo "restore: must run as root (sudo)" >&2
  exit 2
}

# check_dirs: restore never creates the state dirs; install-backup restore-only does.
check_dirs() {
  local d
  if [ "$BACKUP_ROOT" = "/" ]; then echo "FATAL: PLATFORM_BACKUP_ROOT must not be /" >&2; exit 2; fi
  for d in "$(dirname "$BACKUP_ROOT")" "$BACKUP_ROOT" "$LOG_DIR"; do
    if [ ! -d "$d" ]; then
      echo "restore: missing directory $d (run: install-backup restore-only)" >&2
      exit 2
    fi
  done
}

load_env() {
  local k missing=""
  unset "${SCRUB_ENV[@]}" DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG COMPOSE_PROJECT_NAME COMPOSE_PROFILES
  while IFS= read -r k; do
    case "$k" in RESTIC_* | AWS_* | RCLONE_*) unset "$k" ;; esac
  done < <(compgen -e)
  if ! read_backup_env "$ENV_FILE" "$ENV_OWNER"; then
    log "FATAL: $ENV_READ_ERROR"
    echo "restore: $ENV_READ_ERROR" >&2
    exit 2
  fi
  for k in "${ENV_KEYS[@]}"; do
    if [ -z "${!k}" ]; then missing="${missing:+$missing }$k"; fi
  done
  if [ -n "$missing" ]; then
    log "FATAL: missing required env var(s): $missing"
    echo "restore: missing required env var(s): $missing" >&2
    exit 2
  fi
  export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  export -n DISCORD_WEBHOOK
}

# take_lock: flock -n on the lock backup.sh uses (fd 9, held until exit).
take_lock() {
  # LOCK_FILE is assigned by ov_path (printf -v) in load_overrides.
  # shellcheck disable=SC2153
  if ! exec 9> "$LOCK_FILE"; then
    log "FATAL: cannot open lock file $LOCK_FILE"
    echo "restore: cannot open the lock file" >&2
    exit 1
  fi
  if ! flock -n 9; then
    log "state lock-held"
    echo "restore: a backup or another restore holds the lock" >&2
    exit 1
  fi
}

# prepare_restore_dir: <backup root>/restore/<UTC stamp>-<pid>, root 0700 (removed on exit unless --keep).
prepare_restore_dir() {
  local base="$BACKUP_ROOT/restore"
  (umask 077 && mkdir -p -- "$base") || fail restore-dir "cannot create $base"
  RDIR="$base/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  (umask 077 && mkdir -- "$RDIR") || fail restore-dir "cannot create $RDIR"
  chmod 0700 -- "$base" "$RDIR" || fail restore-dir "cannot chmod $RDIR"
}

# ---- restic ----

# snap_args: the restic snapshot selector. Only `latest` is host-filtered; an explicit id is used as given.
snap_args() {
  if [ "$SNAP" = latest ]; then printf '%s\0' latest --host platform; else printf '%s\0' "$SNAP"; fi
}

# resolve_snapshot: logs the snapshot id and time the selector resolves to (fail closed when it resolves to none).
resolve_snapshot() {
  local f="$WORK/snap.json" body id_re='"id":"([0-9a-f]{64})"' time_re='"time":"([^"]+)"' rc=0
  local -a sel
  mapfile -d '' -t sel < <(snap_args)
  STEP=snapshot-resolve
  timed_io snapshot-resolve 120 - "$f" restic snapshots --json "${sel[@]}" || rc=$?
  if [ "$rc" -ne 0 ]; then fail snapshot-resolve "restic snapshots failed (rc=$rc)"; fi
  body="$(< "$f")"
  if [[ ! "$body" =~ $id_re ]]; then fail snapshot-resolve "no snapshot matches '$SNAP'"; fi
  SNAP_ID="${BASH_REMATCH[1]}"
  SNAP_TIME=""
  if [[ "$body" =~ $time_re ]]; then SNAP_TIME="${BASH_REMATCH[1]}"; fi
  log "snapshot selector=$SNAP resolved id=$SNAP_ID time=${SNAP_TIME:-unknown}"
}

# restic_restore <step> <include path...>: one restic restore of the selected snapshot into the restore dir. No --exclude:
# restic refuses --exclude together with --include, and backup.sh already keeps lock and temp files out of the snapshot.
restic_restore() {
  local step="$1" p rc=0
  shift
  local -a sel inc=()
  if [ -n "$SNAP_ID" ]; then sel=("$SNAP_ID"); else mapfile -d '' -t sel < <(snap_args); fi
  for p in "$@"; do inc+=(--include "$p"); done
  STEP="$step"
  timed "$step" 1800 restic restore "${sel[@]}" --target "$RDIR" "${inc[@]}" || rc=$?
  if [ "$rc" -ne 0 ]; then fail "$step" "restic restore failed (rc=$rc)"; fi
  return 0
}

# ---- helpers ----

deploy_uid() {
  local u
  u="$(getent passwd deploy | cut -d: -f3)" || u=""
  [[ "$u" =~ ^[0-9]+$ ]] || refuse "the deploy user does not exist (run install-deploy-user first)"
  printf '%s' "$u"
}

# pg_sql <step> <db> <outfile|-> <sql>: SQL on stdin to psql as postgres over peer, ON_ERROR_STOP.
pg_sql() {
  local step="$1" db="$2" out="$3" sql="$4"
  printf '%s\n' "$sql" > "$WORK/q.sql"
  step_io "$step" 120 "$WORK/q.sql" "$out" docker exec -i "$PG_CONTAINER" psql -X -U postgres -d "$db" -At -v ON_ERROR_STOP=1
}

# redis_cli <step> <outfile> <redis-cli args...>: one admin redis-cli call in the real Redis container.
redis_cli() {
  local step="$1" out="$2"
  shift 2
  step_io "$step" 60 - "$out" docker exec -i "$REDIS_CONTAINER" sh -c "$REDIS_ADMIN_SNIPPET" sh "$REDIS_CTR_ADMIN_FILE" "$@"
}

# DC (the data stack compose command) is set in load_overrides.

check_healthy() {
  local name f="$WORK/health"
  for name in "$PG_CONTAINER" "$REDIS_CONTAINER"; do
    step_io "health:$name" 60 - "$f" docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name"
    if [ "$(tr -d '\r\n' < "$f")" != "running|healthy" ]; then
      refuse "container $name is not running and healthy (install-data install first)"
    fi
  done
}

# check_secrets_src <app>: the restored <secrets root>/<app> is a real directory holding only files and directories (exit 2).
check_secrets_src() {
  local app="$1" src="$RDIR$SECRETS_ROOT/$1"
  STEP="secrets:$app"
  [ -d "$src" ] && [ ! -L "$src" ] || fail "secrets:$app" "the snapshot holds no secrets directory for '$app'" 2
  if [ -n "$(find "$src" ! -type f ! -type d -print -quit)" ]; then fail "secrets:$app" "the restored tree holds a symlink or special file" 2; fi
}

# place_secrets <app>: sets the owner of the restored <secrets root>/<app> tree to the CURRENT deploy uid and gid 64323,
# modes 2750 (dir) / 0440 (file), and verifies each with stat, all INSIDE the root-only restore dir (0700, so the deploy
# user cannot swap a symlink in under a path-based chown). The mv -T into the deploy-owned secrets root is the LAST step:
# no root chown/chmod follows a path the deploy user can reach. The secrets root itself is untouched.
place_secrets() {
  local app="$1" src dst uid p st want
  src="$RDIR$SECRETS_ROOT/$app"
  dst="$SECRETS_ROOT/$app"
  check_secrets_src "$app"
  uid="$(deploy_uid)"
  while IFS= read -r -d '' p; do
    "$CHOWN" -h "$uid:$SECRETS_GID" -- "$p" || fail "secrets:$app" "chown failed"
    if [ -d "$p" ]; then chmod 2750 -- "$p" || fail "secrets:$app" "chmod failed"; else chmod 0440 -- "$p" || fail "secrets:$app" "chmod failed"; fi
  done < <(find "$src" -print0)
  while IFS= read -r -d '' p; do
    if [ -d "$p" ]; then want="$uid:$SECRETS_GID 2750"; else want="$uid:$SECRETS_GID 440"; fi
    st="$(stat -c '%u:%g %a' -- "$p")" || fail "secrets:$app" "cannot stat a restored path"
    if [ "$st" != "$want" ]; then fail "secrets:$app" "a restored path has owner/mode '$st', want '$want'"; fi
  done < <(find "$src" -print0)
  # Re-checked right before the move (mv -T onto an empty directory would succeed silently).
  if [ -e "$dst" ] || [ -L "$dst" ]; then refuse "$dst already exists; nothing more was changed"; fi
  mv -T -- "$src" "$dst" || fail "secrets:$app" "cannot move the restored directory into $SECRETS_ROOT"
  log "secrets: restored $dst owner=$uid:$SECRETS_GID"
}

# take_app_lock <app>: flock -n on <lock dir>/<app>.lock, the lock new-db.sh uses. The lock dir is root-owned (never the
# deploy-owned secrets root), so root never creates, chowns or chmods a path the deploy user controls.
take_app_lock() {
  local app="$1" lock
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || refuse "the lock dir $LOCK_DIR is missing or not a directory (run install-data install first)"
  lock="$LOCK_DIR/$app.lock"
  [ ! -L "$lock" ] || refuse "the lock path $lock is a symlink"
  # The lock dir is sticky (the deploy user creates its own lock files there), so root never opens one with O_CREAT: a
  # missing lock is created with noclobber (O_EXCL, which never follows a symlink; mode 0666 so the deploy user can still
  # open it for append) and the lock is then taken on a READ-ONLY descriptor (flock needs no write access).
  if [ ! -e "$lock" ]; then (umask 0111 && set -o noclobber && : > "$lock") 2> /dev/null || true; fi
  [ -f "$lock" ] && [ ! -L "$lock" ] || refuse "the lock path $lock is not a regular file"
  exec {APPLOCKFD}< "$lock" || fail "app-lock" "cannot open $lock"
  if ! flock -n "$APPLOCKFD"; then
    log "state app-lock-held app=$app"
    echo "restore: another operation holds the lock for '$app'" >&2
    exit 1
  fi
}

# ---- subcommands ----

cmd_list() {
  step_io list 120 - "$WORK/list.out" restic snapshots --host platform
  cat "$WORK/list.out"
}

cmd_app() {
  local dump live f="$WORK/out" tables t n rc=0
  [[ "$APP" =~ $APP_RE ]] || refuse "invalid app name (want $APP_RE)"
  PGROLE="${APP//-/_}"
  case "$PGROLE" in
    pg_* | postgres | template0 | template1 | public) refuse "the name '$APP' maps to the refused Postgres identifier '$PGROLE'" ;;
    *) ;;
  esac
  [[ "$INTO" =~ $DB_RE ]] || refuse "invalid --into database name (want $DB_RE)"
  live="$PGROLE"
  [ "$INTO" != "$live" ] || refuse "--into must differ from the app's live database '$live'"
  case "$INTO" in
    pg_* | postgres | template0 | template1 | public) refuse "--into names the refused Postgres identifier '$INTO'" ;;
    *) ;;
  esac
  take_app_lock "$APP"
  pg_sql app-check postgres "$f" "SELECT (SELECT count(*) FROM pg_database WHERE datname = '$INTO') || '|' || (SELECT count(*) FROM pg_roles WHERE rolname = '$PGROLE');"
  if [[ ! "$(tr -d '\r\n' < "$f")" =~ ^([0-9]+)\|([0-9]+)$ ]]; then fail app-check "unexpected reply from psql"; fi
  [ "${BASH_REMATCH[1]}" -eq 0 ] || refuse "the database '$INTO' already exists"
  [ "${BASH_REMATCH[2]}" -gt 0 ] || refuse "the Postgres role '$PGROLE' does not exist (run secrets and install-data first)"
  prepare_restore_dir
  dump="$BACKUP_ROOT/staging/postgres/$PGROLE.dump"
  restic_restore restic-restore-app "$dump"
  [ -f "$RDIR$dump" ] || refuse "the snapshot holds no dump for '$APP' ($PGROLE.dump)"
  pg_sql app-create postgres - "CREATE DATABASE \"$INTO\" OWNER \"$PGROLE\";
REVOKE CONNECT ON DATABASE \"$INTO\" FROM PUBLIC;
GRANT CONNECT ON DATABASE \"$INTO\" TO \"$PGROLE\";"
  STEP="app-pg-restore"
  timed_io app-pg-restore 3600 "$RDIR$dump" - docker exec -i "$PG_CONTAINER" pg_restore -U postgres --no-owner "--role=$PGROLE" -d "$INTO" || rc=$?
  if [ "$rc" -ne 0 ]; then
    fail app-pg-restore "pg_restore failed (rc=$rc); the half-restored database '$INTO' was left behind: drop it (DROP DATABASE \"$INTO\") before retrying"
  fi
  pg_sql app-tables "$INTO" "$f" "SELECT quote_ident(schemaname) || '.' || quote_ident(tablename) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog', 'information_schema') ORDER BY 1;"
  tables="$(< "$f")"
  echo "restored database '$INTO' (owner $PGROLE) from snapshot $SNAP; rows per table:"
  while IFS= read -r t || [ -n "$t" ]; do
    [ -n "$t" ] || continue
    pg_sql "app-count" "$INTO" "$f" "SELECT count(*) FROM $t;"
    n="$(tr -d '\r\n' < "$f")"
    echo "  $t: $n"
  done <<< "$tables"
  log "app: restored $APP into $INTO"
}

cmd_secrets() {
  [[ "$APP" =~ $APP_RE ]] || refuse "invalid app name (want $APP_RE)"
  [ -d "$SECRETS_ROOT" ] && [ ! -L "$SECRETS_ROOT" ] || refuse "the secrets root $SECRETS_ROOT is missing or not a directory"
  if [ -e "$SECRETS_ROOT/$APP" ] || [ -L "$SECRETS_ROOT/$APP" ]; then refuse "$SECRETS_ROOT/$APP already exists; nothing was changed"; fi
  take_app_lock "$APP"
  # Re-checked under the lock: new-db.sh may have created the directory in between.
  if [ -e "$SECRETS_ROOT/$APP" ] || [ -L "$SECRETS_ROOT/$APP" ]; then refuse "$SECRETS_ROOT/$APP already exists; nothing was changed"; fi
  prepare_restore_dir
  restic_restore restic-restore-secrets "$SECRETS_ROOT/$APP"
  place_secrets "$APP"
  echo "restored $SECRETS_ROOT/$APP"
}

# admin_state <src> <dst>: prints absent | same | differs (a symlink or non-regular destination refuses).
admin_state() {
  local src="$1" dst="$2"
  if [ -L "$dst" ]; then refuse "$dst is a symlink"; fi
  if [ ! -e "$dst" ]; then echo absent; return 0; fi
  [ -f "$dst" ] || refuse "$dst is not a regular file"
  if cmp -s -- "$src" "$dst"; then echo same; else echo differs; fi
}

write_admin() { # <src> <dst>: temp file beside the destination, root:64322 0640, atomic rename
  local src="$1" dst="$2" tmp
  tmp="$(mktemp "$(dirname "$dst")/.tmp.restore.XXXXXX")" || fail host-files "cannot create a temp file beside $dst"
  if ! { cat -- "$src" > "$tmp" && chmod 0640 -- "$tmp" && "$CHOWN" "0:$ADMIN_GID" -- "$tmp" && mv -f -- "$tmp" "$dst"; }; then
    rm -f -- "$tmp"
    fail host-files "cannot write $dst"
  fi
}

cmd_host_files() {
  local f st states=() i=0 differs=0
  local -a files=("$PG_ADMIN_FILE" "$REDIS_ADMIN_FILE")
  for f in "${files[@]}"; do
    [ -d "$(dirname "$f")" ] || refuse "the directory $(dirname "$f") does not exist"
  done
  resolve_snapshot
  prepare_restore_dir
  restic_restore restic-restore-host-files "${files[@]}"
  for f in "${files[@]}"; do
    [ -f "$RDIR$f" ] || fail host-files "the snapshot holds no $f"
    st="$(admin_state "$RDIR$f" "$f")"
    states+=("$st")
    if [ "$st" = differs ]; then differs=1; log "host-files: $f differs from the snapshot copy"; fi
  done
  if [ "$differs" -eq 1 ]; then refuse "an existing admin password file differs from the snapshot; nothing was changed"; fi
  for f in "${files[@]}"; do
    case "${states[$i]}" in
      same) echo "already: $f" ;;
      absent)
        write_admin "$RDIR$f" "$f"
        echo "changed: $f"
        ;;
      *) fail host-files "unexpected state" ;;
    esac
    i=$((i + 1))
  done
}

# ---- full ----

# full_check_empty: Postgres holds only postgres and templates; Redis holds no key and no ACL user besides
# default, admin and health. An unreadable or unexpected reply refuses too (fail closed).
full_check_empty() {
  local f="$WORK/out" line users
  pg_sql full-check-pg postgres "$f" "SELECT count(*) FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres';"
  [[ "$(tr -d '\r\n' < "$f")" =~ ^[0-9]+$ ]] || refuse "unexpected reply from psql; refusing"
  [ "$(tr -d '\r\n' < "$f")" -eq 0 ] || refuse "the Postgres cluster already holds an application database; full restores only onto an empty stack"
  redis_cli full-check-redis-users "$f" ACL USERS
  users=0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
      '') ;;
      default | admin | health) if [ "$line" = admin ]; then users=1; fi ;;
      *) refuse "Redis already holds an ACL user besides default, admin and health; full restores only onto an empty stack" ;;
    esac
  done < "$f"
  [ "$users" -eq 1 ] || refuse "Redis did not return its user list; refusing"
  redis_cli full-check-redis-keys "$f" INFO keyspace
  grep -q '^# Keyspace' "$f" || refuse "Redis did not return its keyspace; refusing"
  if grep -qE '^db[0-9]+:' "$f"; then refuse "Redis already holds keys; full restores only onto an empty stack"; fi
}

# restore_globals: loads globals.sql minus `CREATE ROLE postgres` as postgres over peer, ON_ERROR_STOP.
restore_globals() {
  local src="$RDIR$BACKUP_ROOT/staging/postgres/globals.sql" out="$WORK/globals.sql"
  [ -f "$src" ] || fail pg-globals "the snapshot holds no globals.sql"
  sed '/^CREATE ROLE postgres;$/d' "$src" > "$out" || fail pg-globals "cannot filter globals.sql"
  step_io pg-globals 300 "$out" - docker exec -i "$PG_CONTAINER" psql -X -U postgres -d postgres -v ON_ERROR_STOP=1
}

restore_databases() {
  local d db n=0
  for d in "$RDIR$BACKUP_ROOT"/staging/postgres/*.dump; do
    [ -f "$d" ] || continue
    db="${d##*/}"
    db="${db%.dump}"
    [[ "$db" =~ $DB_RE ]] || fail pg-restore "dump name '${db:0:40}' is not a valid database name" 2
    step_io "pg-restore:$db" 3600 "$d" - docker exec -i "$PG_CONTAINER" pg_restore -U postgres -C -d postgres --exit-on-error
    n=$((n + 1))
  done
  log "pg-restore: restored $n database(s)"
}

# redis_inspect (read-only, run by full_prevalidate before the first mutation): the image and /data mount of the real
# Redis container, into REDIS_IMAGE and REDIS_MOUNT.
redis_inspect() {
  local f="$WORK/out" image mount_kind mount_name mount_src mount line
  local ire='^[A-Za-z0-9][A-Za-z0-9_./:@-]*$'
  step_io redis-inspect-image 60 - "$f" docker inspect --format '{{.Config.Image}}' "$REDIS_CONTAINER"
  image="$(tr -d '\r\n' < "$f")"
  [[ "$image" =~ $ire ]] || fail redis-inspect-image "unexpected image reference" 2
  step_io redis-inspect-mount 60 - "$f" docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Type}}|{{.Name}}|{{.Source}}{{end}}{{end}}' "$REDIS_CONTAINER"
  line="$(tr -d '\r\n' < "$f")"
  IFS='|' read -r mount_kind mount_name mount_src <<< "$line"
  case "$mount_kind" in
    volume) mount="$mount_name" ;;
    bind) mount="$mount_src" ;;
    *) fail redis-inspect-mount "the Redis container has no /data volume or bind mount" 2 ;;
  esac
  if [ "$mount_kind" = volume ] && [[ ! "$mount" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then fail redis-inspect-mount "unexpected volume name" 2; fi
  if [ "$mount_kind" = bind ] && { [[ "$mount" != /* ]] || [[ "$mount" == *[[:space:]:,]* ]]; }; then fail redis-inspect-mount "unexpected bind source" 2; fi
  REDIS_IMAGE="$image"
  REDIS_MOUNT="$mount"
}

# redis_load: stop Redis, replace dump.rdb and users.acl in its /data mount, load the RDB in a one-shot appendonly-off
# container, BGREWRITEAOF (waits until nothing is in progress or scheduled), remove it, then start the real Redis (the
# stack runs appendonly yes, which would otherwise ignore a bare RDB in favour of an empty append-only file).
redis_load() {
  local f="$WORK/out" image="$REDIS_IMAGE" mount="$REDIS_MOUNT" i inprog sched status line stage="$RDIR$BACKUP_ROOT/staging/redis"
  [ -n "$image" ] && [ -n "$mount" ] || fail redis-load "the Redis image and mount were not inspected first"
  step_io redis-stop 120 - - "${DC[@]}" stop redis
  # `compose stop` exits 0 when it selected no container, so prove the real Redis is down before its /data is replaced.
  step_io redis-stop-check 60 - "$f" docker inspect --format '{{.State.Running}}' "$REDIS_CONTAINER"
  [ "$(tr -d '\r\n' < "$f")" = false ] || fail redis-stop-check "the Redis container $REDIS_CONTAINER is still running after compose stop"
  # shellcheck disable=SC2016 # the body is a literal for the container's sh
  step_io redis-replace-files 120 - - docker run --rm --read-only --network none --user 0:0 --cap-drop ALL --cap-add CHOWN \
    --cap-add DAC_OVERRIDE --cap-add FOWNER --security-opt no-new-privileges:true -v "$mount:/data" -v "$stage:/restore:ro" \
    --entrypoint sh "$image" -c 'set -e; rm -rf /data/appendonlydir /data/appendonly.aof /data/dump.rdb; cp /restore/dump.rdb /data/dump.rdb; cp /restore/users.acl /data/users.acl; chown 999:999 /data/dump.rdb /data/users.acl; chmod 0600 /data/dump.rdb /data/users.acl'
  rm_stale_loader
  LOADER_UP=1
  step_io redis-loader-start 120 - - docker run -d --name "$LOADER_NAME" --user 999:999 --network none --read-only --tmpfs /tmp \
    --cap-drop ALL --security-opt no-new-privileges:true --memory 192m -v "$mount:/data" --entrypoint redis-server "$image" \
    --appendonly no --save "" --dir /data
  i=0
  while :; do
    if timed_io redis-loader-loading 60 - "$f" docker exec "$LOADER_NAME" redis-cli INFO persistence; then
      if grep -q '^loading:0' "$f"; then break; fi
    fi
    i=$((i + 1))
    if [ "$i" -ge "$POLL_MAX" ]; then fail redis-loader-loading "the one-shot Redis did not finish loading the RDB in time"; fi
    sleep "$POLL_PAUSE"
  done
  step_io redis-bgrewriteaof 60 - "$f" docker exec "$LOADER_NAME" redis-cli BGREWRITEAOF
  grep -qE 'rewriting (started|scheduled)' "$f" || fail redis-bgrewriteaof "BGREWRITEAOF was not accepted"
  # "scheduled" means the fork has not happened yet: in_progress is 0 and the status still the initial ok, so done is only
  # when nothing is in progress AND nothing is scheduled AND the last status is ok.
  i=0
  while :; do
    step_io redis-aof-wait 60 - "$f" docker exec "$LOADER_NAME" redis-cli INFO persistence
    inprog=""
    sched=""
    status=""
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in
        aof_rewrite_in_progress:*) inprog="${line#*:}" ;;
        aof_rewrite_scheduled:*) sched="${line#*:}" ;;
        aof_last_bgrewrite_status:*) status="${line#*:}" ;;
      esac
    done < "$f"
    if [ "$status" = "err" ]; then fail redis-aof-wait "the AOF rewrite failed (aof_last_bgrewrite_status:err)"; fi
    if [ "$inprog" = "0" ] && [ "$sched" = "0" ] && [ "$status" = "ok" ]; then break; fi
    i=$((i + 1))
    if [ "$i" -ge "$POLL_MAX" ]; then fail redis-aof-wait "the AOF rewrite did not finish in time"; fi
    sleep "$POLL_PAUSE"
  done
  step_io redis-aof-check 60 - "$f" docker exec "$LOADER_NAME" ls /data/appendonlydir
  [ -s "$f" ] || fail redis-aof-check "the loader wrote no append-only files under /data/appendonlydir"
  step_io redis-loader-stop 120 - - docker stop "$LOADER_NAME"
  step_io redis-loader-rm 60 - - docker rm "$LOADER_NAME"
  LOADER_UP=0
  step_io redis-start 120 - - "${DC[@]}" start redis
  i=0
  while :; do
    if timed_io redis-health 30 - "$f" docker inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$REDIS_CONTAINER"; then
      if [ "$(tr -d '\r\n' < "$f")" = "running|healthy" ]; then break; fi
    fi
    i=$((i + 1))
    if [ "$i" -ge "$POLL_MAX" ]; then fail redis-health "Redis did not become healthy after the restore"; fi
    sleep "$POLL_PAUSE"
  done
}

# rm_stale_loader: removes a leftover loader from an earlier failed run (best effort; none usually exists).
rm_stale_loader() {
  timed redis-loader-rm-stale 60 docker rm -f "$LOADER_NAME" || true
}

# full_prevalidate: everything the later steps need from the snapshot and the Redis container, checked before the first
# mutation (exit 2), so a partial snapshot never leaves a half-restored stack that the next `full` would refuse.
full_prevalidate() {
  local pgdir="$RDIR$BACKUP_ROOT/staging/postgres" rdir="$RDIR$BACKUP_ROOT/staging/redis" d db
  [ -s "$pgdir/globals.sql" ] || fail pg-globals "the snapshot holds no globals.sql" 2
  for d in "$pgdir"/*.dump; do
    [ -f "$d" ] || continue
    db="${d##*/}"
    db="${db%.dump}"
    [[ "$db" =~ $DB_RE ]] || fail pg-restore "dump name '${db:0:40}' is not a valid database name" 2
  done
  [ -s "$rdir/dump.rdb" ] || fail redis-load "the snapshot holds no dump.rdb" 2
  [ -s "$rdir/users.acl" ] || fail redis-load "the snapshot holds no users.acl" 2
  redis_inspect
}

cmd_full() {
  local f st differs=0 app d
  local -a files=("$PG_ADMIN_FILE" "$REDIS_ADMIN_FILE") apps=()
  [ -f "$COMPOSE_FILE" ] || refuse "the data stack compose file $COMPOSE_FILE is missing (install-data install first)"
  [ -d "$SECRETS_ROOT" ] && [ ! -L "$SECRETS_ROOT" ] || refuse "the secrets root $SECRETS_ROOT is missing or not a directory (install-data install first)"
  check_healthy
  full_check_empty
  for f in "${files[@]}"; do
    [ -f "$f" ] && [ ! -L "$f" ] || refuse "$f is missing: run restore.sh host-files before install-data install and full (see the RUNBOOK order)"
  done
  resolve_snapshot
  prepare_restore_dir
  restic_restore restic-restore-full "$BACKUP_ROOT/staging/postgres" "$BACKUP_ROOT/staging/redis" "$SECRETS_ROOT" "${files[@]}"
  for f in "${files[@]}"; do
    [ -f "$RDIR$f" ] || fail host-files "the snapshot holds no $f"
    st="$(admin_state "$RDIR$f" "$f")"
    if [ "$st" != same ]; then differs=1; log "full: $f does not match the snapshot copy"; fi
  done
  if [ "$differs" -eq 1 ]; then refuse "the admin password files do not match the snapshot: run restore.sh host-files first (see the RUNBOOK order)"; fi
  if [ -d "$RDIR$SECRETS_ROOT" ]; then
    for d in "$RDIR$SECRETS_ROOT"/*; do
      [ -e "$d" ] || [ -L "$d" ] || continue
      app="${d##*/}"
      [[ "$app" =~ $APP_RE ]] || fail secrets "restored name '${app:0:40}' is not a valid app name" 2
      if [ -e "$SECRETS_ROOT/$app" ] || [ -L "$SECRETS_ROOT/$app" ]; then refuse "$SECRETS_ROOT/$app already exists; full restores only onto an empty stack"; fi
      check_secrets_src "$app"
      apps+=("$app")
    done
  fi
  full_prevalidate
  # Secrets first (the dumps and globals reference the roles whose passwords live there), then Postgres, then Redis.
  for app in "${apps[@]}"; do place_secrets "$app"; done
  restore_globals
  restore_databases
  pg_sql pg-revoke postgres - "REVOKE CONNECT ON DATABASE postgres, template1 FROM PUBLIC;"
  redis_load
  if [ -f "$INSTALL_DATA" ]; then
    step_io verify 600 - - "$INSTALL_DATA" verify
  else
    log "verify: skipped, $INSTALL_DATA is not present"
  fi
  echo "full restore done from snapshot $SNAP_ID"
}

main() {
  parse_args "$@"
  load_overrides
  require_root
  umask 077
  check_dirs
  # Under the root-only backup root, not /tmp: the filtered globals.sql holds role password hashes.
  WORK="$(mktemp -d -p "$BACKUP_ROOT" .restore-work.XXXXXX)"
  TIMED_LAST_FILE="$WORK/timed-last"
  trap on_exit EXIT
  trap 'on_signal TERM' TERM
  trap 'on_signal INT' INT
  init_logging
  log "start cmd=$CMD${APP:+ app=$APP}${INTO:+ into=$INTO} snapshot=$SNAP"
  load_env
  take_lock
  case "$CMD" in
    list) cmd_list ;;
    app) cmd_app ;;
    secrets) cmd_secrets ;;
    host-files) cmd_host_files ;;
    full) cmd_full ;;
    *) usage ;;
  esac
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
