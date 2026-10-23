#!/usr/bin/env bash
# Pre-merge round trip of the REAL backup.sh and restore.sh against the REAL pinned Postgres and Redis (compose.yaml of the
# data stack), the real new-db.sh, the real restic and a local-directory restic repository.
#
# Needs docker, the compose plugin and restic on PATH. Without any of them (CI has no docker daemon) it skips with a loud
# banner and exits 0. Run it once un-skipped on a docker host before merge, with REQUIRE_DOCKER=1 so a skip becomes a
# failure (a skip is otherwise indistinguishable from a pass):
#   REQUIRE_DOCKER=1 bash platform/backup/test_backup_live.sh > /tmp/claude/backup-live.txt 2>&1
# An image that is not cached and cannot be pulled within the timeout is a skip too. BR2LIVE_SKIP=1 opts out (ordinary
# developer `make test` runs); it is still a failure under REQUIRE_DOCKER=1.
#
# Not provable here (unprivileged), so a Pi acceptance item (Steps 5-6): the restored secrets really are owned by
# deploy:64323, a root-only restore (EUID 0 without PLATFORM_RESTORE_ALLOW_NONROOT), the R2 S3 path, timer persistence.
# Here the chown is a recording stub and a stat stub reports the recorded owner for the paths the stub chowned.
#
# Isolation: every container, network, volume and compose project carries the unique prefix br2test-<pid>-<random>. The
# compose file under test is generated from the data stack's compose.yaml, changing only mount sources, names and project
# (asserted by reversing the substitutions). Nothing real is touched: not the platform network, not the platform-data-*
# volumes or containers, not /etc/platform, not any R2 credential. Everything is removed on every exit path.
#
# Hints:
#   leftover containers after a killed run -> docker ps -a --filter name=br2test-   (remove by that prefix)
#   exit 2 with an env-file refusal        -> PLATFORM_BACKUP_ENV_OWNER missing or not the test user's uid:gid
#   restic not found                       -> the test skips (exit 1 under REQUIRE_DOCKER=1): install restic 0.18.1
#   image pull timeout                     -> pre-pull the two images pinned in platform/data/compose.yaml
# shellcheck disable=SC1091,SC2015
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
# shellcheck source=../lib/yaml-subset.sh
. "$here/../lib/yaml-subset.sh"

skip() {
  if [ "${REQUIRE_DOCKER:-0}" = 1 ]; then
    echo "FAIL: $(basename "$0"): $1 (REQUIRE_DOCKER=1 turns a skip into a failure)"
    exit 1
  fi
  echo "################################################################"
  echo "## $(basename "$0") SKIPPED: $1"
  echo "## The live backup/restore round trip did NOT run. Run it on a docker host before merge (REQUIRE_DOCKER=1)."
  echo "################################################################"
  exit 0
}

[ "${BR2LIVE_SKIP:-0}" != 1 ] || skip "BR2LIVE_SKIP=1"
command -v docker > /dev/null 2>&1 || skip "docker is not installed"
command -v restic > /dev/null 2>&1 || skip "restic is not on PATH"
docker info > /dev/null 2>&1 || skip "the docker daemon is not reachable by this user"
docker compose version > /dev/null 2>&1 || skip "the docker compose plugin is not available"

real_getent="$(command -v getent)"
real_stat="$(command -v stat)"
real_docker="$(command -v docker)"
[ -n "$real_getent" ] && [ -n "$real_stat" ] || skip "getent or stat is not available"

t_init

# <=23 chars: rid-a fits the app-name pattern (^[a-z][a-z0-9-]{1,30}$) and the role/db pattern with _ for -.
rid="br2test-$$-$RANDOM"
proj="$rid-proj"
net="$rid-net"
PGC="$rid-postgres"
RDC="$rid-redis"
gen="$T_TMP/compose.live.yaml"
payload="$T_TMP/payload"
secrets="$T_TMP/secrets"
pg_admin_file="$T_TMP/postgres-admin.password"
redis_admin_file="$T_TMP/redis-admin.password"
broot="$T_TMP/backup-root"
bstate="$T_TMP/backup-status"
blog="$T_TMP/backup-log"
block="$T_TMP/backup.lock"
envf="$T_TMP/backup.env"
repo="$T_TMP/repo"
chown_log="$T_TMP/chown.log"
test_uid="$(id -u)"
test_gid="$(id -g)"
restic_pw="rp-$RANDOM-$RANDOM"
dc() { docker compose -p "$proj" -f "$gen" "$@"; }

cleanup() {
  local ids
  [ ! -f "$gen" ] || docker compose -p "$proj" -f "$gen" down -v --remove-orphans > /dev/null 2>&1
  ids="$(docker ps -aq --filter "name=^${rid}-" 2> /dev/null)"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker rm -fv $ids > /dev/null 2>&1
  docker volume rm -f "$rid-postgres" "$rid-redis" > /dev/null 2>&1
  docker network rm "$net" > /dev/null 2>&1
  t_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---- helpers (the same shapes as test_data_live.sh) ----

expect_has() { if grep -qF -- "$3" <<< "$2"; then _pass; else _fail "$1" "lacks: $3 (got: ${2:0:600})"; fi; }
expect_lacks() { if grep -qF -- "$3" <<< "$2"; then _fail "$1" "unexpectedly has: $3"; else _pass; fi; }
expect_re() { if grep -qE -- "$3" <<< "$2"; then _pass; else _fail "$1" "does not match /$3/ (got: ${2:0:600})"; fi; }

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }

wait_healthy() {
  local c="$1" t="${2:-120}" i st
  for ((i = 0; i < t; i += 2)); do
    st="$(docker inspect --format '{{.State.Status}}|{{.State.Health.Status}}' "$c" 2> /dev/null)"
    [ "$st" = "running|healthy" ] && return 0
    sleep 2
  done
  echo "container $c not healthy after ${t}s (last: ${st:-none})"
  docker logs "$c" 2>&1 | tail -n 15
  return 1
}

snippet="$(sed -n "s/^readonly REDIS_ADMIN_SNIPPET='\(.*\)'\$/\1/p" "$here/../data/new-db.sh")"
[ -n "$snippet" ] || { echo "FAIL: cannot read REDIS_ADMIN_SNIPPET from new-db.sh"; exit 1; }
rdadmin() { docker exec -i "$RDC" sh -c "$snippet" sh /etc/platform/redis-admin.password "$@" 2>&1 < /dev/null; }

redis_as() {
  local user="$1" pwf="$2"
  shift 2
  printf '%s\n' "$(< "$pwf")" | docker exec -i "$RDC" sh -c 'IFS= read -r REDISCLI_AUTH; export REDISCLI_AUTH; u="$1"; shift; exec redis-cli --user "$u" --no-auth-warning "$@"' sh "$user" "$@" 2>&1
}

pg_admin() { docker exec -i "$PGC" psql -X -U postgres -d "${2:-postgres}" -At -v ON_ERROR_STOP=1 -c "$1" 2>&1 < /dev/null; }

pg_as() {
  local role="$1" pwf="$2" db="$3" sql="$4"
  printf '%s\n' "$(< "$pwf")" | docker exec -i "$PGC" sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -X -h 127.0.0.1 -U "$1" -d "$2" -At -v ON_ERROR_STOP=1 -c "$3"' sh "$role" "$db" "$sql" 2>&1
}

newdb() {
  NEW_DB_PG_CONTAINER="$PGC" NEW_DB_REDIS_CONTAINER="$RDC" NEW_DB_RESERVED_NAMES="$here/../registry/reserved-names.txt" \
    NEW_DB_SECRETS_ROOT="$secrets" NEW_DB_LOCK_WAIT=10 NEW_DB_EXEC_TIMEOUT=60 bash "$here/../data/new-db.sh" "$1" 2>&1
}

verify() {
  env INSTALL_DATA_SUDO= INSTALL_DATA_PG_CONTAINER="$PGC" INSTALL_DATA_REDIS_CONTAINER="$RDC" INSTALL_DATA_NETWORK="$net" \
    INSTALL_DATA_DIR="$payload" INSTALL_DATA_VAR_DIR="$T_TMP/var" INSTALL_DATA_SECRETS_ROOT="$secrets" \
    INSTALL_DATA_PG_ADMIN_FILE="$pg_admin_file" INSTALL_DATA_REDIS_ADMIN_FILE="$redis_admin_file" \
    bash "$here/../host/install-data.sh" verify 2>&1
}

# The shared PLATFORM_BACKUP_* overrides: the same list for backup.sh and restore.sh (a restore resolves its in-snapshot
# paths from the values the backup ran with).
shared_ov() {
  printf '%s\0' "PLATFORM_BACKUP_ENV_FILE=$envf" "PLATFORM_BACKUP_ENV_OWNER=$test_uid:$test_gid" "PLATFORM_BACKUP_ROOT=$broot" \
    "PLATFORM_BACKUP_STATE_DIR=$bstate" "PLATFORM_BACKUP_LOG_DIR=$blog" "PLATFORM_BACKUP_LOCK=$block" \
    "PLATFORM_BACKUP_SECRETS_ROOT=$secrets" "PLATFORM_BACKUP_PG_ADMIN_FILE=$pg_admin_file" \
    "PLATFORM_BACKUP_REDIS_ADMIN_FILE=$redis_admin_file" "PLATFORM_BACKUP_PG_CONTAINER=$PGC" "PLATFORM_BACKUP_REDIS_CONTAINER=$RDC"
}
mapfile -d '' -t SHARED < <(shared_ov)

restore_ov() {
  printf '%s\0' "PLATFORM_RESTORE_ALLOW_NONROOT=1" "PLATFORM_RESTORE_CHOWN=chown-stub" "PLATFORM_RESTORE_COMPOSE=$gen" \
    "PLATFORM_RESTORE_INSTALL_DATA=$T_TMP/install-data-stub.sh"
}
mapfile -d '' -t RESTOREOV < <(restore_ov)

# run_backup <out file>: the real backup.sh, unprivileged, only through the documented overrides.
run_backup() { timeout 600 env "${SHARED[@]}" bash "$here/backup.sh" manual > "$1" 2>&1; }

# run_restore <out file> <restore.sh args...>: the real restore.sh with the shared + restore-only overrides, plus the
# install-data stub (it records its argv; the real verify needs root-owned host files, see the full section below).
run_restore() {
  local out_file="$1"
  shift
  timeout 900 env "${SHARED[@]}" "${RESTOREOV[@]}" bash "$here/restore.sh" "$@" > "$out_file" 2>&1
}

# ---- stubs: getent (deploy only), chown-stub (records), stat (reports the recorded owner), curl (Discord) ----

{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "$#" -eq 2 ] && [ "$1" = passwd ] && [ "$2" = deploy ]; then\n'
  printf '  echo "deploy:x:%s:%s:deploy:/nonexistent:/usr/sbin/nologin"; exit 0\nfi\n' "$test_uid" "$test_gid"
  printf 'printf "getent-forward %%s\\n" "$*" >> %q\n' "$T_TMP/getent-forward.log"
  printf 'exec %q "$@"\n' "$real_getent"
} > "$STUB_BIN/getent"
chmod +x "$STUB_BIN/getent"
: > "$T_TMP/getent-forward.log"

{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$*" >> %q\n' "$chown_log"
  printf 'exit 0\n'
} > "$STUB_BIN/chown-stub"
chmod +x "$STUB_BIN/chown-stub"
: > "$chown_log"

# stat stub: for `stat -c '%u:%g %a' -- <path>` on a path the chown stub recorded, report the recorded owner (a uid-only
# record keeps the real gid) and the real mode; everything else goes to the real stat.
{
  printf '#!/usr/bin/env bash\n'
  printf 'real=%q\nlog=%q\n' "$real_stat" "$chown_log"
  # shellcheck disable=SC2016 # the stub body is a literal
  printf '%s\n' \
    'if [ "$#" -eq 4 ] && [ "$1" = -c ] && [ "$2" = "%u:%g %a" ] && [ "$3" = -- ]; then' \
    '  p="$4"' \
    '  rec="$(awk -v p="$p" '"'"'{ if ($NF == p) { o = $1 } } END { print o }'"'"' "$log")"' \
    '  if [ -n "$rec" ]; then' \
    '    mode="$("$real" -c "%a" -- "$p")" || exit 1' \
    '    case "$rec" in' \
    '      *:*) echo "$rec $mode" ;;' \
    '      *) echo "$rec:$("$real" -c "%g" -- "$p") $mode" ;;' \
    '    esac' \
    '    exit 0' \
    '  fi' \
    'fi' \
    'exec "$real" "$@"'
} > "$STUB_BIN/stat"
chmod +x "$STUB_BIN/stat"
t_stub curl 0

# docker stub: logs argv (one line per call) and forwards to the real docker, so the run can prove which image, volume and
# container names every call used.
docker_log="$T_TMP/docker-calls.log"
: > "$docker_log"
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$*" >> %q\n' "$docker_log"
  printf 'exec %q "$@"\n' "$real_docker"
} > "$STUB_BIN/docker"
chmod +x "$STUB_BIN/docker"

# ---- read the stack definition and make sure the images are there ----

flat="$T_TMP/compose-flat"
if ! ys_flatten < "$here/../data/compose.yaml" > "$flat"; then
  echo "FAIL: compose.yaml is outside the YAML subset the tests understand"
  exit 1
fi
pgimg="$(ys_get "$flat" services/postgres/image)"
rdimg="$(ys_get "$flat" services/redis/image)"
for img in "$pgimg" "$rdimg"; do
  if ! docker image inspect "$img" > /dev/null 2>&1; then
    timeout 300 docker pull -q "$img" > /dev/null 2> "$T_TMP/pull-err" || { cat "$T_TMP/pull-err"; skip "cannot pull $img (offline or rate-limited)"; }
  fi
done

# ---- generate the isolated compose file (same mapping as test_data_live.sh) ----

mkdir -p "$payload" "$secrets" "$T_TMP/var"
chmod 2710 "$secrets"
cp "$here/../data/pg_hba.conf" "$payload/pg_hba.conf"
cp "$here/../data/redis-entrypoint.sh" "$payload/redis-entrypoint.sh"
chmod 0644 "$payload/pg_hba.conf"
chmod 0755 "$payload/redis-entrypoint.sh"
pg_pw="$(rand 24)"
redis_pw="$(rand 24)"
printf '%s\n' "$pg_pw" > "$pg_admin_file"
printf '%s\n' "$redis_pw" > "$redis_admin_file"
chmod 0644 "$pg_admin_file" "$redis_admin_file"

sed -e "s#^\\(      - \\)/etc/platform/postgres-admin.password:#\\1$pg_admin_file:#" \
  -e "s#^\\(      - \\)/etc/platform/redis-admin.password:#\\1$redis_admin_file:#" \
  -e "s#^\\(      - \\)/opt/platform/data/pg_hba.conf:#\\1$payload/pg_hba.conf:#" \
  -e "s#^\\(      - \\)/opt/platform/data/redis-entrypoint.sh:#\\1$payload/redis-entrypoint.sh:#" \
  -e "s#platform-data-#$rid-#g" \
  -e "s#^name: platform-data\$#name: $proj#" \
  "$here/../data/compose.yaml" | awk -v n="$net" '{ print } /^    external: true$/ { print "    name: " n }' > "$gen"

back="$T_TMP/compose.reversed"
awk -v n="    name: $net" '$0 != n { print }' "$gen" \
  | sed -e "s#^name: $proj\$#name: platform-data#" \
    -e "s#^\\(      - \\)$pg_admin_file:#\\1/etc/platform/postgres-admin.password:#" \
    -e "s#^\\(      - \\)$redis_admin_file:#\\1/etc/platform/redis-admin.password:#" \
    -e "s#^\\(      - \\)$payload/pg_hba.conf:#\\1/opt/platform/data/pg_hba.conf:#" \
    -e "s#^\\(      - \\)$payload/redis-entrypoint.sh:#\\1/opt/platform/data/redis-entrypoint.sh:#" \
    -e "s#$rid-#platform-data-#g" > "$back"
if cmp -s "$back" "$here/../data/compose.yaml"; then _pass; else _fail "the generated compose differs from compose.yaml beyond mount sources, names and project" "$(diff "$here/../data/compose.yaml" "$back" | head -n 12)"; fi
expect_eq "no real host mount source remains in the generated compose" "$(grep -cE '^      - /(etc/platform|opt/platform)/' "$gen")" 0
if grep -nE '(^|[^a-z-])platform-data-(postgres|redis)' "$gen" | grep -v '^[0-9]*:#' > /dev/null; then _fail "the generated compose still names a real platform-data object"; else _pass; fi

install_data_calls="$T_TMP/install-data-calls.log"
printf '#!/bin/sh\necho "install-data-stub $*" >> %s\nexit 0\n' "$install_data_calls" > "$T_TMP/install-data-stub.sh"
chmod +x "$T_TMP/install-data-stub.sh"

docker network create --label "br2test=$rid" "$net" > /dev/null || { echo "FAIL: network create"; exit 1; }

# ---- restic repository and env file ----

timeout 60 env RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$restic_pw" restic init > "$T_TMP/restic-init.txt" 2>&1 || { echo "FAIL: restic init"; cat "$T_TMP/restic-init.txt"; exit 1; }
{
  printf 'RESTIC_REPOSITORY=%s\n' "$repo"
  printf 'RESTIC_PASSWORD=%s\n' "$restic_pw"
  printf 'AWS_ACCESS_KEY_ID=dummy-access-key\n'
  printf 'AWS_SECRET_ACCESS_KEY=dummy-secret-key\n'
  printf 'AWS_DEFAULT_REGION=auto\n'
  printf 'DISCORD_WEBHOOK=https://hook.invalid/test\n'
} > "$envf"
chmod 0600 "$envf"
mkdir -p "$broot" "$blog"

rcmd() { timeout 120 env RESTIC_REPOSITORY="$repo" RESTIC_PASSWORD="$restic_pw" restic "$@" 2>&1; }

# ---- 1. fresh stack, two apps, seeded data ----

if ! dc up -d > "$T_TMP/up.txt" 2>&1; then
  echo "FAIL: compose up"
  cat "$T_TMP/up.txt"
  exit 1
fi
if wait_healthy "$PGC" && wait_healthy "$RDC"; then _pass; else _fail "a fresh stack becomes healthy"; exit 1; fi

app_a="$rid-a"
app_b="$rid-b"
role_a="${app_a//-/_}"
role_b="${app_b//-/_}"
out="$(newdb "$app_a")"
expect_has "new-db app A" "$out" "changed: postgres role and database $role_a"
out="$(newdb "$app_b")"
expect_has "new-db app B" "$out" "changed: postgres role and database $role_b"
pwa="$secrets/$app_a/db-password"
pwb="$secrets/$app_b/db-password"
rpa="$secrets/$app_a/redis-password"
rpb="$secrets/$app_b/redis-password"

out="$(pg_as "$role_a" "$pwa" "$role_a" 'create table t(x int primary key, v text); insert into t select g, md5(g::text) from generate_series(1,50) g; select count(*) from t')"
expect_has "A seeded 50 rows" "$out" "50"
out="$(pg_as "$role_b" "$pwb" "$role_b" 'create table u(x int); insert into u select g from generate_series(1,7) g; select count(*) from u')"
expect_has "B seeded 7 rows" "$out" "7"
sum_sql='select md5(string_agg(x::text || v, chr(44))) from (select * from t order by x) s'
sum_u_sql='select md5(string_agg(x::text, chr(44))) from (select * from u order by x) s'
# An extension created by the superuser (owner postgres, with its COMMENT) in A's database: a real dump carries
# CREATE EXTENSION and COMMENT ON EXTENSION, which `pg_restore --role=<app>` must survive (exit 0, no half-restored DB).
expect_eq "admin creates pgcrypto in A's database" "$(pg_admin 'create extension pgcrypto' "$role_a")" "CREATE EXTENSION"
sum_a_before="$(pg_as "$role_a" "$pwa" "$role_a" "$sum_sql")"
expect_re "A row checksum is a md5" "$sum_a_before" '^[0-9a-f]{32}$'
sum_b_before="$(pg_as "$role_b" "$pwb" "$role_b" "$sum_u_sql")"
expect_re "B row checksum is a md5" "$sum_b_before" '^[0-9a-f]{32}$'
expect_eq "A seeds a Redis string" "$(redis_as "$app_a" "$rpa" set "$app_a:k1" valueA)" OK
expect_eq "A seeds a Redis list" "$(redis_as "$app_a" "$rpa" rpush "$app_a:q" j1 j2 j3)" 3
expect_eq "B seeds a Redis string" "$(redis_as "$app_b" "$rpb" set "$app_b:k1" valueB)" OK

# ---- 2. the same invocations without the overrides are refused (exit 2) ----

rc=0
env -i PATH="$PATH" HOME="$HOME" PLATFORM_BACKUP_ENV_FILE="$envf" PLATFORM_BACKUP_ROOT="$broot" PLATFORM_BACKUP_STATE_DIR="$bstate" \
  PLATFORM_BACKUP_LOG_DIR="$blog" PLATFORM_BACKUP_LOCK="$block" timeout 60 bash "$here/backup.sh" manual > "$T_TMP/refuse-backup.txt" 2>&1 || rc=$?
expect_eq "backup.sh without PLATFORM_BACKUP_ENV_OWNER exits 2 (non-root-owned env file refused)" "$rc" 2
rc=0
env -i PATH="$PATH" HOME="$HOME" PLATFORM_BACKUP_ENV_FILE="$envf" PLATFORM_BACKUP_ENV_OWNER="$test_uid:$test_gid" PLATFORM_BACKUP_ROOT="$broot" \
  PLATFORM_BACKUP_LOG_DIR="$blog" timeout 60 bash "$here/restore.sh" list > "$T_TMP/refuse-restore.txt" 2>&1 || rc=$?
expect_eq "restore.sh without PLATFORM_RESTORE_ALLOW_NONROOT exits 2 (must run as root)" "$rc" 2

# ---- 3. backup ----

run_backup "$T_TMP/backup1.txt"
rc=$?
expect_eq "backup.sh manual exits 0" "$rc" 0
[ "$rc" -eq 0 ] || tail -n 40 "$T_TMP/backup1.txt"
for ph in preflight pg-list pg-globals "pg-db:$role_a" "pg-db:$role_b" redis restic-backup restic-forget restic-check volumes; do
  expect_has "backup log: phase $ph ran and ended rc=0" "$(< "$T_TMP/backup1.txt")" "phase=$ph end rc=0"
done
tsv="$(< "$bstate/last-run.tsv")"
expect_re "last-run.tsv says ok with a snapshot id" "$tsv" $'\tok\t[0-9a-f]{8,64}\t-$'
snaps="$(rcmd snapshots --json)"
expect_eq "exactly one snapshot exists" "$(grep -o '"short_id"' <<< "$snaps" | wc -l)" 1
expect_has "snapshot is tagged platform" "$snaps" '"platform"'
expect_has "snapshot is tagged manual" "$snaps" '"manual"'
expect_has "snapshot host is platform" "$snaps" '"hostname":"platform"'
ls_out="$(rcmd ls latest --host platform)"
for p in "$broot/staging/postgres/globals.sql" "$broot/staging/postgres/$role_a.dump" "$broot/staging/postgres/$role_b.dump" \
  "$broot/staging/redis/dump.rdb" "$broot/staging/redis/users.acl" "$secrets/$app_a/db-password" "$secrets/$app_a/redis-password" \
  "$secrets/$app_b/db-password" "$secrets/$app_b/redis-password" "$pg_admin_file" "$redis_admin_file"; do
  expect_re "snapshot holds ${p#"$T_TMP"/}" "$ls_out" "^${p//./\\.}\$"
done
expect_lacks "snapshot holds no lock file" "$ls_out" ".lock"
expect_eq "staging was wiped after the successful backup" "$([ -e "$broot/staging" ] && echo present || echo gone)" gone
cap_snap="$(grep -o '"short_id":"[0-9a-f]*"' <<< "$snaps" | head -n 1 | cut -d'"' -f4)"

# ---- 4. single-app restore into a new DB; the live DB is untouched ----

run_restore "$T_TMP/restore-app.txt" app "$app_a" --into "${role_a}_r"
rc=$?
expect_eq "restore.sh app exits 0" "$rc" 0
[ "$rc" -eq 0 ] || tail -n 40 "$T_TMP/restore-app.txt"
expect_has "restore app reports the row count of t" "$(< "$T_TMP/restore-app.txt")" "public.t: 50"
expect_eq "restored DB row count matches" "$(pg_admin 'select count(*) from t' "${role_a}_r")" 50
expect_eq "restored DB checksum matches" "$(pg_admin "$sum_sql" "${role_a}_r")" "$sum_a_before"
expect_eq "restored DB has pgcrypto (extension and its comment restored under --role)" "$(pg_admin "select extname || '|' || coalesce(obj_description(oid, 'pg_extension'), 'none') from pg_extension where extname = 'pgcrypto'" "${role_a}_r")" "pgcrypto|cryptographic functions"
expect_eq "restored DB is owned by the app role" "$(pg_admin "select pg_get_userbyid(datdba) from pg_database where datname='${role_a}_r'")" "$role_a"
expect_eq "restored table is owned by the app role" "$(pg_admin "select tableowner from pg_tables where tablename='t'" "${role_a}_r")" "$role_a"
expect_eq "live A DB checksum is unchanged by the restore" "$(pg_as "$role_a" "$pwa" "$role_a" "$sum_sql")" "$sum_a_before"
expect_eq "live B DB checksum is unchanged by the restore" "$(pg_as "$role_b" "$pwb" "$role_b" "$sum_u_sql")" "$sum_b_before"
out="$(pg_as "$role_a" "$pwa" "${role_a}_r" 'select count(*) from t')"
expect_eq "control: A connects to its restored DB" "$out" 50
out="$(pg_as "$role_b" "$pwb" "${role_a}_r" 'select 1')"
expect_has "B cannot connect to A's restored DB" "$out" "permission denied for database"
expect_eq "the restore leaves no restore dir behind" "$(find "$broot/restore" -mindepth 1 -maxdepth 1 | wc -l)" 0
run_restore "$T_TMP/restore-app2.txt" app "$app_a" --into "${role_a}_r"
rc=$?
expect_eq "a second restore into the same name is refused (exit 2)" "$rc" 2

# ---- 5. tear down with -v, drop the secrets, fresh stack ----

dc down -v > "$T_TMP/down.txt" 2>&1 || { echo "FAIL: compose down -v"; cat "$T_TMP/down.txt"; }
expect_eq "down -v removed both containers" "$(docker ps -aq --filter "name=^${rid}-" | wc -l)" 0
expect_eq "down -v removed both volumes" "$(docker volume ls -q --filter "name=^${rid}-" | wc -l)" 0
find "$secrets" -mindepth 1 -delete
expect_eq "the throwaway secrets are gone" "$(find "$secrets" -mindepth 1 | wc -l)" 0
# Rebuilt host: the admin files are gone too, and `host-files` (RUNBOOK order) brings them back before the stack starts.
rm -f "$pg_admin_file" "$redis_admin_file"
: > "$chown_log"
run_restore "$T_TMP/restore-hf0.txt" host-files
rc=$?
expect_eq "host-files restores the absent admin files (exit 0)" "$rc" 0
[ "$rc" -eq 0 ] || tail -n 30 "$T_TMP/restore-hf0.txt"
expect_has "host-files reports changed for the pg file" "$(< "$T_TMP/restore-hf0.txt")" "changed: $pg_admin_file"
expect_eq "the restored pg admin file holds the ORIGINAL password" "$(< "$pg_admin_file")" "$pg_pw"
expect_eq "the restored redis admin file holds the ORIGINAL password" "$(< "$redis_admin_file")" "$redis_pw"
expect_re "host-files chowned the pg file to root:64322 (stub record)" "$(< "$chown_log")" "^0:64322 -- .*\\.tmp\\.restore\\."
expect_eq "host-files chowned both admin files" "$(grep -c '^0:64322 -- ' "$chown_log")" 2
# The stubbed chown leaves them test-user-owned 0640: the containers (uid 999, group 64322) need them readable.
chmod 0644 "$pg_admin_file" "$redis_admin_file"
dc up -d > "$T_TMP/up2.txt" 2>&1 || { echo "FAIL: compose up (fresh)"; cat "$T_TMP/up2.txt"; exit 1; }
if wait_healthy "$PGC" && wait_healthy "$RDC"; then _pass; else _fail "the fresh stack becomes healthy"; exit 1; fi
expect_eq "fresh Postgres holds no app database" "$(pg_admin "select count(*) from pg_database where datname in ('$role_a','$role_b')")" 0
expect_eq "fresh Redis holds no seeded key" "$(rdadmin dbsize)" 0
# Before-state for the hardening assertion: on the fresh stack PUBLIC may still CONNECT to postgres and template1.
expect_eq "fresh stack: PUBLIC can CONNECT to postgres (before the restore)" "$(pg_admin "select has_database_privilege('public','postgres','CONNECT')")" t
expect_eq "fresh stack: PUBLIC can CONNECT to template1 (before the restore)" "$(pg_admin "select has_database_privilege('public','template1','CONNECT')")" t

# ---- 6. full restore ----

: > "$chown_log"
: > "$docker_log"
run_restore "$T_TMP/restore-full.txt" full --confirm-destroy
rc=$?
expect_eq "restore.sh full exits 0" "$rc" 0
[ "$rc" -eq 0 ] || tail -n 60 "$T_TMP/restore-full.txt"
full_out="$(< "$T_TMP/restore-full.txt")"
expect_has "full logs the snapshot it resolved" "$full_out" "snapshot selector=latest resolved id="
# The real install-data verify checks root ownership of the host files, which an unprivileged run cannot satisfy (a Pi
# acceptance item), so `full` runs a stub that records its argv (the wiring is proven) and the non-ownership checks of
# the real verify are asserted here against the restored stack.
expect_has "full ran install-data verify as its last step" "$(< "$install_data_calls")" "install-data-stub verify"
expect_has "the Redis admin login uses the ORIGINAL password after the full restore" "$(rdadmin ping)" PONG
expect_eq "PUBLIC cannot CONNECT to postgres after the full restore (privilege check)" "$(pg_admin "select has_database_privilege('public','postgres','CONNECT')")" f
expect_eq "PUBLIC cannot CONNECT to template1 after the full restore (privilege check)" "$(pg_admin "select has_database_privilege('public','template1','CONNECT')")" f
for a in "$app_a" "$app_b"; do
  expect_has "chown stub saw $a db-password" "$(< "$chown_log")" "$secrets/$a/db-password"
  expect_has "chown stub saw $a redis-password" "$(< "$chown_log")" "$secrets/$a/redis-password"
done
expect_has "full reports done" "$full_out" "full restore done from snapshot"
vout="$(verify)"
expect_has "verify on the restored stack: both containers healthy" "$vout" "PASS: both containers are running and healthy"
expect_has "verify on the restored stack: Redis ACL users" "$vout" "PASS: Redis ACL users"
expect_has "verify on the restored stack: PUBLIC has no CONNECT on postgres and template1" "$vout" "PASS: PUBLIC has no CONNECT on postgres and template1"
expect_has "verify on the restored stack: Redis AOF is on" "$vout" "PASS: Redis AOF is on"
expect_has "verify on the restored stack: hba file" "$vout" "PASS: Postgres hba_file is /etc/postgresql/pg_hba.conf"

# Deploy uid: from the PATH getent stub (passwd deploy only); positive control: another query reaches the real binary.
expect_re "the chown stub saw the test user's uid:gid-64323 target" "$(< "$chown_log")" "^$test_uid:64323 -- "
expect_eq "every secrets chown target carries the stubbed deploy uid" "$(grep -E ':64323 -- ' "$chown_log" | grep -vc "^$test_uid:64323 -- ")" 0
expect_re "control: getent passwd root reaches the real binary through the stub" "$(getent passwd root)" '^root:'
expect_has "control: the stub forwarded that other query" "$(< "$T_TMP/getent-forward.log")" "passwd root"

# Every app logs in with its RESTORED secret over TCP; the data is back.
for pair in "$role_a|$pwa|$rpa|$app_a" "$role_b|$pwb|$rpb|$app_b"; do
  IFS='|' read -r r pw rp a <<< "$pair"
  expect_eq "restored secret file exists: $a db-password" "$([ -s "$pw" ] && echo yes || echo no)" yes
  expect_eq "$a authenticates to Postgres with its restored secret" "$(pg_as "$r" "$pw" "$r" 'select current_database()')" "$r"
  expect_eq "$a authenticates to Redis with its restored secret" "$(redis_as "$a" "$rp" ping)" PONG
done
expect_eq "pgcrypto is back after the full restore" "$(pg_admin "select count(*) from pg_extension where extname = 'pgcrypto'" "$role_a")" 1
expect_eq "A rows are back (checksum)" "$(pg_as "$role_a" "$pwa" "$role_a" "$sum_sql")" "$sum_a_before"
expect_eq "B rows are back (checksum)" "$(pg_as "$role_b" "$pwb" "$role_b" "$sum_u_sql")" "$sum_b_before"
expect_eq "A Redis string is back" "$(redis_as "$app_a" "$rpa" get "$app_a:k1")" valueA
expect_eq "A Redis list is back" "$(redis_as "$app_a" "$rpa" lrange "$app_a:q" 0 -1 | tr '\n' ' ')" "j1 j2 j3 "
expect_eq "B Redis string is back" "$(redis_as "$app_b" "$rpb" get "$app_b:k1")" valueB
users="$(rdadmin acl users | sort | tr '\n' ' ')"
expect_eq "ACL users are present" "$users" "admin $app_a $app_b default health "
expect_has "A cannot read B's Redis key after the restore (ACL scope survived)" "$(redis_as "$app_a" "$rpa" get "$app_b:k1")" NOPERM
out="$(pg_as "$role_a" "$pwa" "$role_b" 'select 1')"
expect_has "A cannot connect to B's database after the full restore" "$out" "permission denied for database"

# Hardening survived.
out="$(pg_as "$role_a" "$pwa" postgres 'select 1')"
expect_has "A cannot connect to postgres after the full restore" "$out" "permission denied for database"
out="$(pg_as "$role_a" "$pwa" template1 'select 1')"
expect_has "A cannot connect to template1 after the full restore" "$out" "permission denied for database"
expect_eq "control: A connects to its own DB after the full restore" "$(pg_as "$role_a" "$pwa" "$role_a" 'select 1')" 1

# The loader only ever saw the throwaway container's image and volume: every `docker run` the restore made (the docker
# stub on PATH logs argv and forwards) carries the throwaway Redis volume and the image pinned in compose.yaml.
runs="$(grep -c '^run ' "$docker_log")"
expect_eq "full made exactly two docker run calls (file replace, loader)" "$runs" 2
expect_eq "every docker run mounted the throwaway Redis volume" "$(grep '^run ' "$docker_log" | grep -c -e "-v $rid-redis:/data")" 2
expect_eq "every docker run used the image pinned in compose.yaml" "$(grep '^run ' "$docker_log" | grep -cF -e " $rdimg ")" 2
expect_eq "no docker call of the whole run names a production platform-data object" "$(grep -c 'platform-data' "$docker_log")" 0
expect_has "control: the loader was started under the name derived from the throwaway Redis container" "$(< "$docker_log")" "run -d --name $RDC-restore-loader"
expect_eq "no loader container is left behind" "$(docker ps -aq --filter "name=^${RDC}-restore-loader" | wc -l)" 0
expect_eq "the throwaway Redis volume still has its prefixed name" "$(docker inspect --format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Name}}{{end}}{{end}}' "$RDC")" "$rid-redis"
expect_lacks "the full run never names the production Redis volume or container" "$full_out" "platform-data-redis"
expect_lacks "the full run never names the production Postgres container" "$full_out" "platform-data-postgres"

# ---- 7. Redis persistence: restart and the keys are still there (the AOF was rewritten from the RDB) ----

docker restart "$RDC" > /dev/null
wait_healthy "$RDC" && _pass || _fail "Redis healthy after the restart"
expect_eq "after a restart A's Redis string is still there" "$(redis_as "$app_a" "$rpa" get "$app_a:k1")" valueA
expect_eq "after a restart A's Redis list is still there" "$(redis_as "$app_a" "$rpa" llen "$app_a:q")" 3
expect_eq "after a restart B's Redis string is still there" "$(redis_as "$app_b" "$rpb" get "$app_b:k1")" valueB
expect_eq "after a restart the Redis ACL users are still there" "$(rdadmin acl users | sort | tr '\n' ' ')" "admin $app_a $app_b default health "
expect_eq "Redis runs with appendonly yes after the restore" "$(rdadmin config get appendonly | tr '\n' ' ')" "appendonly yes "

# ---- 8. host-files on a stack whose admin files already match ----

run_restore "$T_TMP/restore-hf.txt" host-files
rc=$?
expect_eq "host-files exits 0 when both files match" "$rc" 0
expect_has "host-files reports already for the pg file" "$(< "$T_TMP/restore-hf.txt")" "already: $pg_admin_file"

# ---- 9. a second backup after the restore still works and prunes nothing it should keep ----

run_backup "$T_TMP/backup2.txt"
rc=$?
expect_eq "a second backup.sh manual exits 0 after the restore" "$rc" 0
expect_eq "two snapshots exist" "$(rcmd snapshots --json | grep -o '"short_id"' | wc -l)" 2
: "${cap_snap:=}"

t_finish
