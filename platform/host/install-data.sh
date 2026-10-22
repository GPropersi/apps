#!/usr/bin/env bash
# install-data.sh: install and check the shared data stack (one Postgres, one Redis) on the app host (run yourself,
# not Claude).
#
# The stack is described by platform/data/compose.yaml. It runs as the Compose project platform-data from
# /opt/platform/data and joins the existing `platform` Docker network (created by install-ingress.sh). No port is
# published and no firewall rule is touched. Per-app databases and logins come later from `platform new-db`.
#
# Host-side inputs (you create them; the installer never writes a secret and never edits /etc/group):
#   /etc/platform/postgres-admin.password   the Postgres admin password: regular file, root:64322, mode exactly 0640,
#   /etc/platform/redis-admin.password      the Redis admin password: the same, one line (one trailing newline is fine)
#   a group with gid 64322 (admin secrets: the containers get it through group_add) and a group with gid 64323 (app
#   secrets: app containers get it through group_add); both must have no members, be no account's primary group and
#   not be the Docker socket's group
#   the `deploy` user (make host-deploy-user) and the `platform` network (make host-ingress)
# The installer itself creates (as root, explicit owners and modes, never relying on umask):
#   /var/lib/platform            root:root 0755
#   /var/lib/platform/secrets    deploy:64323 2710 (setgid, so `platform new-db` running as deploy, which is not in that
#                                group and has no sudo, creates every file and directory with group 64323 and no chgrp)
#   /opt/platform/data           root:root 0755: compose.yaml, pg_hba.conf, reserved-names.txt and connection.env 0644,
#                                redis-entrypoint.sh 0755 (a 0644 entrypoint cannot be run by the non-root container user),
#                                new-db.sh 0755 (run by `platform new-db` as the deploy user)
#   the sysctl drop-in 99-platform-redis (under sysctl.d) root:root 0644: vm.overcommit_memory = 1, so Redis background
#                                saves keep working after a reboot; the live value is also set to 1 now
#
# The payload files (compose.yaml, pg_hba.conf, redis-entrypoint.sh, reserved-names.txt, new-db.sh) are embedded below
# (BEGIN-PAYLOAD/END-PAYLOAD) because the host has no checkout: `platform/lint/embed-payloads.sh` regenerates them from
# the tracked sources (`make embed`) and `make lint` fails if they differ. connection.env (host and port values only) is
# generated here. verify checks every payload file's owner, mode and bytes.
#
# Usage: install-data.sh [install|status|verify] [--host ALIAS]
#   install   checks every precondition first (deploy user, platform network, both admin password files, both groups,
#             the secrets paths) and reports all problems together; nothing is installed and no mutating docker command
#             runs until they all pass. Then it places the files, creates the two directories, writes the sysctl drop-in
#             and sets the live vm.overcommit_memory (a failed live write only WARNs), starts the stack and waits
#             (bounded) for both containers to be healthy. Idempotent: a second run with unchanged inputs reports
#             "already:" for every item and makes no mutating docker call. A changed compose.yaml, pg_hba.conf or
#             redis-entrypoint.sh recreates the containers (a bind-mounted file is not re-read otherwise).
#   status    report every check (PASS/FAIL/WARN), exit 0
#   verify    the same checks, exit 1 on any FAIL (a WARN never changes the status)
#   --host    stream this script over one `ssh <alias> bash -s` call (BatchMode, no tty; passwordless sudo needed).
#
# Exit: 0 ok | 1 failed check, wrong state or unusable input | 2 usage error. ssh failures pass through ssh's status.
#
# Known gap: verify never logs in to Postgres with the admin password file (Postgres reads POSTGRES_PASSWORD_FILE only at
# first init, so a later change to the file diverges silently) and does not inspect the live containers' HostConfig
# (read-only root, dropped capabilities, memory limit); the on-disk compose.yaml bytes are compared instead. Both are
# validated only by the live run (platform/data/test_data_live.sh).
#
# Test overrides (env, test-only): INSTALL_DATA_ROOT (path prefix for every default host path), INSTALL_DATA_SUDO (the
# privilege prefix; "sudo -n" by default, none when already root), INSTALL_DATA_SOCKET (the Docker socket path),
# INSTALL_DATA_HEALTH_TIMEOUT / INSTALL_DATA_POLL (seconds), INSTALL_DATA_PG_CONTAINER / INSTALL_DATA_REDIS_CONTAINER
# (default platform-data-postgres / platform-data-redis), and per-path overrides, absolute and not prefixed by the root,
# so the live test can run the server-side checks against throwaway containers: INSTALL_DATA_DIR, INSTALL_DATA_VAR_DIR,
# INSTALL_DATA_SECRETS_ROOT, INSTALL_DATA_PG_ADMIN_FILE, INSTALL_DATA_REDIS_ADMIN_FILE, INSTALL_DATA_OVERCOMMIT_FILE,
# INSTALL_DATA_SYSCTL_FILE (the vm.overcommit_memory drop-in), INSTALL_DATA_REDIS_CTR_ADMIN_FILE (where the Redis
# container sees its admin file), and INSTALL_DATA_NETWORK (the Docker network the containers must be on only;
# "platform" by default). The docker, stat, getent, install, chown and chmod commands are the ones on PATH, so a test
# puts stubs there.
set -euo pipefail

export LC_ALL=C
# groupadd, getent and friends live in /usr/sbin, which a non-root ssh user's PATH lacks
export PATH="$PATH:/usr/sbin:/sbin"

# Fixed, chosen without knowledge of the host's group database. ADMIN_GID must equal the numeric group_add of both
# services in compose.yaml (the stack test compares them); SECRETS_GID is the app-secrets group named in data/README.md.
readonly ADMIN_GID=64322
readonly SECRETS_GID=64323
readonly PROJECT="platform-data"
NETWORK="${INSTALL_DATA_NETWORK:-platform}"
[[ "$NETWORK" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { printf '%s\n' "INSTALL_DATA_NETWORK must be a Docker network name (letters, digits, _ . -)" >&2; exit 2; }
readonly NETWORK
# Where the Postgres container sees the mounted pg_hba.conf (the bind mount and hba_file in compose.yaml).
readonly PG_CTR_HBA="/etc/postgresql/pg_hba.conf"
readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
ROOT="${INSTALL_DATA_ROOT:-}"
INSTALL_DIR="${INSTALL_DATA_DIR:-$ROOT/opt/platform/data}"
VAR_DIR="${INSTALL_DATA_VAR_DIR:-$ROOT/var/lib/platform}"
SECRETS_DIR="${INSTALL_DATA_SECRETS_ROOT:-$VAR_DIR/secrets}"
PG_ADMIN_FILE="${INSTALL_DATA_PG_ADMIN_FILE:-$ROOT/etc/platform/postgres-admin.password}"
REDIS_ADMIN_FILE="${INSTALL_DATA_REDIS_ADMIN_FILE:-$ROOT/etc/platform/redis-admin.password}"
REDIS_CTR_ADMIN_FILE="${INSTALL_DATA_REDIS_CTR_ADMIN_FILE:-/etc/platform/redis-admin.password}"
OVERCOMMIT_FILE="${INSTALL_DATA_OVERCOMMIT_FILE:-$ROOT/proc/sys/vm/overcommit_memory}"
SYSCTL_FILE="${INSTALL_DATA_SYSCTL_FILE:-$ROOT/etc/sysctl.d/99-platform-redis.conf}"
PG="${INSTALL_DATA_PG_CONTAINER:-platform-data-postgres}"
REDIS="${INSTALL_DATA_REDIS_CONTAINER:-platform-data-redis}"
SOCKET="${INSTALL_DATA_SOCKET:-/var/run/docker.sock}"
HEALTH_TIMEOUT="${INSTALL_DATA_HEALTH_TIMEOUT:-180}"
POLL="${INSTALL_DATA_POLL:-2}"

if [ -n "${INSTALL_DATA_SUDO+set}" ]; then
  read -r -a SUDO <<<"$INSTALL_DATA_SUDO"
elif [ "$EUID" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo -n)
fi

FAILURES=0
CHANGED=0
FORCE_RECREATE=0
COMPOSE_CHANGED=0
LAST_PLACED=0
TMP=""
SECRET=""

info() { printf '%s\n' "$1"; }
err() { printf '%s\n' "$1" >&2; }
pass() { printf 'PASS: %s\n' "$1"; }
warn() { printf 'WARN: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
die() { err "install-data: $1"; exit "${2:-1}"; }

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

# priv <cmd...>: run with privilege; stdin is never forwarded (this script may itself be read from stdin).
priv() { "${SUDO[@]}" "$@" </dev/null; }
dk() { priv docker "$@"; }

require_privilege() {
  priv true || die "no usable privilege (sudo -n failed). Over --host the account needs passwordless sudo; otherwise copy this script to the host and run it there directly"
}

# ---- embedded payloads (regenerated by platform/lint/embed-payloads.sh; do not edit between the markers) ----

# BEGIN-PAYLOAD platform/data/compose.yaml
payload_compose() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# Data stack: one shared Postgres and one shared Redis for every app, on the `platform` network only.
#
#   apps -> postgres:5432 / redis:6379 (the service names are the DNS names on `platform`); nothing is published.
#
# Host-side inputs (never written here, validated by install-data.sh): the admin secrets
# /etc/platform/postgres-admin.password and /etc/platform/redis-admin.password (root:64322 0640, read through
# group_add 64322), and the payloads installed to /opt/platform/data (pg_hba.conf, redis-entrypoint.sh).
#
# Rules this file keeps (platform/data/test_data_stack.sh enforces them):
# - It stays inside the small YAML subset (block style only) so the tests can read it without a YAML library.
# - No password appears in any environment value or command argument: Traefik can read every container's
#   Config.Env (a known gap, to be closed separately), so every secret is a mounted file. The one literal is the Redis healthcheck's
#   `--pass placeholder`: the nopass `health` user accepts any password, and the flag makes redis-cli send AUTH.
# - Postgres: log_statement=none and log_min_error_statement=panic keep a failing CREATE ROLE ... PASSWORD from
#   writing its statement (and so the password) into the container log. pg_hba.conf has one `local` line
#   (`local all postgres peer`, used by `docker exec` as the postgres uid) and only scram-sha-256 `host` lines.
# - Postgres memory (measured by test_data_live.sh): a heavy sort + hash-aggregate session costs about 15MB of private
#   memory with hash_mem_multiplier=1 (about twice that with the default 2), on top of 128MB shared_buffers and the
#   container's page cache. 24 such sessions at once stay inside the 512m cap only with hash_mem_multiplier=1; the
#   per-role cap of 3 connections and the 60-connection ceiling do not bound the sum, so a query-heavy app needs a bigger
#   mem_limit, not just more connections.
# - Redis: noeviction (queued jobs are never evicted) with AOF everysec. maxmemory is half the cgroup cap because the
#   AOF rewrite buffer and copy-on-write pages are not counted by maxmemory. Redis memory is shared by all apps with
#   no per-app quota: a full Redis rejects every app's writes (monitored by `install-data.sh verify`).
# - Every service drops all capabilities, cannot gain privileges, has a read-only root, a memory limit and restarts
#   unless stopped.
name: platform-data

services:
  postgres:
    image: docker.io/library/postgres:18.6@sha256:edb0c08dc33befd0262ab3b5cf1c4f3f8cfd8b09e88c05b45adee29d6761ddb6
    container_name: platform-data-postgres
    command:
      - postgres
      - -c
      - hba_file=/etc/postgresql/pg_hba.conf
      - -c
      - log_statement=none
      - -c
      - log_min_error_statement=panic
      - -c
      - shared_buffers=128MB
      - -c
      - effective_cache_size=512MB
      - -c
      - work_mem=4MB
      - -c
      - maintenance_work_mem=48MB
      - -c
      - max_connections=60
      - -c
      - huge_pages=off
      - -c
      - wal_compression=on
      - -c
      - max_parallel_workers_per_gather=0
      - -c
      - hash_mem_multiplier=1
    environment:
      POSTGRES_PASSWORD_FILE: /etc/platform/postgres-admin.password
    volumes:
      - platform-data-postgres:/var/lib/postgresql
      - /etc/platform/postgres-admin.password:/etc/platform/postgres-admin.password:ro
      - /opt/platform/data/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro
    tmpfs:
      - /tmp
      - /var/run/postgresql
    user: "999:999"
    group_add:
      - "64322"
    networks:
      - platform
    restart: unless-stopped
    mem_limit: 512m
    shm_size: 128m
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    healthcheck:
      test:
        - CMD
        - pg_isready
        - -U
        - postgres
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 30s

  redis:
    image: docker.io/library/redis:8.10.2@sha256:5c02d7c0f8d75af45958c0294a8004f2e14b42df98a1103e3a669aa7ec787be6
    container_name: platform-data-redis
    entrypoint:
      - /usr/local/bin/redis-entrypoint.sh
    command:
      - --maxmemory
      - 96mb
      - --maxmemory-policy
      - noeviction
      - --appendonly
      - "yes"
      - --appendfsync
      - everysec
      - --aclfile
      - /data/users.acl
    volumes:
      - platform-data-redis:/data
      - /etc/platform/redis-admin.password:/etc/platform/redis-admin.password:ro
      - /opt/platform/data/redis-entrypoint.sh:/usr/local/bin/redis-entrypoint.sh:ro
    tmpfs:
      - /tmp
    user: "999:999"
    group_add:
      - "64322"
    networks:
      - platform
    restart: unless-stopped
    mem_limit: 192m
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    healthcheck:
      test:
        - CMD
        - redis-cli
        - --user
        - health
        - --pass
        - placeholder
        - --no-auth-warning
        - ping
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 10s

volumes:
  platform-data-postgres:
    name: platform-data-postgres
  platform-data-redis:
    name: platform-data-redis

networks:
  platform:
    external: true
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/data/compose.yaml

# BEGIN-PAYLOAD platform/data/pg_hba.conf
payload_pg_hba() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# Postgres client authentication for the shared data stack (mounted read-only; hba_file is set in compose.yaml).
#
# The one local line is for `docker exec` (new-db and verify run as the postgres uid, so they need no password).
# Every host line uses scram-sha-256; `samenet` is the platform network, so no address literal appears here.
# The postgres superuser never logs in over the network: the reject line comes first (first match wins).
# platform/data/test_data_stack.sh enforces: exactly this one local line, the reject line first, then host lines with
# scram-sha-256 only.
local all postgres peer
host all postgres samenet reject
host all all samenet scram-sha-256
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/data/pg_hba.conf

# BEGIN-PAYLOAD platform/data/redis-entrypoint.sh
payload_redis_entrypoint() {
  cat <<'PLATFORM_PAYLOAD_EOF'
#!/bin/sh
# redis-entrypoint.sh: Redis cannot read a password from a file, so this wrapper builds the ACL file from the
# mounted admin password file at first start, then execs redis-server with the arguments it was given.
#
# Mounted read-only into the redis container (set as the service entrypoint). Never prints the password or its hash
# and never passes either in the environment or on a command line.
#
# users.acl (built only when absent; ACL SAVE rewrites it at runtime with the per-app users):
#   user default off
#   user admin on #<sha256 of the admin password> ~* &* +@all
#   user health on nopass -@all +ping
# The admin password is the file's content with exactly one trailing newline stripped (new-db and verify strip
# identically for REDISCLI_AUTH, so the hash and the client password always agree).
# The write is atomic: a temp file in the data dir (created under umask 077) is moved to users.acl, so the file is
# either absent or complete. A leftover temp file from an interrupted start is removed at the next start.
#
# REDIS_ENTRYPOINT_DATA and REDIS_ENTRYPOINT_ADMIN_FILE exist only so the offline test can use a scratch tree.
set -eu

data="${REDIS_ENTRYPOINT_DATA:-/data}"
admin_file="${REDIS_ENTRYPOINT_ADMIN_FILE:-/etc/platform/redis-admin.password}"
acl="$data/users.acl"
tmp="$data/users.acl.tmp"

umask 077
rm -f "$tmp"

if [ ! -e "$acl" ]; then
  [ -r "$admin_file" ] || { echo "redis-entrypoint: cannot read the admin password file" >&2; exit 1; }
  # "$(cat; printf x)" keeps every trailing newline, then exactly one is stripped.
  pw="$(cat "$admin_file"; printf x)"
  pw="${pw%x}"
  nl='
'
  case "$pw" in
    *"$nl") pw="${pw%"$nl"}" ;;
  esac
  [ -n "$pw" ] || { echo "redis-entrypoint: admin password file is empty" >&2; exit 1; }
  hash="$(printf '%s' "$pw" | sha256sum | cut -d ' ' -f 1)"
  pw=""
  {
    printf 'user default off\n'
    printf 'user admin on #%s ~* &* +@all\n' "$hash"
    printf 'user health on nopass -@all +ping\n'
  } > "$tmp"
  # Flush the data blocks before the rename: a power loss must not leave a rename without its content.
  sync "$tmp"
  mv "$tmp" "$acl"
fi

# Fail closed: an ACL file without the default user switched off (truncated, hand-edited) would leave Redis open.
# ACL SAVE appends more tokens after "off" (such as sanitize-payload), so accept those, but never "on".
awk '$1 == "user" && $2 == "default" && $3 == "off" { ok = 1; for (i = 4; i <= NF; i++) if ($i == "on") ok = 0 } END { exit ok ? 0 : 1 }' "$acl" \
  || { echo "redis-entrypoint: users.acl does not switch the default user off" >&2; exit 1; }

exec redis-server "$@"
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/data/redis-entrypoint.sh

# BEGIN-PAYLOAD platform/registry/reserved-names.txt
payload_reserved_names() {
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

# BEGIN-PAYLOAD platform/data/new-db.sh
payload_new_db() {
  cat <<'PLATFORM_PAYLOAD_EOF'
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
#   2. Takes the per-app lock <secrets root>/.<app>.lock (flock, bounded wait).
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
# (default /var/lib/platform/secrets), NEW_DB_REDIS_CTR_ADMIN_FILE (the admin file as the Redis container sees it),
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
  lock="$SECRETS_ROOT/.$APP.lock"
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
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/data/new-db.sh

# connection_env: the platform-wide, non-secret connection contract (service names on the platform network).
connection_env() {
  printf '%s\n' 'PLATFORM_PG_HOST=postgres' 'PLATFORM_PG_PORT=5432' 'PLATFORM_REDIS_HOST=redis' 'PLATFORM_REDIS_PORT=6379'
}

# reserved_names: one reserved app name per line (comments and blank lines dropped), from the embedded list.
# shellcheck disable=SC2329 # reached through chk_redis_acl, which run_check invokes by name
reserved_names() { payload_reserved_names | sed -e 's/#.*//' -e 's/[[:space:]]*$//' | grep -v '^$' || true; }

# ---- host inputs: each chk_* prints one line per problem (never a file's content) and always returns 0 ----

# file_meta <path>: "<uid>:<gid> <octal mode>".
file_meta() { priv stat -c '%u:%g %a' -- "$1"; }

# socket_gid: the numeric group of the Docker socket, from stat (not a docker call).
socket_gid() { stat -c '%g' -- "$SOCKET"; }

deploy_uid() { getent passwd deploy | cut -d: -f3; }

# read_secret <path>: sets SECRET to the file's content with exactly one trailing newline stripped. Never printed.
read_secret() {
  local raw
  raw="$(priv cat -- "$1" 2>/dev/null && printf x)" || return 1
  raw="${raw%x}"
  if [[ "$raw" == *$'\n' ]]; then raw="${raw%$'\n'}"; fi
  SECRET="$raw"
}

chk_deploy_user() {
  local uid
  if ! getent passwd deploy >/dev/null 2>&1; then
    echo "the deploy user does not exist: run \`make host-deploy-user HOST=<alias> ARGS=\"install --pubkey-file <path>\"\` first"
    return 0
  fi
  uid="$(deploy_uid)"
  [[ "$uid" =~ ^[0-9]+$ ]] || echo "cannot read the deploy user's numeric uid"
}

chk_network() {
  local desc
  desc="$(dk network inspect --format '{{.Driver}} {{.EnableIPv6}}' "$NETWORK" 2>/dev/null)" || { echo "network $NETWORK is missing: run \`make host-ingress HOST=<alias> ARGS=install\` first"; return 0; }
  [ "$desc" = "bridge false" ] || echo "network $NETWORK is '$desc', want 'bridge false' (a bridge with IPv6 off)"
}

# chk_admin_file <label> <path>: regular, not a symlink, root:ADMIN_GID 0640, non-empty and one line.
chk_admin_file() {
  local label="$1" p="$2" meta
  if ! priv test -e "$p"; then echo "$label admin password file missing: $p"; return 0; fi
  if priv test -L "$p"; then echo "$label admin password file is a symlink: $p"; return 0; fi
  if ! priv test -f "$p"; then echo "$label admin password file is not a regular file: $p"; return 0; fi
  meta="$(file_meta "$p")" || { echo "cannot stat the $label admin password file"; return 0; }
  [ "$meta" = "0:$ADMIN_GID 640" ] || echo "$label admin password file uid:gid/mode is '$meta', want '0:$ADMIN_GID 640' (owner root, group $ADMIN_GID, mode 0640)"
  if ! priv test -s "$p"; then echo "$label admin password file is empty"; return 0; fi
  read_secret "$p" || { echo "cannot read the $label admin password file"; return 0; }
  if [[ "$SECRET" == *$'\n'* ]]; then
    echo "$label admin password file has more than one line (one trailing newline is fine)"
  elif [ -z "$SECRET" ]; then
    echo "$label admin password file has no content"
  fi
}

# chk_group <gid> <label>: exists, no members, nobody's primary group, not the Docker socket's group.
chk_group() {
  local gid="$1" label="$2" entry egid members sgid accounts groups_all dup prim
  entry="$(getent group "$gid" || true)"
  egid=""
  members=""
  [ -z "$entry" ] || IFS=: read -r _ _ egid members <<<"$entry"
  if [ "$egid" != "$gid" ]; then
    echo "no group with gid $gid exists ($label); create it, see the instructions below"
    return 0
  fi
  [ -z "$members" ] || echo "$label group (gid $gid) has members; it must have none"
  # getent group <gid> shows only the first entry: a second entry with the same gid and a member must also fail.
  groups_all="$(getent group || true)"
  if [ -n "$groups_all" ]; then
    dup="$(awk -F: -v g="$gid" '$3 == g { n++; if ($4 != "") m++ } END { print (n + 0) " " (m + 0) }' <<<"$groups_all")"
    if [ "${dup%% *}" -gt 1 ] 2>/dev/null; then echo "more than one group entry carries gid $gid ($label group must be unique)"; fi
    if [ "${dup##* }" -gt 0 ] 2>/dev/null && [ -z "$members" ]; then echo "a group entry with gid $gid has members; it must have none"; fi
  fi
  accounts="$(getent passwd || true)"
  if [ -z "$accounts" ]; then
    echo "cannot list accounts to check the $label group is nobody's primary group"
  else
    prim=0
    awk -F: -v g="$gid" '$4 == g { f = 1 } END { exit f ? 0 : 1 }' <<<"$accounts" || prim=$?
    case "$prim" in
      0) echo "$label group (gid $gid) is an account's primary group" ;;
      1) ;;
      *) echo "cannot check the accounts' primary groups (awk failed)" ;;
    esac
  fi
  if sgid="$(socket_gid 2>/dev/null)" && [ "$sgid" = "$gid" ]; then
    echo "$label group (gid $gid) is the Docker socket's group"
  fi
}

chk_groups() { chk_group "$ADMIN_GID" "admin-secrets"; chk_group "$SECRETS_GID" "app-secrets"; }

# chk_path_kind <label> <path>: a symlink or a non-directory at a directory path fails closed.
chk_path_kind() {
  if priv test -L "$2"; then
    echo "$1 is a symlink: $2 (refusing to follow it)"
  elif priv test -e "$2" && ! priv test -d "$2"; then
    echo "$1 is not a directory: $2"
  fi
}

chk_secret_paths() {
  chk_path_kind "install directory" "$INSTALL_DIR"
  chk_path_kind "platform state directory" "$VAR_DIR"
  chk_path_kind "secrets root" "$SECRETS_DIR"
}

# chk_secrets_dirs: owner/group/mode of the two directories (verify only; install creates or corrects them).
# shellcheck disable=SC2329 # invoked by name through run_check
chk_secrets_dirs() {
  local uid meta
  if [ ! -d "$VAR_DIR" ] || [ -L "$VAR_DIR" ]; then echo "$VAR_DIR is missing or not a directory"; else
    meta="$(file_meta "$VAR_DIR")" || meta="unreadable"
    [ "$meta" = "0:0 755" ] || echo "$VAR_DIR uid:gid/mode is '$meta', want '0:0 755'"
  fi
  if [ ! -d "$SECRETS_DIR" ] || [ -L "$SECRETS_DIR" ]; then echo "$SECRETS_DIR is missing or not a directory"; return 0; fi
  uid="$(deploy_uid 2>/dev/null || true)"
  [[ "$uid" =~ ^[0-9]+$ ]] || { echo "cannot read the deploy user's uid to judge the secrets root owner"; return 0; }
  meta="$(file_meta "$SECRETS_DIR")" || meta="unreadable"
  [ "$meta" = "$uid:$SECRETS_GID 2710" ] || echo "$SECRETS_DIR uid:gid/mode is '$meta', want '$uid:$SECRETS_GID 2710' (owner deploy, group $SECRETS_GID, setgid, mode 2710)"
}

print_instructions() {
  err ""
  err "Create the host-side inputs yourself (nothing here writes a secret or edits /etc/group):"
  err "  sudo groupadd --gid $ADMIN_GID platform-data-admin     # once; no members, no account may use it as primary group"
  err "  sudo groupadd --gid $SECRETS_GID platform-app-secrets  # once; the same rules"
  err "  sudo install -d -m 0755 -o root -g root /etc/platform"
  err "  sudo install -m 0640 -o root -g $ADMIN_GID /dev/null $PG_ADMIN_FILE"
  err "  openssl rand -hex 24 | sudo tee $PG_ADMIN_FILE >/dev/null     # or paste your own single-line password"
  err "  sudo install -m 0640 -o root -g $ADMIN_GID /dev/null $REDIS_ADMIN_FILE"
  err "  openssl rand -hex 24 | sudo tee $REDIS_ADMIN_FILE >/dev/null"
  err "  (the deploy user and the platform network come from make host-deploy-user and make host-ingress)"
}

# ---- file helpers ----

# place_file <src> <dest> <mode>: copy, own as root, chmod, then atomic rename. Reports already/changed.
place_file() {
  local src="$1" dest="$2" mode="$3"
  LAST_PLACED=0
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest" && [ "$(file_meta "$dest")" = "0:0 $mode" ]; then
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

# ensure_dir <dir> <uid> <gid> <mode>: create root:root 0755 when absent, then correct owner and mode of the directory
# itself only (never recursive, never touching what is inside). A symlink or non-directory was rejected earlier.
ensure_dir() {
  local dir="$1" uid="$2" gid="$3" mode="$4" meta created=0 parent
  if ! priv test -d "$dir"; then
    # install -d sets the mode only on the last component: create a missing parent explicitly too (never an existing one)
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
  # GNU chmod keeps an existing setgid bit on a directory whatever the numeric mode, so a mode without one clears it.
  [ "${#mode}" -ge 4 ] || priv chmod ug-s "$dir"
  if [ "$created" -eq 1 ]; then info "changed: $dir/ (created as $uid:$gid $mode)"; else info "changed: $dir/ (was '$meta', now '$uid:$gid $mode')"; fi
  CHANGED=1
}

# ---- compose helpers ----

compose() { dk compose -p "$PROJECT" -f "$INSTALL_DIR/compose.yaml" "$@"; }

# stack_problems [run]: one line per container that is absent, not running or (without "run") not healthy.
stack_problems() {
  local only_run="${1:-}" name st state health
  for name in "$PG" "$REDIS"; do
    if ! st="$(dk inspect --format '{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$name" 2>/dev/null)"; then
      echo "container $name does not exist"
      continue
    fi
    state="${st%%|*}"
    health="${st#*|}"
    if [ "$state" != "running" ]; then
      echo "$name is $state"
    elif [ -z "$only_run" ] && [ "$health" != "healthy" ]; then
      echo "$name is ${health:-without a health status}"
    fi
  done
}

wait_healthy() {
  local deadline problems
  deadline=$((SECONDS + HEALTH_TIMEOUT))
  while :; do
    problems="$(stack_problems)"
    if [ -z "$problems" ]; then
      info "healthy: both containers"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      err "$problems"
      die "the stack is not healthy after ${HEALTH_TIMEOUT}s (unhealthy: $(tr '\n' ';' <<<"$problems"))"
    fi
    sleep "$POLL"
  done
}

# ---- install ----

sysctl_payload() { printf '%s\n' 'vm.overcommit_memory = 1'; }

# install_overcommit: Redis wants vm.overcommit_memory=1 for background saves, and a plain `sysctl -w` reverts at the
# next boot. Write the drop-in (an existing /etc/sysctl.d is never touched) and set the live value only when it differs.
# shellcheck disable=SC2016 # expanded by the shell that sudo starts
install_overcommit() {
  local dir v
  dir="$(dirname "$SYSCTL_FILE")"
  priv test -d "$dir" || ensure_dir "$dir" 0 0 755
  sysctl_payload > "$TMP/sysctl.conf"
  place_file "$TMP/sysctl.conf" "$SYSCTL_FILE" 644
  v="$(priv cat -- "$OVERCOMMIT_FILE" 2>/dev/null)" || v=""
  if [ "$v" = "1" ]; then
    info "already: vm.overcommit_memory is 1"
    return 0
  fi
  if ! priv sh -c 'printf "1\n" > "$1"' sh "$OVERCOMMIT_FILE"; then
    warn "cannot set vm.overcommit_memory (is '${v:-unreadable}'): the drop-in is in place, so it applies at the next boot"
    return 0
  fi
  info "changed: vm.overcommit_memory set to 1 (was '${v:-unreadable}')"
  CHANGED=1
}

do_install() {
  local problems line uid stopped
  require_privilege
  TMP="$(mktemp -d)"

  problems="$(chk_deploy_user; chk_network; chk_admin_file Postgres "$PG_ADMIN_FILE"; chk_admin_file Redis "$REDIS_ADMIN_FILE"; chk_groups; chk_secret_paths)"
  if [ -n "$problems" ]; then
    while IFS= read -r line; do err "install-data: $line"; done <<<"$problems"
    print_instructions
    die "preconditions failed; nothing was installed and no mutating docker command was run"
  fi
  uid="$(deploy_uid)"

  payload_compose > "$TMP/compose.yaml"
  payload_pg_hba > "$TMP/pg_hba.conf"
  payload_redis_entrypoint > "$TMP/redis-entrypoint.sh"
  payload_reserved_names > "$TMP/reserved-names.txt"
  payload_new_db > "$TMP/new-db.sh"
  connection_env > "$TMP/connection.env"

  ensure_dir "$INSTALL_DIR" 0 0 755
  # A new install directory means a first install: everything below is new, so recreate.
  [ "$CHANGED" -eq 0 ] || FORCE_RECREATE=1
  place_file "$TMP/compose.yaml" "$INSTALL_DIR/compose.yaml" 644
  COMPOSE_CHANGED="$LAST_PLACED"
  # pg_hba.conf and the entrypoint are bind-mounted: a running container does not re-read them, and a config hash does
  # not see their content, so a change forces a recreate. A changed compose.yaml is handled by a plain `up -d`, which
  # recreates exactly the services whose configuration changed.
  place_file "$TMP/pg_hba.conf" "$INSTALL_DIR/pg_hba.conf" 644
  [ "$LAST_PLACED" -eq 0 ] || FORCE_RECREATE=1
  place_file "$TMP/redis-entrypoint.sh" "$INSTALL_DIR/redis-entrypoint.sh" 755
  [ "$LAST_PLACED" -eq 0 ] || FORCE_RECREATE=1
  place_file "$TMP/reserved-names.txt" "$INSTALL_DIR/reserved-names.txt" 644
  # new-db.sh is run by `platform new-db` (the deploy user), not mounted: a change never recreates the containers.
  place_file "$TMP/new-db.sh" "$INSTALL_DIR/new-db.sh" 755
  place_file "$TMP/connection.env" "$INSTALL_DIR/connection.env" 644
  ensure_dir "$VAR_DIR" 0 0 755
  ensure_dir "$SECRETS_DIR" "$uid" "$SECRETS_GID" 2710
  install_overcommit

  # Always run `up -d`: it is a no-op on a converged stack, and it closes the window where an earlier run placed new files
  # and then failed before `up` (the next run sees every file as "already" but the containers are stale).
  if [ "$FORCE_RECREATE" -eq 1 ]; then
    compose up -d --remove-orphans --force-recreate || die "docker compose up failed"
    info "changed: stack started"
  else
    stopped="$(stack_problems run)"
    compose up -d --remove-orphans || die "docker compose up failed"
    if [ -n "$stopped" ] || [ "$COMPOSE_CHANGED" -eq 1 ]; then info "changed: stack started"; else info "already: stack running"; fi
  fi
  wait_healthy
  info "install-data: done"
}

# ---- status / verify ----

check_meta() {
  local label="$1" path="$2" want="$3" meta
  if [ ! -e "$path" ]; then fail "$label missing: $path"; return 1; fi
  if [ -L "$path" ]; then fail "$label is a symlink: $path"; return 1; fi
  meta="$(file_meta "$path")" || meta="unreadable"
  if [ "$meta" = "$want" ]; then pass "$label owner/mode ($meta)"; else fail "$label uid:gid/mode is '$meta', want '$want'"; return 1; fi
}

check_payload() {
  local label="$1" path="$2" fn="$3"
  if [ -f "$path" ] && "$fn" | cmp -s - "$path"; then pass "$label bytes equal the embedded payload"; else fail "$label bytes differ from the embedded payload"; fi
}

# run_check <label> <fn> [args...]: PASS when the chk function prints nothing, one FAIL per printed problem otherwise.
run_check() {
  local label="$1" probs line
  shift
  probs="$("$@")"
  if [ -z "$probs" ]; then
    pass "$label"
  else
    while IFS= read -r line; do fail "$label: $line"; done <<<"$probs"
  fi
}

# container_checks <name>: the per-container security properties. Admin passwords are compared inside this shell only:
# never printed, never in an argv.
# shellcheck disable=SC2016 # the {{ }} docker templates are literal on purpose
container_checks() {
  local name="$1" out envcmd label pw esc
  out="$(dk port "$name" 2>/dev/null || true)"
  if [ -z "$out" ]; then pass "$name publishes no port"; else fail "$name publishes a port"; fi

  out="$(dk inspect --format '{{range $k, $v := .Config.Labels}}{{$k}}{{"\n"}}{{end}}' "$name" 2>/dev/null || echo "inspect-failed")"
  if [ "$out" = "inspect-failed" ]; then fail "cannot inspect the labels of $name"
  elif grep -qxF "platform.app" <<<"$out"; then fail "$name carries the platform.app label"
  else pass "$name carries no platform.app label"; fi

  out="$(dk inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$name" 2>/dev/null || echo "inspect-failed")"
  if [ "$out" = "inspect-failed" ]; then fail "cannot inspect the networks of $name"
  elif [ "$out" = "$NETWORK" ]; then pass "$name is only on the $NETWORK network"
  else fail "$name is not exactly on the $NETWORK network (networks: $(tr '\n' ' ' <<<"$out"))"; fi

  envcmd="$(dk inspect --format '{{json .Config.Env}} {{json .Config.Cmd}} {{json .Config.Healthcheck}}' "$name" 2>/dev/null || true)"
  for label in Postgres Redis; do
    if [ "$label" = "Postgres" ]; then read_secret "$PG_ADMIN_FILE" || SECRET=""; else read_secret "$REDIS_ADMIN_FILE" || SECRET=""; fi
    pw="$SECRET"
    SECRET=""
    if [ -z "$pw" ] || [ -z "$envcmd" ]; then
      fail "cannot compare the $label admin password with the Env, Cmd and Healthcheck of $name"
      continue
    fi
    esc="${pw//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    if [[ "$envcmd" == *"$pw"* ]] || [[ "$envcmd" == *"$esc"* ]]; then
      fail "the $label admin password appears in the Env, Cmd or Healthcheck of $name"
    else
      pass "the $label admin password is not in the Env, Cmd or Healthcheck of $name"
    fi
  done
}

# Runs redis-cli as the admin user inside the Redis container. The password is read from the mounted file inside the
# container, with exactly one trailing newline stripped (as the entrypoint's hash does), and handed over through
# REDISCLI_AUTH: it is never in an argv on the host or in the container.
# shellcheck disable=SC2016 # expanded by the shell inside the container
readonly REDIS_ADMIN_SNIPPET='f="$1"; shift; pw="$(cat "$f"; printf x)"; pw="${pw%x}"; nl="$(printf "\nx")"; nl="${nl%x}"; case "$pw" in *"$nl") pw="${pw%"$nl"}" ;; esac; REDISCLI_AUTH="$pw" exec redis-cli --user admin --no-auth-warning "$@"'
redis_admin() { dk exec "$REDIS" sh -c "$REDIS_ADMIN_SNIPPET" sh "$REDIS_CTR_ADMIN_FILE" "$@"; }

# redis_get <config key>: the value of one CONFIG GET (second line of the reply).
redis_get() {
  local reply
  reply="$(redis_admin config get "$1" | tr -d '\r')" || return 1
  sed -n '2p' <<<"$reply"
}

# acl_tok <token>: a token made safe to print. Anything that could be credential material (a hash, a password token)
# is redacted; otherwise only a conservative character class survives (no '#').
# shellcheck disable=SC2329 # reached through acl_problems, which run_check invokes by name
acl_tok() {
  case "$1" in
    "#"* | ">"* | "<"*) printf '<redacted>' ;;
    *) printf '%s' "${1//[^A-Za-z0-9_@:*~&%+-]/?}" ;;
  esac
}

# acl_problems <ACL LIST text>: one line per problem. Accepted: default (off), admin, health (each restricted), and any
# non-reserved app user whose rule is key-scoped (~<name>:*), has no channels and has the dangerous commands denied.
# shellcheck disable=SC2329 # reached through chk_redis_acl, which run_check invokes by name
acl_problems() {
  local text="$1" reserved line name rest t seen=" " d later
  local -a tok
  reserved="$(reserved_names)"
  while IFS= read -r line; do
    line="${line%$'\r'}"
    [ -n "$line" ] || continue
    read -r -a tok <<<"$line"
    if [ "${tok[0]:-}" != "user" ] || [ -z "${tok[1]:-}" ]; then echo "unparseable Redis ACL line"; continue; fi
    name="${tok[1]}"
    rest="${tok[*]:2}"
    seen+="$name "
    case "$name" in
      default)
        [[ " $rest " == *" off "* ]] || echo "the Redis default user is not switched off"
        [[ " $rest " != *" on "* ]] || echo "the Redis default user is enabled"
        ;;
      admin)
        [[ " $rest " == *" on "* ]] || echo "the Redis admin user is not enabled"
        [[ " $rest " != *" nopass "* ]] || echo "the Redis admin user has no password (nopass)"
        ;;
      health)
        for t in "${tok[@]:2}"; do
          case "$t" in
            on | nopass | sanitize-payload | skip-sanitize-payload | resetchannels | -@all | +ping) ;;
            *) echo "the Redis health user has an unexpected rule '$(acl_tok "$t")'" ;;
          esac
        done
        for t in on nopass -@all +ping; do
          [[ " $rest " == *" $t "* ]] || echo "the Redis health user lacks '$t'"
        done
        ;;
      *)
        if ! [[ "$name" =~ $APP_RE ]] || grep -qxF -- "$name" <<<"$reserved"; then
          echo "unexpected Redis ACL user '${name//[^A-Za-z0-9_-]/?}'"
          continue
        fi
        [[ " $rest " == *" on "* ]] || echo "Redis user $name is not enabled"
        [[ " $rest " != *" nopass "* ]] || echo "Redis user $name has no password (nopass)"
        [[ " $rest " == *" ~$name:* "* ]] || echo "Redis user $name lacks the key scope ~$name:*"
        [[ " $rest " == *" resetchannels "* ]] || echo "Redis user $name lacks resetchannels"
        for d in -@dangerous -scan -randomkey -dbsize; do
          [[ " $rest " == *" $d "* ]] || echo "Redis user $name lacks $d"
        done
        # Allowlist of tokens: anything else (a selector, reset, nocommands, alldbs, a password token, ...) fails.
        for t in "${tok[@]:2}"; do
          case "$t" in
            "("* | *")" | reset | nocommands | alldbs) echo "Redis user $name has an unexpected rule '$(acl_tok "$t")' (selector or reset)" ;;
            "~$name:*") ;;
            "~"* | "%"* | allkeys | "&"* | allchannels) echo "Redis user $name has an extra key or channel scope '$(acl_tok "$t")'" ;;
            on | nopass | sanitize-payload | skip-sanitize-payload | resetchannels | allcommands) ;;
            "+"* | "-"*) ;;
            "#"*) [[ "$t" =~ ^#[A-Za-z0-9]+$ ]] || echo "Redis user $name has an unexpected rule '$(acl_tok "$t")'" ;;
            *) echo "Redis user $name has an unexpected rule '$(acl_tok "$t")'" ;;
          esac
        done
        # The deny tokens must come last: an allow added after them would re-enable the command.
        later=0
        for t in "${tok[@]:2}"; do
          case "$t" in
            -@dangerous | -scan | -randomkey | -dbsize) later=1 ;;
            +* | allcommands) [ "$later" -eq 0 ] || echo "Redis user $name allows '$(acl_tok "$t")' after the deny rules" ;;
          esac
        done
        ;;
    esac
  done <<<"$text"
  for name in default admin health; do
    [[ "$seen" == *" $name "* ]] || echo "the Redis $name user is missing"
  done
}

# shellcheck disable=SC2329 # invoked by name through run_check
chk_redis_acl() {
  local text
  text="$(redis_admin acl list)" || { echo "cannot read ACL LIST (admin auth failed or Redis is down)"; return 0; }
  acl_problems "$text"
}

check_redis_config() {
  local v
  if v="$(redis_get maxmemory-policy)" && [ -n "$v" ]; then
    if [ "$v" = "noeviction" ]; then pass "Redis eviction policy is noeviction"; else fail "Redis eviction policy is '${v//[^A-Za-z0-9_-]/?}', want noeviction"; fi
  else
    fail "cannot read the Redis maxmemory-policy"
  fi
  if v="$(redis_get appendonly)" && [ -n "$v" ]; then
    if [ "$v" = "yes" ]; then pass "Redis AOF is on"; else fail "Redis appendonly is '${v//[^A-Za-z0-9_-]/?}', want yes"; fi
  else
    fail "cannot read the Redis appendonly setting"
  fi
}

# check_redis_memory: WARN at about 80% of maxmemory (advisory, never changes the exit status); an unreadable INFO fails.
check_redis_memory() {
  local info used max
  if ! info="$(redis_admin info memory | tr -d '\r')"; then fail "cannot read INFO memory from Redis"; return 0; fi
  used="$(sed -n 's/^used_memory:\([0-9][0-9]*\)$/\1/p' <<<"$info" | head -n 1)"
  max="$(sed -n 's/^maxmemory:\([0-9][0-9]*\)$/\1/p' <<<"$info" | head -n 1)"
  if [ -z "$used" ] || [ -z "$max" ]; then fail "INFO memory has no used_memory or maxmemory"; return 0; fi
  if [ "$max" -eq 0 ]; then fail "Redis maxmemory is 0 (unbounded)"; return 0; fi
  if [ $((used * 100)) -ge $((max * 80)) ]; then
    warn "Redis memory is at $((used * 100 / max))% of maxmemory ($used of $max bytes); it is shared by all apps and a full Redis rejects every app's writes"
  else
    pass "Redis memory is at $((used * 100 / max))% of maxmemory"
  fi
}

# pg_query <sql>: one query over the local socket as the postgres user (peer auth, no password), tuples only.
pg_query() { dk exec "$PG" psql -X -U postgres -d postgres -At -v ON_ERROR_STOP=1 -c "$1"; }

check_postgres() {
  local v open apps
  if v="$(pg_query "SHOW log_min_error_statement")"; then
    if [ "$v" = "panic" ]; then pass "Postgres log_min_error_statement is panic"; else fail "Postgres log_min_error_statement is '${v//[^A-Za-z0-9_-]/?}', want panic"; fi
  else
    fail "cannot read Postgres log_min_error_statement"
  fi
  if v="$(pg_query "SHOW log_statement")"; then
    if [ "$v" = "none" ]; then pass "Postgres log_statement is none"; else fail "Postgres log_statement is '${v//[^A-Za-z0-9_-]/?}', want none"; fi
  else
    fail "cannot read Postgres log_statement"
  fi
  # The running server must use the installed pg_hba.conf (as the container sees it) and every rule must parse and be
  # peer (the one local line) or scram-sha-256: a container left over from a failed `up` could run other rules.
  if v="$(pg_query "SHOW hba_file")"; then
    if [ "$v" = "$PG_CTR_HBA" ]; then pass "Postgres hba_file is $PG_CTR_HBA"; else fail "Postgres hba_file is '${v//[^A-Za-z0-9_./-]/?}', want $PG_CTR_HBA"; fi
  else
    fail "cannot read the Postgres hba_file"
  fi
  if v="$(pg_query "SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL OR auth_method IS NULL OR auth_method NOT IN ('peer', 'scram-sha-256', 'reject')")" && [[ "$v" =~ ^[0-9]+$ ]]; then
    if [ "$v" -eq 0 ]; then pass "every pg_hba rule parses and uses peer, scram-sha-256 or reject"; else fail "pg_hba_file_rules has $v rule(s) with an error or an auth method other than peer, scram-sha-256 or reject"; fi
  else
    fail "cannot read pg_hba_file_rules"
  fi
  # datacl NULL means the default privileges, which include CONNECT for PUBLIC.
  if ! open="$(pg_query "SELECT datname FROM pg_database WHERE datname IN ('postgres', 'template1') AND (datacl IS NULL OR EXISTS (SELECT 1 FROM aclexplode(datacl) a WHERE a.grantee = 0 AND a.privilege_type = 'CONNECT')) ORDER BY 1")"; then
    fail "cannot read the PUBLIC CONNECT privilege on postgres and template1"
    return 0
  fi
  if ! apps="$(pg_query "SELECT count(*) FROM pg_database WHERE datname NOT IN ('postgres', 'template0', 'template1')")" || ! [[ "$apps" =~ ^[0-9]+$ ]]; then
    fail "cannot count the app databases"
    return 0
  fi
  if [ -z "$open" ]; then
    pass "PUBLIC has no CONNECT on postgres and template1"
  elif [ "$apps" -eq 0 ]; then
    info "already: no apps yet, posture applied by new-db"
  else
    fail "PUBLIC still has CONNECT on: $(tr '\n' ' ' <<<"$open")(an app database exists, so new-db should have revoked it)"
  fi
}

check_overcommit() {
  local v
  if ! v="$(priv cat -- "$OVERCOMMIT_FILE" 2>/dev/null)" || [ "$v" != "1" ]; then
    warn "vm.overcommit_memory is '${v:-unreadable}', Redis wants 1 for background saves under memory pressure: run install, which writes $SYSCTL_FILE and sets it"
  elif [ -f "$SYSCTL_FILE" ] && sysctl_payload | cmp -s - "$SYSCTL_FILE" && [ "$(file_meta "$SYSCTL_FILE" 2>/dev/null)" = "0:0 644" ]; then
    pass "vm.overcommit_memory is 1 and persisted in $SYSCTL_FILE"
  else
    warn "vm.overcommit_memory is 1 now but $SYSCTL_FILE is missing, differs or is not root:root 0644, so it may revert at the next boot: run install"
  fi
}

do_checks() {
  local problems line name
  check_meta "install directory" "$INSTALL_DIR" "0:0 755" || true
  check_meta "compose.yaml" "$INSTALL_DIR/compose.yaml" "0:0 644" || true
  check_payload "compose.yaml" "$INSTALL_DIR/compose.yaml" payload_compose
  check_meta "pg_hba.conf" "$INSTALL_DIR/pg_hba.conf" "0:0 644" || true
  check_payload "pg_hba.conf" "$INSTALL_DIR/pg_hba.conf" payload_pg_hba
  check_meta "redis-entrypoint.sh" "$INSTALL_DIR/redis-entrypoint.sh" "0:0 755" || true
  check_payload "redis-entrypoint.sh" "$INSTALL_DIR/redis-entrypoint.sh" payload_redis_entrypoint
  check_meta "reserved-names.txt" "$INSTALL_DIR/reserved-names.txt" "0:0 644" || true
  check_payload "reserved-names.txt" "$INSTALL_DIR/reserved-names.txt" payload_reserved_names
  check_meta "new-db.sh" "$INSTALL_DIR/new-db.sh" "0:0 755" || true
  check_payload "new-db.sh" "$INSTALL_DIR/new-db.sh" payload_new_db
  check_meta "connection.env" "$INSTALL_DIR/connection.env" "0:0 644" || true
  check_payload "connection.env" "$INSTALL_DIR/connection.env" connection_env

  run_check "deploy user" chk_deploy_user
  run_check "network $NETWORK" chk_network
  run_check "Postgres admin password file" chk_admin_file Postgres "$PG_ADMIN_FILE"
  run_check "Redis admin password file" chk_admin_file Redis "$REDIS_ADMIN_FILE"
  run_check "secret groups are private" chk_groups
  run_check "secrets paths" chk_secret_paths
  run_check "secrets root and its parent" chk_secrets_dirs

  problems="$(stack_problems)"
  if [ -z "$problems" ]; then
    pass "both containers are running and healthy"
  else
    while IFS= read -r line; do fail "$line"; done <<<"$problems"
  fi
  for name in "$PG" "$REDIS"; do container_checks "$name"; done

  run_check "Redis ACL users" chk_redis_acl
  check_redis_config
  check_redis_memory
  check_postgres
  check_overcommit
}

do_report() {
  require_privilege
  do_checks
  if [ "$FAILURES" -gt 0 ]; then
    printf 'install-data: %d check(s) failed\n' "$FAILURES"
    [ "$1" = "status" ] || exit 1
  else
    printf 'install-data: all checks passed\n'
  fi
}

# ---- main ----

main() {
  local cmd="install" host=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      install | status | verify) cmd="$1"; shift ;;
      --host) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "missing value for --host" 2; host="$2"; shift 2 ;;
      -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  case "$host" in -*) die "refusing option-looking --host: $host" 2 ;; esac
  [[ "$HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] || die "INSTALL_DATA_HEALTH_TIMEOUT must be a whole number of seconds" 2
  [[ "$POLL" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "INSTALL_DATA_POLL must be a number of seconds" 2

  if [ -n "$host" ]; then
    exec ssh -o BatchMode=yes -- "$host" "bash -s -- $cmd" < "${BASH_SOURCE[0]}"
  fi

  case "$cmd" in
    install) do_install ;;
    status | verify) do_report "$cmd" ;;
  esac
}

main "$@"
exit 0
