#!/usr/bin/env bash
# platform-backup runner (root, host systemd oneshot or run by hand). Usage: backup.sh nightly|manual
#
# Framework (env, lock, logging, notify, state file, window, deadline) plus the data phases: preflight, pg-list,
# pg-globals, pg-db:<db>, redis, restic-backup, restic-forget, restic-check, volumes (see PHASES).
#
# Exit codes: 0 ok, 1 failed, 2 usage or env/override problem.
#
# Credentials: /etc/platform/backup.env is read by this script itself with a literal KEY=VALUE reader (never sourced;
# see read_backup_env). The systemd unit has no EnvironmentFile=, so nothing depends on the caller's environment.
#
# Test overrides (all optional, each read once at startup, default = production value, an unparsable value exits 2).
# They are honoured ONLY when PLATFORM_BACKUP_TESTING=1; otherwise every PLATFORM_BACKUP_* / PLATFORM_RESTORE_* variable
# is ignored (unset, named in a warning) and the production values apply. A BACKUP_ROOT other than the production one
# must hold a .platform-backup-root sentinel file before staging/ is wiped.
# restore.sh reads the same names except PLATFORM_BACKUP_DEADLINE_SECS:
#   PLATFORM_BACKUP_ENV_FILE            /etc/platform/backup.env
#   PLATFORM_BACKUP_ENV_OWNER           0:0   (numeric uid:gid the env file must have; mode 0600 and no-symlink never relax)
#   PLATFORM_BACKUP_ROOT                /var/lib/platform/backup   (staging/ and restore/)
#   PLATFORM_BACKUP_STATE_DIR           /var/lib/platform/backup-status   (last-run.tsv)
#   PLATFORM_BACKUP_LOG_DIR             /var/log/platform-backup
#   PLATFORM_BACKUP_LOCK                /run/platform-backup.lock
#   PLATFORM_BACKUP_SECRETS_ROOT        /var/lib/platform/secrets
#   PLATFORM_BACKUP_PG_ADMIN_FILE       /etc/platform/postgres-admin.password
#   PLATFORM_BACKUP_REDIS_ADMIN_FILE    /etc/platform/redis-admin.password
#   PLATFORM_BACKUP_PG_CONTAINER        platform-data-postgres
#   PLATFORM_BACKUP_REDIS_CONTAINER     platform-data-redis
#   PLATFORM_BACKUP_DEADLINE_SECS       4200  (backup.sh only; positive integer)
#
# The window (window.env beside this script) and the clock (now_epoch, now_iso, now_hhmm, window_file) are plain
# functions so a test can redefine them after sourcing this file; the BASH_SOURCE guard at the bottom keeps main from
# running on source, and a test may also replace PHASES with dummy phases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_KEYS=(RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION DISCORD_WEBHOOK)
RESTIC_REPOSITORY=""
RESTIC_PASSWORD=""
AWS_ACCESS_KEY_ID=""
AWS_SECRET_ACCESS_KEY=""
# Exported for restic and the S3 SDK (via ENV_KEYS) and set by read_backup_env, so shellcheck sees no direct use.
# shellcheck disable=SC2034
AWS_DEFAULT_REGION=""
DISCORD_WEBHOOK=""

# Phases run in order after env and lock. Each entry is a function that returns 0 on success; it runs its external
# calls through timed. A function named phase_<name> has the label <name> with _ shown as - (failed_phase, logs); a
# phase may refine CUR_PHASE (pg-db:<db>) and set PHASE_MSG for the failure text. run_phases calls each phase in a ||
# context, so errexit is OFF inside a phase body: a phase must check the rc of every timed call and return non-zero
# itself on failure.
PHASES=(phase_preflight phase_pg_list phase_pg_globals phase_pg_db phase_redis phase_restic_backup phase_restic_forget
  phase_restic_check phase_volumes)

NOTIFY_PHASE_SECS=30
UNLOCK_SECS=120
REDIS_PHASE_SECS=120
REDIS_CALL_SECS=30
# In-container path of the Redis admin password file (the data stack mounts it there; same constant as new-db.sh).
REDIS_CTR_ADMIN_FILE=/etc/platform/redis-admin.password
# Docker volumes that are backed up logically (dumps), so the volume inventory does not warn about them.
LOGICAL_VOLUMES=(platform-data-postgres platform-data-redis)
# Caller-environment variables that could redirect or re-credential restic or the S3 SDK: removed in phase_env.
SCRUB_ENV=(RESTIC_PASSWORD_FILE RESTIC_PASSWORD_COMMAND RESTIC_REPOSITORY_FILE RESTIC_FROM_REPOSITORY
  RESTIC_FROM_PASSWORD_FILE RESTIC_FROM_PASSWORD_COMMAND RESTIC_FROM_REPOSITORY_FILE RESTIC_KEY_HINT RESTIC_CACHE_DIR
  RESTIC_COMPRESSION RESTIC_PACK_SIZE RESTIC_READ_CONCURRENCY AWS_SESSION_TOKEN AWS_PROFILE AWS_SHARED_CREDENTIALS_FILE
  AWS_CONFIG_FILE AWS_ROLE_ARN AWS_WEB_IDENTITY_TOKEN_FILE AWS_REGION AWS_ENDPOINT_URL AWS_ENDPOINT_URL_S3)

# Identical to new-db.sh's and install-data.sh's REDIS_ADMIN_SNIPPET (a test compares all three): runs redis-cli as the
# admin user inside the Redis container, the password read from the mounted file and passed via REDISCLI_AUTH.
# shellcheck disable=SC2016 # expanded by the shell inside the container
readonly REDIS_ADMIN_SNIPPET='f="$1"; shift; pw="$(cat "$f"; printf x)"; pw="${pw%x}"; nl="$(printf "\nx")"; nl="${nl%x}"; case "$pw" in *"$nl") pw="${pw%"$nl"}" ;; esac; REDISCLI_AUTH="$pw" exec redis-cli --user admin --no-auth-warning "$@"'

PHASE_MSG=""
DBS=()
DB_COUNT=""
STAGING=""
BACKUP_DONE=0
REDIS_BOUND_END=0

RUN_MODE=""
RUN_START_EPOCH=""
RUN_START_ISO=""
DEADLINE_SECS=4200
CUR_PHASE="env"
FAIL_PHASE=""
FAIL_MSG=""
FAIL_DETAIL=""
SNAPSHOT_ID=""
NOTIFY_ENABLED=0
WARNINGS=()
WINDOW_OK=0
WINDOW_START=""
WINDOW_END=""
WINDOW_TZ=""
START_IN_WINDOW=-1
LOG_FILE=""
WORK=""
TIMED_LAST_FILE="/dev/null"
TIMED_PID=""
ENV_READ_ERROR=""

# ---- clock and window source (redefinable in tests) ----

now_epoch() { date +%s; }
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
now_hhmm() { TZ="$WINDOW_TZ" date +%H:%M; }
window_file() { printf '%s/window.env' "$SCRIPT_DIR"; }

# ---- masking and logging ----

# mask_text <text>: replaces every secret value with *** (values loaded from backup.env; empty values skipped).
mask_text() {
  local s="$1" v
  for v in "$RESTIC_REPOSITORY" "$RESTIC_PASSWORD" "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" "$DISCORD_WEBHOOK"; do
    if [ -n "$v" ]; then s=${s//"$v"/***}; fi
  done
  printf '%s' "$s"
}

# log <text>: timestamped, masked, to stdout (journald) and the dated file log.
log() {
  local line
  line="$(now_iso) $(mask_text "$*")"
  printf '%s\n' "$line"
  if [ -n "$LOG_FILE" ]; then printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true; fi
}

init_logging() {
  local created=0
  if [ ! -d "$LOG_DIR" ]; then created=1; fi
  if (umask 027 && mkdir -p -- "$LOG_DIR") 2>/dev/null; then
    if [ "$created" -eq 1 ]; then chmod 0750 -- "$LOG_DIR" 2>/dev/null || true; fi
    LOG_FILE="$LOG_DIR/$(date -u +%Y-%m-%d).log"
    if ! (umask 027 && : >> "$LOG_FILE") 2>/dev/null; then
      LOG_FILE=""
    else
      chmod 0640 -- "$LOG_FILE" 2>/dev/null || true
    fi
  fi
  if [ -z "$LOG_FILE" ]; then echo "WARN: cannot write a file log under $LOG_DIR; logging to stdout only" >&2; fi
  return 0
}

# prune_logs: keep the newest 30 dated logs always; older ones go only when also more than 30 days old.
prune_logs() {
  local f n=0
  [ -d "$LOG_DIR" ] || return 0
  while IFS= read -r f; do
    n=$((n + 1))
    if [ "$n" -gt 30 ] && [ -n "$(find "$f" -maxdepth 0 -mtime +30 2>/dev/null)" ]; then
      rm -f -- "$f"
      log "prune: removed old log $f"
    fi
  done < <(find "$LOG_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].log' | sort -r)
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

# gate_test_overrides: fail closed. The PLATFORM_BACKUP_* / PLATFORM_RESTORE_* overrides are test hooks (a different chown,
# data root, env file, ...); they are honoured only with PLATFORM_BACKUP_TESTING=1 and are otherwise unset (named in a
# warning, never their values), so a caller environment that leaks through sudo -E / env_keep cannot redirect a root run.
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
  ov_path STATE_DIR PLATFORM_BACKUP_STATE_DIR /var/lib/platform/backup-status
  ov_path LOG_DIR PLATFORM_BACKUP_LOG_DIR /var/log/platform-backup
  ov_path LOCK_FILE PLATFORM_BACKUP_LOCK /run/platform-backup.lock
  ov_path SECRETS_ROOT PLATFORM_BACKUP_SECRETS_ROOT /var/lib/platform/secrets
  ov_path PG_ADMIN_FILE PLATFORM_BACKUP_PG_ADMIN_FILE /etc/platform/postgres-admin.password
  ov_path REDIS_ADMIN_FILE PLATFORM_BACKUP_REDIS_ADMIN_FILE /etc/platform/redis-admin.password
  ov_name PG_CONTAINER PLATFORM_BACKUP_PG_CONTAINER platform-data-postgres
  ov_name REDIS_CONTAINER PLATFORM_BACKUP_REDIS_CONTAINER platform-data-redis
  # Honoured only when set; default 0:0. A set-but-malformed (or empty) value exits 2.
  ENV_OWNER="0:0"
  if [ -n "${PLATFORM_BACKUP_ENV_OWNER+x}" ]; then
    if [[ ! "$PLATFORM_BACKUP_ENV_OWNER" =~ ^[0-9]+:[0-9]+$ ]]; then
      echo "FATAL: PLATFORM_BACKUP_ENV_OWNER must match uid:gid (digits)" >&2
      exit 2
    fi
    ENV_OWNER="$PLATFORM_BACKUP_ENV_OWNER"
  fi
  if [ -n "${PLATFORM_BACKUP_DEADLINE_SECS+x}" ]; then
    if [[ ! "$PLATFORM_BACKUP_DEADLINE_SECS" =~ ^[1-9][0-9]{0,6}$ ]]; then
      echo "FATAL: PLATFORM_BACKUP_DEADLINE_SECS must be a positive integer (at most 7 digits)" >&2
      exit 2
    fi
    DEADLINE_SECS="$PLATFORM_BACKUP_DEADLINE_SECS"
  fi
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

# ---- JSON and notify ----

# json_escape <string>: JSON string body (no surrounding quotes), pure bash.
json_escape() {
  local s="$1" i c u
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  s=${s//$'\r'/\\r}
  for i in {1..31}; do
    if [ "$i" -eq 9 ] || [ "$i" -eq 10 ] || [ "$i" -eq 13 ]; then continue; fi
    printf -v c '%b' "\\0$(printf '%03o' "$i")"
    printf -v u '\\u%04x' "$i"
    s=${s//"$c"/$u}
  done
  printf '%s' "$s"
}

# notify <ok|failed> <text>: Discord post. Never changes the run's exit code.
notify() {
  local status="$1" text="$2" payload cfg hook rc=0 err
  text="platform-backup $status: $(mask_text "$text")"
  if [ "${#text}" -gt 1900 ]; then text="${text:0:1900}..."; fi
  if [ -z "$WORK" ] || [ ! -d "$WORK" ]; then
    WORK="$(mktemp -d)" || { log "notify: cannot create a work dir; webhook not sent"; return 0; }
    TIMED_LAST_FILE="$WORK/timed-last"
  fi
  payload="$WORK/payload.json"
  cfg="$WORK/curl.cfg"
  printf '{"content":"%s","allowed_mentions":{"parse":[]}}' "$(json_escape "$text")" > "$payload" \
    || { log "notify: cannot write the payload; webhook not sent"; return 0; }
  # The webhook URL is a secret: it goes through a 0600 curl config file, never argv (ps shows argv).
  hook=${DISCORD_WEBHOOK//\\/\\\\}
  hook=${hook//\"/\\\"}
  (umask 077 && printf 'url = "%s"\n' "$hook" > "$cfg") \
    || { log "notify: cannot write the curl config; webhook not sent"; return 0; }
  timed_fixed notify "$NOTIFY_PHASE_SECS" curl -fsS --max-time 30 -o /dev/null -K "$cfg" \
    -H 'Content-Type: application/json' --data-binary "@$payload" || rc=$?
  if [ "$rc" -ne 0 ]; then
    err="$(tr '\n' ' ' < "$TIMED_LAST_FILE" 2>/dev/null || true)"
    log "notify: webhook POST failed rc=$rc err=$(mask_text "$err")"
  fi
  return 0
}

# ---- timed ----

# timed <label> <secs> <cmd...>: runs the command under timeout, logs start/end (rc, duration), logs its masked
# output line by line (also kept in $TIMED_LAST_FILE), TIMED OUT at 124/137. The timeout is clamped to the time left
# before the total deadline; with none left the command is not started and the result is 124.
# timed_fixed is the same without the clamp (restic unlock, notify: they keep their own bound after the deadline).
timed() { _timed_run 1 "$@"; }
timed_fixed() { _timed_run 0 "$@"; }

# timed_io <label> <secs> <stdin-file|-> <stdout-file|-> <cmd...>: timed, with the command's stdin and stdout redirected
# on the host side (binary-safe, never through $()). "-" for stdin is /dev/null; "-" for stdout leaves it in the log.
timed_io() {
  local label="$1" secs="$2" in="$3" out="$4"
  shift 4
  # shellcheck disable=SC2016 # the body is a literal for sh -c
  timed "$label" "$secs" sh -c 'i="$1"; o="$2"; shift 2; if [ "$i" = - ]; then i=/dev/null; fi; exec < "$i"; if [ "$o" != - ]; then exec > "$o"; fi; exec "$@"' sh "$in" "$out" "$@"
}

_timed_run() {
  local clamp="$1" label="$2" secs="$3" t0 rc=0 remain line
  shift 3
  : > "$TIMED_LAST_FILE" 2>/dev/null || true
  if [ "$clamp" -eq 1 ] && [ -n "$RUN_START_EPOCH" ]; then
    remain=$((DEADLINE_SECS - ($(now_epoch) - RUN_START_EPOCH)))
    if [ "$remain" -le 0 ]; then
      log "phase=$label start timeout=0s"
      log "phase=$label TIMED OUT (total deadline of ${DEADLINE_SECS}s already reached)"
      log "phase=$label end rc=124 dur=0s"
      return 124
    fi
    if [ "$remain" -lt "$secs" ]; then secs="$remain"; fi
  fi
  t0="$(now_epoch)"
  # Background + wait so a trapped TERM/INT interrupts at once instead of waiting for a long foreground child. fd 9
  # (the lock) is closed in the child so an orphan can never keep the lock held.
  (
    set +e
    exec 9>&-
    timeout -s TERM -k 30 "$secs" "$@" 2>&1 | while IFS= read -r line || [ -n "$line" ]; do
      line="$(mask_text "$line")"
      log "$label: $line"
      printf '%s\n' "$line" >> "$TIMED_LAST_FILE" 2>/dev/null
    done
    exit "${PIPESTATUS[0]}"
  ) &
  TIMED_PID=$!
  # Logged after the fork and after TIMED_PID is set: a TERM seen once this line is out always finds the child.
  log "phase=$label start timeout=${secs}s"
  wait "$TIMED_PID" || rc=$?
  TIMED_PID=""
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then log "phase=$label TIMED OUT after ${secs}s"; fi
  log "phase=$label end rc=$rc dur=$(($(now_epoch) - t0))s"
  return "$rc"
}

# ---- state file ----

# write_state <ok|failed>: last-run.tsv, atomically, in the 0755 backup-status dir.
write_state() {
  local result="$1" end_iso
  end_iso="$(now_iso)"
  # The subshell is the left side of ||, so errexit is off inside it: every step checks itself and fails the subshell.
  (
    local tmp=""
    umask 022
    if [ ! -d "$STATE_DIR" ]; then
      mkdir -p -- "$STATE_DIR" || exit 1
      chmod 0755 -- "$STATE_DIR" || exit 1
    fi
    tmp="$(mktemp "$STATE_DIR/.last-run.XXXXXX")" || exit 1
    if ! { printf '%s\t%s\t%s\t%s\t%s\n' "$RUN_START_ISO" "$end_iso" "$result" "${SNAPSHOT_ID:--}" "${FAIL_PHASE:--}" > "$tmp" \
      && chmod 0644 -- "$tmp" && mv -f -- "$tmp" "$STATE_DIR/last-run.tsv"; }; then
      rm -f -- "$tmp"
      exit 1
    fi
  ) || log "WARN: could not write $STATE_DIR/last-run.tsv"
  return 0
}

# ---- window ----

# load_window: literal read of window.env (START, END, TZ); on any problem the window warnings are disabled, loudly.
load_window() {
  local f line key val seen=" " s="" e="" z=""
  WINDOW_OK=0
  f="$(window_file)"
  if [ ! -f "$f" ]; then log "WARN: window file $f missing; window warnings disabled"; return 0; fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    case "$line" in *=*) ;; *) log "WARN: window file has a malformed line; window warnings disabled"; return 0 ;; esac
    key="${line%%=*}"
    val="${line#*=}"
    case "$seen" in *" $key "*) log "WARN: window file repeats $key; window warnings disabled"; return 0 ;; esac
    seen="$seen$key "
    case "$key" in
      BACKUP_WINDOW_START) s="$val" ;;
      BACKUP_WINDOW_END) e="$val" ;;
      BACKUP_WINDOW_TZ) z="$val" ;;
      *) log "WARN: window file has an unknown key; window warnings disabled"; return 0 ;;
    esac
  done < "$f"
  if [[ ! "$s" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] || [[ ! "$e" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]] \
    || [[ ! "$z" =~ ^[A-Za-z0-9_/+-]+$ ]] || [[ ! "$s" < "$e" ]]; then
    log "WARN: window file values invalid; window warnings disabled"
    return 0
  fi
  WINDOW_START="$s"
  WINDOW_END="$e"
  WINDOW_TZ="$z"
  WINDOW_OK=1
  return 0
}

window_check_start() {
  local h
  if [ "$RUN_MODE" != "nightly" ] || [ "$WINDOW_OK" -ne 1 ]; then return 0; fi
  h="$(now_hhmm)"
  if [[ "$h" < "$WINDOW_START" ]] || [[ ! "$h" < "$WINDOW_END" ]]; then
    START_IN_WINDOW=0
    WARNINGS+=("started outside backup window")
    log "window: run started at $h, outside [$WINDOW_START,$WINDOW_END) $WINDOW_TZ"
  else
    START_IN_WINDOW=1
  fi
  return 0
}

window_check_end() {
  local h
  if [ "$RUN_MODE" != "nightly" ] || [ "$WINDOW_OK" -ne 1 ] || [ "$START_IN_WINDOW" -ne 1 ]; then return 0; fi
  h="$(now_hhmm)"
  if [[ ! "$h" < "$WINDOW_END" ]]; then
    WARNINGS+=("overran backup window")
    log "window: run ended at $h, after $WINDOW_END $WINDOW_TZ"
  fi
  return 0
}

# ---- exit path ----

die_phase() { # <phase> <exit code> <message>
  FAIL_PHASE="$1"
  FAIL_MSG="$3"
  exit "$2"
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
  log "signal $1 received during phase=${CUR_PHASE:-unknown}"
  kill_timed_child
  FAIL_PHASE="${CUR_PHASE:-unknown}"
  FAIL_MSG="terminated by SIG$1"
  exit 1
}

# on_exit: the single exit path (normal end, die_phase, signal, crash under set -e). Writes the state file and posts
# exactly one notify, then cleans up. Exempt from the deadline clamp.
on_exit() {
  local rc=$? result=ok text dur w
  trap - EXIT TERM INT
  set +e # nothing in the exit path may abort it: state and notify are best effort, the exit code is rc
  if [ "$rc" -ne 0 ] || [ -n "$FAIL_PHASE" ]; then
    result=failed
    if [ -z "$FAIL_PHASE" ]; then
      FAIL_PHASE="${CUR_PHASE:-unknown}"
      FAIL_MSG="unexpected exit rc=$rc"
    fi
    if [ "$rc" -eq 0 ]; then rc=1; fi
  fi
  window_check_end
  # Dumps must not sit on disk once the snapshot exists (also after a later forget/check failure); before that the
  # staging dir is kept for diagnosis and wiped by the next run.
  if [ "$BACKUP_DONE" -eq 1 ] && [ -n "$STAGING" ]; then rm -rf -- "$STAGING"; fi
  dur=$(($(now_epoch) - RUN_START_EPOCH))
  log "run end mode=$RUN_MODE result=$result rc=$rc dur=${dur}s${FAIL_PHASE:+ failed_phase=$FAIL_PHASE}${FAIL_MSG:+ msg=$FAIL_MSG}"
  write_state "$result"
  if [ "$NOTIFY_ENABLED" -eq 1 ] && [ -n "$DISCORD_WEBHOOK" ]; then
    if [ "$result" = ok ]; then
      text="$RUN_MODE run ok in ${dur}s, snapshot ${SNAPSHOT_ID:--}${DB_COUNT:+, databases $DB_COUNT}"
    else
      text="$RUN_MODE run FAILED at phase ${FAIL_PHASE}: ${FAIL_MSG}"
      if [ -n "$FAIL_DETAIL" ]; then text="$text"$'\n'"$FAIL_DETAIL"; fi
    fi
    if [ "${#WARNINGS[@]}" -gt 0 ]; then
      text="$text"$'\n'"warning:"
      for w in "${WARNINGS[@]}"; do text="$text $w;"; done
    fi
    notify "$result" "$text"
  fi
  if [ -n "$WORK" ] && [ -d "$WORK" ]; then rm -rf -- "$WORK"; fi
  exit "$rc"
}

# ---- framework phases ----

# phase_env: read and validate backup.env. Failure: state failed (failed_phase=env), exit 2, NO webhook call.
phase_env() {
  local k missing=""
  CUR_PHASE="env"
  log "phase=env start"
  # Whatever the caller's environment holds (a hand run without sudo) must not reach restic or the S3 SDK.
  unset "${SCRUB_ENV[@]}" DOCKER_HOST DOCKER_CONTEXT DOCKER_CONFIG
  while IFS= read -r k; do
    case "$k" in RESTIC_* | AWS_* | RCLONE_*) unset "$k" ;; esac
  done < <(compgen -e)
  if ! read_backup_env "$ENV_FILE" "$ENV_OWNER"; then
    log "FATAL: $ENV_READ_ERROR"
    die_phase env 2 "$ENV_READ_ERROR"
  fi
  for k in "${ENV_KEYS[@]}"; do
    if [ -z "${!k}" ]; then missing="${missing:+$missing }$k"; fi
  done
  if [ -n "$missing" ]; then
    log "FATAL: missing required env var(s): $missing"
    die_phase env 2 "missing required env var(s): $missing"
  fi
  export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION
  # restic --json status lines are logged one per line: ask for about one per minute.
  export RESTIC_PROGRESS_FPS=0.0166
  NOTIFY_ENABLED=1
  log "phase=env end rc=0"
}

# phase_lock: flock -n on the shared lock (fd 9, held until the process exits).
phase_lock() {
  CUR_PHASE=lock
  log "phase=lock start"
  # LOCK_FILE is assigned by ov_path (printf -v) in load_overrides.
  # shellcheck disable=SC2153
  if ! exec 9> "$LOCK_FILE"; then
    log "FATAL: cannot open lock file $LOCK_FILE"
    die_phase lock 1 "cannot open lock file"
  fi
  if ! flock -n 9; then
    log "state lock-held"
    die_phase lock 1 "another backup or restore holds the lock"
  fi
  log "phase=lock end rc=0"
}

# ---- data phases ----

# prepare_staging: wipe and recreate staging/ (root 0700). Runs under the lock, before pg-list.
prepare_staging() {
  if [ "$BACKUP_ROOT" = "/" ]; then log "FATAL: PLATFORM_BACKUP_ROOT must not be /"; return 1; fi
  # Fail closed: a recursive delete only under the production root or a root that carries the sentinel file.
  if [ "$BACKUP_ROOT" != "/var/lib/platform/backup" ] && { [ ! -f "$BACKUP_ROOT/.platform-backup-root" ] || [ -L "$BACKUP_ROOT/.platform-backup-root" ]; }; then
    log "FATAL: refusing to wipe $BACKUP_ROOT/staging: $BACKUP_ROOT is not /var/lib/platform/backup and has no .platform-backup-root sentinel file"
    return 1
  fi
  STAGING="$BACKUP_ROOT/staging"
  rm -rf -- "$STAGING" || return 1
  (umask 077 && mkdir -p -- "$STAGING/postgres" "$STAGING/redis") || return 1
  chmod 0700 -- "$BACKUP_ROOT" "$STAGING" "$STAGING/postgres" "$STAGING/redis" || return 1
  log "staging: wiped and recreated $STAGING"
}

# restic_timed <label> <secs> <restic args...>: timed restic call; a timeout (124/137, including one clamped to the
# deadline) runs `restic unlock` (timed_fixed: exempt from the clamp, own 120s bound) and is reported as 124.
restic_timed() {
  local label="$1" secs="$2" rc=0 keep
  shift 2
  timed "$label" "$secs" restic "$@" || rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    keep="$(cat "$TIMED_LAST_FILE" 2>/dev/null || true)"
    timed_fixed restic-unlock "$UNLOCK_SECS" restic unlock || log "WARN: restic unlock failed after $label timed out"
    printf '%s\n' "$keep" > "$TIMED_LAST_FILE" 2>/dev/null || true
    rc=124
  fi
  return "$rc"
}

phase_preflight() {
  local rc=0
  timed_io preflight 60 - /dev/null restic cat config || rc=$?
  if [ "$rc" -ne 0 ]; then PHASE_MSG="repository unreachable or not initialised"; fi
  return "$rc"
}

# phase_pg_list: stage dir wiped first, then the database list; every name is validated before it can become a path.
phase_pg_list() {
  local f="$WORK/dblist" rc=0 line shown
  if ! prepare_staging; then PHASE_MSG="cannot prepare the staging dir"; return 1; fi
  timed_io pg-list 60 - "$f" docker exec "$PG_CONTAINER" psql -X -U postgres -d postgres -At -v ON_ERROR_STOP=1 \
    -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1" || rc=$?
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  DBS=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -z "$line" ]; then continue; fi
    if [[ ! "$line" =~ ^[a-z][a-z0-9_]{1,30}$ ]]; then
      shown="$(printf '%q' "${line:0:60}")"
      log "pg-list: database name fails validation: $shown"
      PHASE_MSG="database name fails validation: $shown"
      return 1
    fi
    DBS+=("$line")
  done < "$f"
  DB_COUNT="${#DBS[@]}"
  log "state databases=$DB_COUNT"
  return 0
}

phase_pg_globals() {
  local rc=0
  timed_io pg-globals 60 - "$STAGING/postgres/globals.sql" docker exec "$PG_CONTAINER" pg_dumpall -U postgres --globals-only || rc=$?
  return "$rc"
}

# phase_pg_db: one custom-format dump per listed database, redirected on the host, then pg_restore --list reads it.
phase_pg_db() {
  local db rc dump
  for db in "${DBS[@]}"; do
    CUR_PHASE="pg-db:$db"
    dump="$STAGING/postgres/$db.dump"
    rc=0
    timed_io "pg-db:$db" 600 - "$dump" docker exec "$PG_CONTAINER" pg_dump -U postgres -Fc -d "$db" || rc=$?
    if [ "$rc" -ne 0 ]; then return "$rc"; fi
    timed_io "pg-db:$db:verify" 600 "$dump" /dev/null docker exec -i "$PG_CONTAINER" pg_restore --list || rc=$?
    if [ "$rc" -ne 0 ]; then PHASE_MSG="pg_restore --list failed on the dump (rc=$rc)"; return "$rc"; fi
  done
  return 0
}

# poll_sleep: one pause between Redis polls (a function so tests can advance the stubbed clock instead of sleeping).
poll_sleep() { sleep 2; }

# redis_cli <label> <outfile> <redis-cli args...>: one admin redis-cli call, bounded by the phase bound and the per-call cap.
redis_cli() {
  local label="$1" out="$2" left secs
  shift 2
  left=$((REDIS_BOUND_END - $(now_epoch)))
  if [ "$left" -le 0 ]; then : > "$TIMED_LAST_FILE" 2>/dev/null || true; return 124; fi
  secs="$REDIS_CALL_SECS"
  if [ "$left" -lt "$secs" ]; then secs="$left"; fi
  timed_io "redis:$label" "$secs" - "$out" docker exec -i "$REDIS_CONTAINER" sh -c "$REDIS_ADMIN_SNIPPET" sh "$REDIS_CTR_ADMIN_FILE" "$@"
}

# _redis_run: BGSAVE and wait for a finished save, then copy dump.rdb and users.acl. Returns 124 at the bound.
_redis_run() {
  local f="$WORK/redis-out" l0 l line inprog status rc=0 stage="$STAGING/redis"
  redis_cli lastsave "$f" LASTSAVE || rc=$?
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  l0="$(tr -d '\r\n' < "$f")"
  if [[ ! "$l0" =~ ^[0-9]+$ ]]; then PHASE_MSG="unexpected LASTSAVE reply"; return 1; fi
  redis_cli bgsave "$f" BGSAVE || rc=$?
  # A save already running (redis-cli may exit non-zero on that error reply) or scheduled behind an AOF rewrite is
  # waited for like our own: the poll below needs LASTSAVE to change and a finished, ok save.
  if grep -qE 'Background saving started|Background saving scheduled|already in progress' "$f"; then
    rc=0
  elif [ "$rc" -ne 0 ]; then
    return "$rc"
  else
    PHASE_MSG="BGSAVE refused"
    return 1
  fi
  while :; do
    rc=0
    redis_cli lastsave "$f" LASTSAVE || rc=$?
    if [ "$rc" -ne 0 ]; then return "$rc"; fi
    l="$(tr -d '\r\n' < "$f")"
    redis_cli info "$f" INFO persistence || rc=$?
    if [ "$rc" -ne 0 ]; then return "$rc"; fi
    inprog=""
    status=""
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      case "$line" in
        rdb_bgsave_in_progress:*) inprog="${line#*:}" ;;
        rdb_last_bgsave_status:*) status="${line#*:}" ;;
      esac
    done < "$f"
    if [ "$inprog" = "0" ]; then
      # The status reports the PREVIOUS save until the new one finishes, so it counts only when nothing is running.
      if [ "$status" = "err" ]; then PHASE_MSG="redis BGSAVE failed (rdb_last_bgsave_status:err)"; return 1; fi
      if [ "$status" = "ok" ] && [[ "$l" =~ ^[0-9]+$ ]] && [ "$l" != "$l0" ]; then break; fi
    fi
    poll_sleep
  done
  rc=0
  timed "redis:cp-rdb" 60 docker cp "$REDIS_CONTAINER:/data/dump.rdb" "$stage/dump.rdb" || rc=$?
  if [ "$rc" -ne 0 ]; then return "$rc"; fi
  timed "redis:cp-acl" 60 docker cp "$REDIS_CONTAINER:/data/users.acl" "$stage/users.acl" || rc=$?
  return "$rc"
}

phase_redis() {
  local t0 rc=0 remain
  t0="$(now_epoch)"
  REDIS_BOUND_END=$((t0 + REDIS_PHASE_SECS))
  remain=$((DEADLINE_SECS - (t0 - RUN_START_EPOCH)))
  if [ "$((t0 + remain))" -lt "$REDIS_BOUND_END" ]; then REDIS_BOUND_END=$((t0 + remain)); fi
  log "phase=redis start timeout=$((REDIS_BOUND_END - t0))s"
  _redis_run || rc=$?
  if [ "$rc" -eq 124 ]; then log "phase=redis TIMED OUT after $(($(now_epoch) - t0))s"; fi
  log "phase=redis end rc=$rc dur=$(($(now_epoch) - t0))s"
  return "$rc"
}

phase_restic_backup() {
  local rc=0 line sid="" sum_re='"message_type":"summary"' id_re='"snapshot_id":"([0-9a-f]{8,64})"'
  restic_timed restic-backup 3600 backup --json --host platform --tag platform --tag "$RUN_MODE" \
    --exclude '.*.lock' --exclude '.tmp.*' "$STAGING" "$SECRETS_ROOT" "$PG_ADMIN_FILE" "$REDIS_ADMIN_FILE" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" -ne 3 ]; then return "$rc"; fi
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ $sum_re ]] && [[ "$line" =~ $id_re ]]; then sid="${BASH_REMATCH[1]}"; fi
  done < "$TIMED_LAST_FILE"
  if [ "$rc" -eq 3 ]; then
    # restic exit 3: the snapshot exists but some files were unreadable. The run fails (staging kept), and the state
    # file and notify still name the snapshot.
    if [ -n "$sid" ]; then SNAPSHOT_ID="$sid"; fi
    PHASE_MSG="restic backup incomplete, some files unreadable"
    return 3
  fi
  if [ -z "$sid" ]; then PHASE_MSG="restic backup printed no summary snapshot id"; return 1; fi
  SNAPSHOT_ID="$sid"
  BACKUP_DONE=1
  log "state snapshot=$SNAPSHOT_ID"
  return 0
}

phase_restic_forget() {
  restic_timed restic-forget 1800 forget --prune --host platform --tag platform --group-by host \
    --keep-daily 7 --keep-weekly 4 --keep-monthly 6
}

phase_restic_check() {
  restic_timed restic-check 600 check
}

# phase_volumes: warn-only inventory of Docker volumes that no phase backs up.
phase_volumes() {
  local f="$WORK/volumes" rc=0 v skip names="" k
  timed_io volumes 60 - "$f" docker volume ls --format '{{.Name}}' || rc=$?
  if [ "$rc" -ne 0 ]; then
    WARNINGS+=("volume inventory failed")
    return 0
  fi
  while IFS= read -r v || [ -n "$v" ]; do
    if [ -z "$v" ] || [[ "$v" =~ ^[0-9a-f]{64}$ ]]; then continue; fi
    skip=0
    for k in "${LOGICAL_VOLUMES[@]}"; do if [ "$v" = "$k" ]; then skip=1; fi; done
    if [ "$skip" -eq 0 ]; then names="${names:+$names }$v"; fi
  done < "$f"
  if [ -n "$names" ]; then
    WARNINGS+=("not backed up: $names")
    log "volumes: not backed up: $names"
  fi
  return 0
}

run_phases() {
  local p rc label detail
  for p in "${PHASES[@]}"; do
    label="$p"
    if [[ "$p" == phase_* ]]; then label="${p#phase_}"; label="${label//_/-}"; fi
    if [ $(($(now_epoch) - RUN_START_EPOCH)) -ge "$DEADLINE_SECS" ]; then
      log "phase=$label not started: total deadline of ${DEADLINE_SECS}s reached"
      die_phase "$label" 1 "deadline exceeded"
    fi
    CUR_PHASE="$label"
    PHASE_MSG=""
    rc=0
    "$p" || rc=$?
    if [ "$rc" -ne 0 ]; then
      detail="$(tail -n 3 "$TIMED_LAST_FILE" 2>/dev/null || true)"
      detail="$(mask_text "$detail")"
      FAIL_DETAIL="${detail:0:500}"
      if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then die_phase "$CUR_PHASE" 1 "TIMED OUT rc=$rc"; fi
      die_phase "$CUR_PHASE" 1 "${PHASE_MSG:-phase failed} rc=$rc"
    fi
  done
}

usage() {
  echo "usage: backup.sh nightly|manual" >&2
}

main() {
  local mode="${1:-}"
  case "$mode" in
    nightly | manual) ;;
    *) usage; exit 2 ;;
  esac
  load_overrides
  umask 077 # dumps, staged files and the work dir are root-only
  RUN_MODE="$mode"
  RUN_START_EPOCH="$(now_epoch)"
  RUN_START_ISO="$(now_iso)"
  trap on_exit EXIT
  trap 'on_signal TERM' TERM
  trap 'on_signal INT' INT
  WORK="$(mktemp -d)"
  TIMED_LAST_FILE="$WORK/timed-last"
  init_logging
  prune_logs
  log "run start mode=$mode deadline=${DEADLINE_SECS}s"
  load_window
  window_check_start
  phase_env
  phase_lock
  run_phases
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
