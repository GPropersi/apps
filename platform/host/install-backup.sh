#!/usr/bin/env bash
# install-backup.sh: install and check the nightly backup to R2 on the app host (run yourself, not Claude).
#
# A root systemd oneshot (platform-backup.service, started by platform-backup.timer) dumps Postgres, snapshots Redis and
# sends the dumps, the secrets root and the two admin password files to a restic repository in R2. See
# platform/backup/README.md and RUNBOOK.md. This installer places the pieces; it never runs a backup by itself.
#
# Host-side input (you create it; the installer never writes a secret):
#   /etc/platform/backup.env   root:root 0600, the six keys RESTIC_REPOSITORY, RESTIC_PASSWORD, AWS_ACCESS_KEY_ID,
#                              AWS_SECRET_ACCESS_KEY, AWS_DEFAULT_REGION, DISCORD_WEBHOOK as literal KEY=VALUE lines
#                              (no quotes). It is read by name only with the same literal reader backup.sh uses; a value
#                              is never printed.
# For `install` the data stack (make host-data) and both admin password files must already exist; `restore-only` needs
# neither, so a rebuilt host can install the restore tooling first.
# The installer creates (as root, explicit owners and modes, never relying on umask):
#   /opt/platform/backup          root:root 0755: backup.sh, restore.sh 0755; window.env, restic.sha256 0644
#   /usr/local/bin/restic         root:root 0755: the pinned upstream release, sha256-checked before it is installed
#   /var/lib/platform             root:root 0755 (when absent)
#   /var/lib/platform/backup      root:root 0700 (staging and restore work area)
#   /var/lib/platform/backup-status  root:root 0755 (install only; holds last-run.tsv for non-root readers)
#   /var/log/platform-backup      root:root 0750
#   install only: /etc/systemd/system/platform-backup.service and platform-backup.timer (0644), then daemon-reload and
#   `enable --now platform-backup.timer`. The service itself is never started here (the timer is Persistent=true, so a
#   catch-up run can fire when the timer is enabled; it takes the shared lock and is flagged as outside the window).
#
# The payload files (backup.sh, restore.sh, window.env, the service and the timer) are embedded below
# (BEGIN-PAYLOAD/END-PAYLOAD) because the host has no checkout: `platform/lint/embed-payloads.sh` regenerates them from
# the tracked sources (`make embed`) and `make lint` fails if they differ. The timer source has its own file name
# (platform-backup-timer.timer) and is installed as platform-backup.timer. restic.sha256 records the sha256 of the
# installed binary, written only after the downloaded archive matched the pinned checksum; verify compares against it.
#
# Usage: install-backup.sh [install|restore-only|status|verify|run-now|init-repo] [--host ALIAS]
#   install       check every precondition first (backup.env, data stack, secrets root, admin files, curl/flock/timeout/
#                 bunzip2) and report all problems together; nothing is written until they all pass. Idempotent: a
#                 second run prints only "already:" lines and makes no download and no systemctl enable.
#   restore-only  restic, /opt/platform/backup and the three work directories only; no unit, no timer, nothing enabled.
#   status        report every check (PASS/FAIL/WARN), exit 0
#   verify        the same checks, exit 1 on any FAIL (a WARN never changes the status)
#   run-now       run `backup.sh manual` under systemd-run with the nightly's resource properties; output streams back
#   init-repo     run `restic init` once; refuses when `restic cat config` already succeeds (never automatic)
#   --host        stream this script over one `ssh -o BatchMode=yes -- ALIAS bash -s -- MODE` call (passwordless sudo needed).
#
# Exit: 0 ok | 1 failed check, wrong state or unusable input | 2 usage error or unusable backup.env. ssh failures pass
# through ssh's status.
#
# Test overrides (env, test-only): INSTALL_BACKUP_ROOT (path prefix for every default host path), INSTALL_BACKUP_SUDO
# (the privilege prefix; "sudo -n" by default, none when already root), INSTALL_BACKUP_TOOLS (the required commands),
# and per-path overrides, absolute and not prefixed by the root: INSTALL_BACKUP_DIR, INSTALL_BACKUP_VAR_DIR,
# INSTALL_BACKUP_WORK_DIR, INSTALL_BACKUP_STATE_DIR, INSTALL_BACKUP_LOG_DIR, INSTALL_BACKUP_ENV_FILE,
# INSTALL_BACKUP_SECRETS_ROOT, INSTALL_BACKUP_PG_ADMIN_FILE, INSTALL_BACKUP_REDIS_ADMIN_FILE, INSTALL_BACKUP_DATA_DIR,
# INSTALL_BACKUP_UNIT_DIR, INSTALL_BACKUP_RESTIC_BIN, INSTALL_BACKUP_JOURNAL_DIR. The curl, bunzip2, sha256sum, stat,
# install, chown, systemctl and systemd-run commands are the ones on PATH, so a test puts stubs there.
set -euo pipefail

export LC_ALL=C
# systemctl and friends may live in /usr/sbin, which a non-root ssh user's PATH can lack
export PATH="$PATH:/usr/sbin:/sbin"

# SHA256SUMS of restic_0.18.1_linux_arm64.bz2 (the release's SHA256SUMS file, tag v0.18.1): the archive, not the binary.
readonly RESTIC_SHA256="87f53fddde38764095e9c058a3b31834052c37e5826d2acf34e18923c006bd45"
readonly RESTIC_FILE="restic_0.18.1_linux_arm64.bz2"
readonly RESTIC_URL="https://github.com/restic/restic/releases/download/v0.18.1/restic_0.18.1_linux_arm64.bz2"
# What `restic version` must start with (the pinned 0.18.1).
readonly RESTIC_VERSION_PREFIX="restic 0.18.1 "
readonly STALE_SECS=129600
readonly ACCURACY_SECS=60
# The properties of platform-backup.service, repeated for run-now (a static test compares them to the unit). Type=oneshot is
# required: a transient unit defaults to Type=simple, for which TimeoutStartSec would not bound the run.
readonly RUN_PROPS=(Type=oneshot Nice=10 IOSchedulingClass=idle MemoryHigh=384M MemoryMax=512M TimeoutStartSec=4500 After=docker.service Requires=docker.service)

ROOT="${INSTALL_BACKUP_ROOT:-}"
OPT_DIR="${INSTALL_BACKUP_DIR:-$ROOT/opt/platform/backup}"
VAR_DIR="${INSTALL_BACKUP_VAR_DIR:-$ROOT/var/lib/platform}"
WORK_DIR="${INSTALL_BACKUP_WORK_DIR:-$VAR_DIR/backup}"
STATE_DIR="${INSTALL_BACKUP_STATE_DIR:-$VAR_DIR/backup-status}"
LOG_DIR="${INSTALL_BACKUP_LOG_DIR:-$ROOT/var/log/platform-backup}"
ENV_FILE="${INSTALL_BACKUP_ENV_FILE:-$ROOT/etc/platform/backup.env}"
SECRETS_DIR="${INSTALL_BACKUP_SECRETS_ROOT:-$VAR_DIR/secrets}"
PG_ADMIN_FILE="${INSTALL_BACKUP_PG_ADMIN_FILE:-$ROOT/etc/platform/postgres-admin.password}"
REDIS_ADMIN_FILE="${INSTALL_BACKUP_REDIS_ADMIN_FILE:-$ROOT/etc/platform/redis-admin.password}"
DATA_DIR="${INSTALL_BACKUP_DATA_DIR:-$ROOT/opt/platform/data}"
UNIT_DIR="${INSTALL_BACKUP_UNIT_DIR:-$ROOT/etc/systemd/system}"
RESTIC_BIN="${INSTALL_BACKUP_RESTIC_BIN:-$ROOT/usr/local/bin/restic}"
JOURNAL_DIR="${INSTALL_BACKUP_JOURNAL_DIR:-$ROOT/var/log/journal}"
TOOLS="${INSTALL_BACKUP_TOOLS:-curl flock timeout bunzip2}"
ENV_OWNER="0:0"
SERVICE_NAME="platform-backup.service"
TIMER_NAME="platform-backup.timer"

if [ -n "${INSTALL_BACKUP_SUDO+set}" ]; then
  read -r -a SUDO <<<"$INSTALL_BACKUP_SUDO"
elif [ "$EUID" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo -n)
fi

FAILURES=0
CHANGED=0
LAST_PLACED=0
FETCHED=0
TMP=""
PROBLEMS=()

info() { printf '%s\n' "$1"; }
err() { printf '%s\n' "$1" >&2; }
pass() { printf 'PASS: %s\n' "$1"; }
warn() { printf 'WARN: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
die() { err "install-backup: $1"; exit "${2:-1}"; }

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

# priv <cmd...>: run with privilege; stdin is never forwarded (this script may itself be read from stdin).
priv() { "${SUDO[@]}" "$@" </dev/null; }
sc() { priv systemctl "$@"; }

require_privilege() {
  priv true || die "no usable privilege (sudo -n failed). Over --host the account needs passwordless sudo; otherwise copy this script to the host and run it there directly"
}

# ---- literal env reader (BYTE-IDENTICAL in every script that carries a copy: backup.sh, restore.sh, install-backup.sh) ----
# The function is only ever run inside a privileged bash (its source is passed through `declare -f`), never directly.
# shellcheck disable=SC2329,SC2034
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

# The reader runs inside a privileged bash (backup.env is root-only); its source text is passed as the -c script.
READER_FN="$(declare -f read_backup_env)"

# shellcheck disable=SC2016 # the -c script is a literal for the privileged bash
# env_problem: succeeds when backup.env passes the reader. Otherwise prints the reason (never a value) and fails.
env_problem() {
  local why
  if why="$(priv bash -c "$READER_FN"'
read_backup_env "$1" "$2" || { printf "%s" "$ENV_READ_ERROR"; exit 1; }
for k in RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION DISCORD_WEBHOOK; do
  [ -n "${!k}" ] || { printf "%s" "env file does not define $k"; exit 1; }
done' bash "$ENV_FILE" "$ENV_OWNER")"; then
    return 0
  fi
  printf '%s' "${why:-cannot read backup.env}"
  return 1
}

# shellcheck disable=SC2016 # the -c script is a literal for the privileged bash
# with_env <cmd...>: run the command as root with the six keys read by the shared reader and exported (values never
# printed, never in an argv).
with_env() {
  priv bash -c "$READER_FN"'
read_backup_env "$1" "$2" || { printf "%s\n" "install-backup: backup.env: $ENV_READ_ERROR" >&2; exit 2; }
shift 2
export RESTIC_REPOSITORY RESTIC_PASSWORD AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION DISCORD_WEBHOOK
exec "$@"' bash "$ENV_FILE" "$ENV_OWNER" "$@"
}

# ---- embedded payloads (regenerated by platform/lint/embed-payloads.sh; do not edit between the markers) ----

# BEGIN-PAYLOAD platform/backup/backup.sh
payload_backup() {
  cat <<'PLATFORM_PAYLOAD_EOF'
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
PRE_SNAP_COUNT=""
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
  local rc=0 line sid="" sum_re='"message_type":"summary"' id_re='"snapshot_id":"([0-9a-f]{8,64})"' pre="$WORK/snapshots-before"
  # The snapshot count before this backup is the reference the forget guard compares against (unknown on a failed listing).
  PRE_SNAP_COUNT=""
  if timed_io restic-snapshots-pre 120 - "$pre" restic snapshots --json --host platform --tag platform; then
    PRE_SNAP_COUNT="$(count_snapshots "$(< "$pre")")"
  else
    log "WARN: cannot count the snapshots before the backup; the forget guard checks only that the new snapshot is listed"
  fi
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

# count_snapshots <restic snapshots --json body>: the number of snapshots listed (one "short_id" key each).
count_snapshots() {
  local s="$1" n=0 key='"short_id":"'
  while [[ "$s" == *"$key"* ]]; do
    n=$((n + 1))
    s="${s#*"$key"}"
  done
  printf '%s' "$n"
}

# phase_restic_forget: `forget --prune` deletes history, so it runs only when the repository provably holds the snapshot
# this run just created and at least one more snapshot than before the backup (guards a bad clock, a tag/host mismatch or
# a truncated listing from aging out everything). Otherwise it is skipped, the reason is logged and the run fails.
phase_restic_forget() {
  local f="$WORK/snapshots-after" rc=0 body n
  timed_io restic-snapshots 120 - "$f" restic snapshots --json --host platform --tag platform || rc=$?
  if [ "$rc" -ne 0 ]; then
    PHASE_MSG="forget skipped: cannot list the snapshots to verify the new one"
    log "WARN: $PHASE_MSG (rc=$rc)"
    return "$rc"
  fi
  body="$(< "$f")"
  n="$(count_snapshots "$body")"
  if [ -z "$SNAPSHOT_ID" ] || { [[ "$body" != *"\"id\":\"$SNAPSHOT_ID"* ]] && [[ "$body" != *"\"short_id\":\"$SNAPSHOT_ID\""* ]]; }; then
    PHASE_MSG="forget skipped: the snapshot just created (${SNAPSHOT_ID:-none}) is not in the repository listing"
    log "WARN: $PHASE_MSG (listed=$n)"
    return 1
  fi
  if [ -n "$PRE_SNAP_COUNT" ] && [ "$n" -lt "$((PRE_SNAP_COUNT + 1))" ]; then
    PHASE_MSG="forget skipped: $n snapshots listed, expected at least $((PRE_SNAP_COUNT + 1)) (before the backup: $PRE_SNAP_COUNT)"
    log "WARN: $PHASE_MSG"
    return 1
  fi
  log "forget guard: new snapshot $SNAPSHOT_ID is listed (listed=$n before=${PRE_SNAP_COUNT:-unknown})"
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
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/backup/backup.sh

# BEGIN-PAYLOAD platform/backup/restore.sh
payload_restore() {
  cat <<'PLATFORM_PAYLOAD_EOF'
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
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/backup/restore.sh

# BEGIN-PAYLOAD platform/backup/window.env
payload_window() {
  cat <<'PLATFORM_PAYLOAD_EOF'
BACKUP_WINDOW_START=03:30
BACKUP_WINDOW_END=05:00
BACKUP_WINDOW_TZ=America/Chicago
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/backup/window.env

# BEGIN-PAYLOAD platform/backup/platform-backup.service
payload_platform_backup() {
  cat <<'PLATFORM_PAYLOAD_EOF'
[Unit]
Description=Platform nightly backup to R2 (restic)
Wants=network-online.target
After=network-online.target time-sync.target docker.service
Requires=docker.service

[Service]
Type=oneshot
User=root
ExecStart=/opt/platform/backup/backup.sh nightly
TimeoutStartSec=4500
Nice=10
IOSchedulingClass=idle
MemoryHigh=384M
MemoryMax=512M
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/backup/platform-backup.service

# BEGIN-PAYLOAD platform/backup/platform-backup-timer.timer
payload_platform_backup_timer() {
  cat <<'PLATFORM_PAYLOAD_EOF'
[Unit]
Description=Platform nightly backup timer (inside the 03:30-05:00 backup window)

[Timer]
OnCalendar=*-*-* 03:35:00 America/Chicago
Persistent=true
AccuracySec=1min
Unit=platform-backup.service

[Install]
WantedBy=timers.target
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/backup/platform-backup-timer.timer

# ---- file helpers ----

file_meta() { priv stat -c '%u:%g %a' -- "$1"; }

# place_file <src> <dest> <mode>: copy, own as root, chmod, then atomic rename. Reports already/changed.
place_file() {
  local src="$1" dest="$2" mode="${3#0}"
  LAST_PLACED=0
  if priv test -f "$dest" && ! priv test -L "$dest" && priv cmp -s -- "$src" "$dest" && [ "$(file_meta "$dest")" = "0:0 $mode" ]; then
    info "already: $dest"
    return 0
  fi
  # install replaces a pre-planted $dest.new instead of following it, and sets owner and mode in one step.
  priv install -m "$mode" -o root -g root -- "$src" "$dest.new"
  priv mv -f -- "$dest.new" "$dest"
  info "changed: $dest"
  CHANGED=1
  LAST_PLACED=1
}

# ensure_dir <dir> <uid> <gid> <mode>: create root:root 0755 when absent (a missing parent too, never an existing one),
# then correct owner and mode of the directory itself only (never recursive). A symlink or non-directory was rejected
# earlier.
ensure_dir() {
  local dir="$1" uid="$2" gid="$3" mode="${4#0}" meta created=0 parent
  if ! priv test -d "$dir"; then
    parent="$(dirname "$dir")"
    priv test -d "$parent" || priv install -d -m 0755 -o root -g root "$parent"
    priv install -d -m 0755 -o root -g root "$dir"
    created=1
  fi
  meta="$(file_meta "$dir")" || meta="unreadable"
  if [ "$meta" = "$uid:$gid $mode" ]; then
    if [ "$created" -eq 1 ]; then info "changed: $dir/"; CHANGED=1; else info "already: $dir/"; fi
    return 0
  fi
  priv chown "$uid:$gid" "$dir"
  priv chmod "$mode" "$dir"
  if [ "$created" -eq 1 ]; then info "changed: $dir/ (created as $uid:$gid $mode)"; else info "changed: $dir/ (was '$meta', now '$uid:$gid $mode')"; fi
  CHANGED=1
}

# ---- preconditions ----

problem() { PROBLEMS+=("$1"); }

# chk_dir_kind <dir>: a symlink or non-directory where a directory belongs is a problem (absent is fine).
chk_dir_kind() {
  if priv test -L "$1"; then
    problem "$1 is a symlink"
  elif priv test -e "$1" && ! priv test -d "$1"; then
    problem "$1 exists and is not a directory"
  fi
}

precond_common() {
  local t why
  for t in $TOOLS; do
    command -v "$t" >/dev/null 2>&1 || problem "required command not found: $t"
  done
  if ! why="$(env_problem)"; then problem "$ENV_FILE: $why"; fi
}

precond_install() {
  local f
  if ! priv test -f "$DATA_DIR/compose.yaml" || priv test -L "$DATA_DIR/compose.yaml"; then
    problem "the platform-data stack is not installed ($DATA_DIR/compose.yaml is missing): run make host-data install first"
  fi
  if ! priv test -d "$SECRETS_DIR" || priv test -L "$SECRETS_DIR"; then
    problem "the secrets root $SECRETS_DIR is missing or not a directory: run make host-data install first"
  fi
  for f in "$PG_ADMIN_FILE" "$REDIS_ADMIN_FILE"; do
    if ! priv test -f "$f" || priv test -L "$f"; then problem "the admin password file $f is missing (create it as described in platform/host/README.md)"; fi
  done
  chk_dir_kind "$STATE_DIR"
}

abort_if_problems() {
  local p
  [ "${#PROBLEMS[@]}" -gt 0 ] || return 0
  for p in "${PROBLEMS[@]}"; do err "problem: $p"; done
  die "${#PROBLEMS[@]} precondition(s) failed, nothing was installed"
}

# ---- restic ----

restic_bin_hash() { priv sha256sum -- "$RESTIC_BIN" | awk '{print $1}'; }

# restic_installed_ok: the installed binary is a root-owned 0755 regular file that reports the pinned version and
# whose hash equals the one recorded when it was installed.
restic_installed_ok() {
  local v h side
  priv test -f "$RESTIC_BIN" && ! priv test -L "$RESTIC_BIN" || return 1
  [ "$(file_meta "$RESTIC_BIN")" = "0:0 755" ] || return 1
  v="$(priv "$RESTIC_BIN" version 2>/dev/null)" || return 1
  [[ "$v" == "$RESTIC_VERSION_PREFIX"* ]] || return 1
  side="$(priv cat -- "$OPT_DIR/restic.sha256" 2>/dev/null)" || return 1
  h="$(restic_bin_hash)" || return 1
  [[ "$h" =~ ^[0-9a-f]{64}$ ]] && [ "$h" = "$side" ]
}

# prepare_restic: nothing to do when the installed binary is current; otherwise download, check the archive against
# RESTIC_SHA256 and decompress into $TMP (nothing outside $TMP is touched, so a mismatch leaves the host unchanged).
prepare_restic() {
  local got
  FETCHED=0
  if restic_installed_ok; then return 0; fi
  info "fetching: $RESTIC_FILE"
  curl --fail --silent --show-error --location --connect-timeout 20 --max-time 300 --retry 3 --retry-delay 2 \
    -o "$TMP/$RESTIC_FILE" "$RESTIC_URL" </dev/null || die "download of $RESTIC_FILE failed; nothing was installed"
  got="$(sha256sum -- "$TMP/$RESTIC_FILE" </dev/null | awk '{print $1}')"
  [ "$got" = "$RESTIC_SHA256" ] || die "checksum mismatch for $RESTIC_FILE; refusing, $RESTIC_BIN left untouched"
  bunzip2 -c -- "$TMP/$RESTIC_FILE" > "$TMP/restic" </dev/null || die "could not decompress $RESTIC_FILE; nothing was installed"
  [ -s "$TMP/restic" ] || die "the decompressed restic binary is empty; nothing was installed"
  FETCHED=1
}

install_restic() {
  local hash
  if [ "$FETCHED" -eq 1 ]; then
    priv test -d "$(dirname "$RESTIC_BIN")" || priv install -d -m 0755 -o root -g root "$(dirname "$RESTIC_BIN")"
    place_file "$TMP/restic" "$RESTIC_BIN" 0755
    hash="$(sha256sum -- "$TMP/restic" </dev/null | awk '{print $1}')"
  else
    info "already: $RESTIC_BIN"
    hash="$(restic_bin_hash)"
  fi
  printf '%s\n' "$hash" > "$TMP/restic.sha256"
  place_file "$TMP/restic.sha256" "$OPT_DIR/restic.sha256" 0644
}

# ---- install ----

install_payloads() {
  payload_backup > "$TMP/backup.sh"
  place_file "$TMP/backup.sh" "$OPT_DIR/backup.sh" 0755
  payload_restore > "$TMP/restore.sh"
  place_file "$TMP/restore.sh" "$OPT_DIR/restore.sh" 0755
  payload_window > "$TMP/window.env"
  place_file "$TMP/window.env" "$OPT_DIR/window.env" 0644
}

timer_ready() {
  sc is-enabled --quiet "$TIMER_NAME" >/dev/null 2>&1 && sc is-active --quiet "$TIMER_NAME" >/dev/null 2>&1
}

install_units() {
  local units_changed=0 timer_changed=0 was_ready=0
  priv test -d "$UNIT_DIR" || priv install -d -m 0755 -o root -g root "$UNIT_DIR"
  payload_platform_backup > "$TMP/$SERVICE_NAME"
  place_file "$TMP/$SERVICE_NAME" "$UNIT_DIR/$SERVICE_NAME" 0644
  [ "$LAST_PLACED" -eq 0 ] || units_changed=1
  payload_platform_backup_timer > "$TMP/$TIMER_NAME"
  place_file "$TMP/$TIMER_NAME" "$UNIT_DIR/$TIMER_NAME" 0644
  [ "$LAST_PLACED" -eq 0 ] || { units_changed=1; timer_changed=1; }
  if timer_ready; then was_ready=1; fi
  if [ "$units_changed" -eq 1 ]; then
    sc daemon-reload
    info "changed: systemd units reloaded"
    CHANGED=1
  fi
  if [ "$was_ready" -eq 0 ]; then
    sc enable --now "$TIMER_NAME"
    info "changed: $TIMER_NAME enabled and started"
    CHANGED=1
  elif [ "$timer_changed" -eq 1 ]; then
    # a changed schedule is only picked up by an active timer when it restarts; this never starts the service
    sc restart "$TIMER_NAME"
    info "changed: $TIMER_NAME restarted to apply the new schedule"
  else
    info "already: $TIMER_NAME enabled and active"
  fi
}

# do_install <install|restore-only>
do_install() {
  local mode="$1"
  require_privilege
  PROBLEMS=()
  precond_common
  [ "$mode" != install ] || precond_install
  chk_dir_kind "$VAR_DIR"
  chk_dir_kind "$WORK_DIR"
  chk_dir_kind "$LOG_DIR"
  chk_dir_kind "$OPT_DIR"
  abort_if_problems
  TMP="$(mktemp -d)"
  prepare_restic
  ensure_dir "$VAR_DIR" 0 0 0755
  ensure_dir "$WORK_DIR" 0 0 0700
  [ "$mode" != install ] || ensure_dir "$STATE_DIR" 0 0 0755
  ensure_dir "$LOG_DIR" 0 0 0750
  ensure_dir "$OPT_DIR" 0 0 0755
  install_restic
  install_payloads
  [ "$mode" != install ] || install_units
  if [ "$CHANGED" -eq 0 ]; then info "install-backup: $mode: everything already in place"; else info "install-backup: $mode done"; fi
}

# ---- checks (status, verify) ----

check_payload() { # <path> <mode> <payload function>
  local dest="$1" mode="$2" fn="$3" meta
  if ! priv test -f "$dest" || priv test -L "$dest"; then fail "$dest is missing or not a regular file"; return 0; fi
  meta="$(file_meta "$dest")" || meta="unreadable"
  if [ "$meta" != "0:0 $mode" ]; then fail "$dest has owner/mode '$meta', want '0:0 $mode'"; return 0; fi
  "$fn" > "$TMP/expect"
  if priv cmp -s -- "$TMP/expect" "$dest"; then pass "$dest (bytes, owner, mode)"; else fail "$dest differs from the shipped payload (drifted bytes)"; fi
}

check_dir() { # <dir> <mode>
  local meta
  if ! priv test -d "$1"; then fail "$1/ is missing"; return 0; fi
  meta="$(file_meta "$1")" || meta="unreadable"
  if [ "$meta" = "0:0 $2" ]; then pass "$1/ is root:root $2"; else fail "$1/ has owner/mode '$meta', want '0:0 $2'"; fi
}

check_restic() {
  local v side h
  if ! priv test -f "$RESTIC_BIN" || priv test -L "$RESTIC_BIN"; then fail "$RESTIC_BIN is missing or not a regular file"; return 0; fi
  h="$(file_meta "$RESTIC_BIN")" || h="unreadable"
  if [ "$h" = "0:0 755" ]; then pass "$RESTIC_BIN is root:root 0755"; else fail "$RESTIC_BIN has owner/mode '$h', want '0:0 755'"; fi
  v="$(priv "$RESTIC_BIN" version 2>/dev/null)" || v=""
  if [[ "$v" == "$RESTIC_VERSION_PREFIX"* ]]; then pass "restic version is the pinned 0.18.1"; else fail "restic version drift: reports '${v:-nothing}', want ${RESTIC_VERSION_PREFIX}..."; fi
  if ! side="$(priv cat -- "$OPT_DIR/restic.sha256" 2>/dev/null)"; then fail "restic hash record $OPT_DIR/restic.sha256 is missing"; return 0; fi
  h="$(restic_bin_hash)" || h=""
  if [ -n "$h" ] && [ "$h" = "$side" ]; then pass "restic binary hash matches the record made at install"; else fail "restic hash drift: the installed binary differs from the recorded hash"; fi
}

check_envfile() {
  local why
  if why="$(env_problem)"; then pass "backup.env (owner, mode, six keys, literal values)"; else fail "backup.env: $why"; fi
}

check_timer() {
  local en ac ne
  en="$({ sc is-enabled "$TIMER_NAME" 2>/dev/null || true; } | head -n 1)"
  if [ "$en" = enabled ]; then pass "$TIMER_NAME is enabled"; else fail "$TIMER_NAME is not enabled (is-enabled: ${en:-unknown})"; fi
  ac="$({ sc is-active "$TIMER_NAME" 2>/dev/null || true; } | head -n 1)"
  if [ "$ac" = active ]; then pass "$TIMER_NAME is active"; else fail "$TIMER_NAME is not active (is-active: ${ac:-unknown})"; fi
  ne="$({ sc show -p NextElapseUSecRealtime "$TIMER_NAME" 2>/dev/null || true; } | sed 's/^[^=]*=//')"
  if [ -n "$ne" ]; then pass "$TIMER_NAME has a next run scheduled"; else fail "$TIMER_NAME has no next run scheduled (NextElapseUSecRealtime is empty)"; fi
}

# hms_secs <HH:MM[:SS]>: seconds since midnight; fails on any other shape.
hms_secs() {
  [[ "$1" =~ ^([0-9]{2}):([0-9]{2})(:([0-9]{2}))?$ ]] || return 1
  printf '%s' $((10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[4]:-0}))
}

check_window() {
  local timer unit win line t wtz ws we tz tmo ts ss es re='^OnCalendar=\*-\*-\* ([0-9]{2}:[0-9]{2}:[0-9]{2}) (.+)$'
  if ! timer="$(priv cat -- "$UNIT_DIR/$TIMER_NAME" 2>/dev/null)"; then fail "cannot read $UNIT_DIR/$TIMER_NAME"; return 0; fi
  if ! unit="$(priv cat -- "$UNIT_DIR/$SERVICE_NAME" 2>/dev/null)"; then fail "cannot read $UNIT_DIR/$SERVICE_NAME"; return 0; fi
  if ! win="$(priv cat -- "$OPT_DIR/window.env" 2>/dev/null)"; then fail "cannot read $OPT_DIR/window.env"; return 0; fi
  line="$(grep -E '^OnCalendar=' <<<"$timer" | head -n 1 || true)"
  if ! [[ "$line" =~ $re ]]; then fail "the timer OnCalendar line is not '*-*-* HH:MM:SS <timezone>'"; return 0; fi
  t="${BASH_REMATCH[1]}"
  tz="${BASH_REMATCH[2]}"
  ws="$(sed -n 's/^BACKUP_WINDOW_START=//p' <<<"$win" | head -n 1)"
  we="$(sed -n 's/^BACKUP_WINDOW_END=//p' <<<"$win" | head -n 1)"
  wtz="$(sed -n 's/^BACKUP_WINDOW_TZ=//p' <<<"$win" | head -n 1)"
  tmo="$(sed -n 's/^TimeoutStartSec=//p' <<<"$unit" | head -n 1)"
  ts="$(hms_secs "$t")" || ts=""
  ss="$(hms_secs "$ws")" || ss=""
  es="$(hms_secs "$we")" || es=""
  if [ -z "$ts" ] || [ -z "$ss" ] || [ -z "$es" ] || [[ ! "$tmo" =~ ^[0-9]+$ ]]; then fail "cannot evaluate the window (timer '$t', window '$ws'-'$we', TimeoutStartSec '$tmo')"; return 0; fi
  if [ "$tz" != "$wtz" ]; then fail "timer timezone '$tz' differs from BACKUP_WINDOW_TZ '$wtz'"; return 0; fi
  if [ "$ts" -ge "$ss" ] && [ "$ts" -lt "$es" ]; then pass "timer time $t is inside the window $ws-$we $wtz"; else fail "timer time $t is outside the backup window $ws-$we $wtz"; fi
  if [ $((ts + tmo + ACCURACY_SECS)) -le "$es" ]; then pass "timer time + TimeoutStartSec + AccuracySec ends inside the window"; else fail "timer time + TimeoutStartSec ($tmo s) + AccuracySec ends after BACKUP_WINDOW_END $we"; fi
}

check_state() {
  local f="$STATE_DIR/last-run.tsv" meta
  check_dir "$STATE_DIR" 755
  if ! priv test -e "$f"; then warn "no $f yet (no backup has run)"; return 0; fi
  meta="$(file_meta "$f")" || meta="unreadable"
  if [ "$meta" = "0:0 644" ]; then pass "last-run.tsv is root:root 0644"; else fail "last-run.tsv has owner/mode '$meta', want '0:0 644'"; fi
  check_last_run "$f"
}

check_last_run() {
  local f="$1" line e res snap ph end_epoch now
  line="$(priv tail -n 1 -- "$f" 2>/dev/null || true)"
  IFS=$'\t' read -r _ e res snap ph <<<"$line" || true
  if [ -z "${res:-}" ] || [ -z "${e:-}" ]; then fail "last-run.tsv is unreadable or malformed"; return 0; fi
  case "$res" in
    ok) pass "the last backup run succeeded (snapshot ${snap:--})" ;;
    failed) fail "the last backup run failed (phase ${ph:--})" ;;
    *) fail "last-run.tsv has an unknown result '$res'"; return 0 ;;
  esac
  if ! end_epoch="$(date -u -d "$e" +%s 2>/dev/null)"; then fail "last-run.tsv end time '$e' is not a date"; return 0; fi
  now="$(date +%s)"
  if [ $((now - end_epoch)) -gt "$STALE_SECS" ]; then fail "the last backup run ended more than 36h ago ($e)"; else pass "the last backup run ended within 36h"; fi
}

check_journal() {
  if priv test -d "$JOURNAL_DIR"; then pass "the journal is persistent ($JOURNAL_DIR exists)"; else warn "$JOURNAL_DIR is missing: the journal is not persistent, so unit logs vanish on reboot (the file logs under $LOG_DIR remain)"; fi
}

do_checks() {
  TMP="$(mktemp -d)"
  check_dir "$OPT_DIR" 755
  check_dir "$WORK_DIR" 700
  check_dir "$LOG_DIR" 750
  check_payload "$OPT_DIR/backup.sh" 755 payload_backup
  check_payload "$OPT_DIR/restore.sh" 755 payload_restore
  check_payload "$OPT_DIR/window.env" 644 payload_window
  check_payload "$UNIT_DIR/$SERVICE_NAME" 644 payload_platform_backup
  check_payload "$UNIT_DIR/$TIMER_NAME" 644 payload_platform_backup_timer
  check_restic
  check_envfile
  check_timer
  check_window
  check_state
  check_journal
}

do_report() {
  require_privilege
  do_checks
  if [ "$FAILURES" -gt 0 ]; then
    printf 'install-backup: %d check(s) failed\n' "$FAILURES"
    [ "$1" = "status" ] || exit 1
  else
    printf 'install-backup: all checks passed\n'
  fi
}

# ---- run-now and init-repo ----

require_installed() { # <what the caller needs>
  priv test -f "$RESTIC_BIN" || die "restic is not installed at $RESTIC_BIN (run install or restore-only first); $1 not run"
  if [ "$1" = run-now ]; then
    priv test -f "$OPT_DIR/backup.sh" || die "$OPT_DIR/backup.sh is not installed (run install first); run-now not run"
  fi
}

do_run_now() {
  local args=() p
  require_privilege
  require_installed run-now
  for p in "${RUN_PROPS[@]}"; do args+=(-p "$p"); done
  # The unit's own resource envelope; the manual tag comes from the mode argument. The shared lock still stops an overlap.
  priv systemd-run --wait --pipe "${args[@]}" "$OPT_DIR/backup.sh" manual
}

do_init_repo() {
  local why rc
  require_privilege
  require_installed init-repo
  if ! why="$(env_problem)"; then die "backup.env: $why" 2; fi
  # restic exits 10 only for "repository does not exist"; any other failure (network, credentials, wrong bucket) must not init.
  rc=0
  with_env timeout 120 "$RESTIC_BIN" cat config >/dev/null 2>&1 || rc=$?
  if [ "$rc" -eq 0 ]; then
    die "the repository already exists (restic cat config succeeded); refusing to init" 1
  fi
  if [ "$rc" -ne 10 ]; then
    die "cannot reach or open the repository (restic cat config exited $rc, not 10 = repository does not exist); not initialising" 1
  fi
  info "install-backup: no repository found; running restic init once"
  with_env timeout 120 "$RESTIC_BIN" init
}

# ---- main ----

main() {
  local cmd="install" host=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      install | restore-only | status | verify | run-now | init-repo) cmd="$1"; shift ;;
      --host) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "missing value for --host" 2; host="$2"; shift 2 ;;
      -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  case "$host" in -*) die "refusing option-looking --host: $host" 2 ;; esac

  if [ -n "$host" ]; then
    exec ssh -o BatchMode=yes -- "$host" "bash -s -- $cmd" < "${BASH_SOURCE[0]}"
  fi

  case "$cmd" in
    install | restore-only) do_install "$cmd" ;;
    status | verify) do_report "$cmd" ;;
    run-now) do_run_now ;;
    init-repo) do_init_repo ;;
  esac
}

main "$@"
exit 0
