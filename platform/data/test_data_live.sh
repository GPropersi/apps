#!/usr/bin/env bash
# Pre-merge run of the REAL data stack (the pinned Postgres and Redis from compose.yaml) with the real new-db.sh, the real
# redis-entrypoint.sh, the real reserved-names list and the real install-data.sh verify checks.
#
# Needs docker; on a host without a usable docker daemon (CI has none) it skips with a loud notice and exits 0. Run it
# once un-skipped on a docker host before merge, with REQUIRE_DOCKER=1 so a missing docker or daemon is a failure instead
# of a skip (a skip is otherwise indistinguishable from a pass):
#   REQUIRE_DOCKER=1 bash platform/data/test_data_live.sh > /tmp/claude/data-live.txt 2>&1
#
# Like test_traefik_dynamic.sh it runs automatically whenever a usable daemon exists (no opt-in variable). Opt out with
# PDLIVE_SKIP=1 (ordinary developer `make test` runs): it skips with a notice, and is still a failure under REQUIRE_DOCKER=1.
# An image that is not cached and cannot be pulled (offline, rate-limited) is a skip as well, not a failure.
# PDLIVE_PG_BURSTS="6 12" shrinks the Postgres concurrent-session rounds (default "6 12 18 24").
# PDLIVE_CAPTURE=<file> appends command outputs (ACL hashes of throwaway passwords, container names) for the plan;
# that file must NEVER be committed to this public repo.
#
# What it proves against real servers (every negative assertion carries a positive control in the same run):
#   - one app cannot connect to another app's database, nor to postgres/template1; the public schema has no PUBLIC rights;
#   - an app role is capped at 3 connections; a failing CREATE ROLE ... PASSWORD leaves no password in `docker logs`;
#   - a Redis app user can SET its own prefix but not another's, and not KEYS/SCAN/RANDOMKEY/DBSIZE/FLUSHALL/CONFIG;
#   - the `default` Redis user is rejected; `admin` works for an admin file with and without a trailing newline;
#   - a fresh stack is healthy and Redis has only default (off), admin and health; install-data.sh verify reports
#     "already: no apps yet" before the first new-db, PASS after two apps, and FAIL for an injected rogue user and for an
#     enabled default user (each injection reverted);
#   - re-running new-db is a no-op; the Redis ACL and a queued key survive a restart; Postgres data survives down + up on
#     the named volume and no anonymous volume appears; a Redis fill to maxmemory and a Postgres sort burst stay inside the
#     containers' memory limits (informational numbers are printed);
#   - `platform ls` classifies a live labelled container's state and health.
#
# Isolation: every container, network, volume and compose project carries the unique prefix pdlive-<pid>. The compose
# file under test is generated from compose.yaml, changing only the admin-file and payload mount sources, the prefixed
# names and the project name (asserted by reversing the substitutions and comparing with compose.yaml). It never touches
# the real `platform` network, the real named volumes or the real platform-data-* containers. Everything is removed on
# every exit path.
#
# Hints:
#   leftover containers after a killed run  -> docker ps -a --filter name=pdlive-  (remove by prefix)
#   pg_hba "no entry" on 127.x              -> samenet did not match loopback; the app connects need another route
#   positive control failed                 -> the paired refusal proves nothing; fix the control first
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
  echo "## The real-docker data stack check did NOT run. Run it on a docker host before merge (REQUIRE_DOCKER=1)."
  echo "################################################################"
  exit 0
}

[ "${PDLIVE_SKIP:-0}" != 1 ] || skip "PDLIVE_SKIP=1"
command -v docker >/dev/null 2>&1 || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "the docker daemon is not reachable by this user"
docker compose version >/dev/null 2>&1 || skip "the docker compose plugin is not available"

t_init

# At most 7 + 7 + 1 + 5 = 20 chars, so rid-a / rid-b / rid-ls (23 max) fit the app-name pattern ^[a-z][a-z0-9-]{1,30}$
# and the underscore form of rid-a is a valid Postgres identifier.
rid="pdlive-$$-$RANDOM"
proj="$rid-proj"
net="$rid-net"
PGC="$rid-postgres"
RDC="$rid-redis"
LSC="$rid-ls"
gen="$T_TMP/compose.live.yaml"
payload="$T_TMP/payload"
secrets="$T_TMP/secrets"
pg_admin_file="$T_TMP/postgres-admin.password"
redis_admin_file="$T_TMP/redis-admin.password"
captures="${PDLIVE_CAPTURE:-}"

cap() { [ -z "$captures" ] || printf '### %s\n%s\n' "$1" "$2" >> "$captures"; }

dc() { docker compose -p "$proj" -f "$gen" "$@"; }

cleanup() {
  local ids
  [ ! -f "$gen" ] || docker compose -p "$proj" -f "$gen" down -v --remove-orphans >/dev/null 2>&1
  ids="$(docker ps -aq --filter "name=^${rid}-" 2>/dev/null)"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker rm -fv $ids >/dev/null 2>&1
  docker volume rm -f "$rid-postgres" "$rid-redis" >/dev/null 2>&1
  docker network rm "$net" >/dev/null 2>&1
  t_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---- helpers ----

# expect_has / expect_lacks <label> <text> <fixed-string>
expect_has() { if grep -qF -- "$3" <<<"$2"; then _pass; else _fail "$1" "lacks: $3 (got: ${2:0:600})"; fi; }
expect_lacks() { if grep -qF -- "$3" <<<"$2"; then _fail "$1" "unexpectedly has: $3"; else _pass; fi; }
expect_re() { if grep -qE -- "$3" <<<"$2"; then _pass; else _fail "$1" "does not match /$3/ (got: ${2:0:600})"; fi; }

expect_ne_empty() { if [ -n "$2" ]; then _pass; else _fail "$1" "empty"; fi; }

# oom_check <container> <label>: the cgroup's own oom_kill counter (the kernel usually kills one backend, not PID 1, so
# State.OOMKilled alone can stay false).
oom_check() {
  local ev
  ev="$(docker exec "$1" cat /sys/fs/cgroup/memory.events 2>/dev/null | grep '^oom_kill ')"
  if [ -z "$ev" ]; then echo "notice: $1 has no /sys/fs/cgroup/memory.events (cgroup v1?): oom_kill is not asserted for $2"
  else expect_eq "no cgroup oom_kill in $1 $2" "$ev" "oom_kill 0"; fi
}

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }

# wait_healthy <container> [seconds]
wait_healthy() {
  local c="$1" t="${2:-120}" i st
  for ((i = 0; i < t; i += 2)); do
    st="$(docker inspect --format '{{.State.Status}}|{{.State.Health.Status}}' "$c" 2>/dev/null)"
    [ "$st" = "running|healthy" ] && return 0
    sleep 2
  done
  echo "container $c not healthy after ${t}s (last: ${st:-none})"
  docker logs "$c" 2>&1 | tail -n 15
  return 1
}

# The admin redis-cli snippet is the one new-db.sh runs (read from the real script, never retyped).
snippet="$(sed -n "s/^readonly REDIS_ADMIN_SNIPPET='\(.*\)'\$/\1/p" "$here/new-db.sh")"
[ -n "$snippet" ] || { echo "FAIL: cannot read REDIS_ADMIN_SNIPPET from new-db.sh"; exit 1; }
rdadmin() { docker exec -i "$RDC" sh -c "$snippet" sh /etc/platform/redis-admin.password "$@" 2>&1 </dev/null; }

# redis_as <user> <password file> <redis-cli args...>: the password goes in through stdin and REDISCLI_AUTH, not argv.
redis_as() {
  local user="$1" pwf="$2"
  shift 2
  printf '%s\n' "$(<"$pwf")" | docker exec -i "$RDC" sh -c 'IFS= read -r REDISCLI_AUTH; export REDISCLI_AUTH; u="$1"; shift; exec redis-cli --user "$u" --no-auth-warning "$@"' sh "$user" "$@" 2>&1
}

pg_admin() { docker exec -i "$PGC" psql -X -U postgres -d "${2:-postgres}" -At -v ON_ERROR_STOP=1 -c "$1" 2>&1 </dev/null; }

# pg_as <role> <password file> <db> <sql>: over TCP with scram, the password through stdin and PGPASSWORD.
pg_as() {
  local role="$1" pwf="$2" db="$3" sql="$4"
  printf '%s\n' "$(<"$pwf")" | docker exec -i "$PGC" sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -X -h 127.0.0.1 -U "$1" -d "$2" -At -v ON_ERROR_STOP=1 -c "$3"' sh "$role" "$db" "$sql" 2>&1
}

newdb() {
  NEW_DB_PG_CONTAINER="$PGC" NEW_DB_REDIS_CONTAINER="$RDC" NEW_DB_RESERVED_NAMES="$here/../registry/reserved-names.txt" \
    NEW_DB_SECRETS_ROOT="$secrets" NEW_DB_LOCK_WAIT=10 NEW_DB_EXEC_TIMEOUT=60 bash "$here/new-db.sh" "$1" 2>&1
}

verify() {
  env INSTALL_DATA_SUDO= INSTALL_DATA_PG_CONTAINER="$PGC" INSTALL_DATA_REDIS_CONTAINER="$RDC" INSTALL_DATA_NETWORK="$net" \
    INSTALL_DATA_DIR="$payload" INSTALL_DATA_VAR_DIR="$T_TMP/var" INSTALL_DATA_SECRETS_ROOT="$secrets" \
    INSTALL_DATA_PG_ADMIN_FILE="$pg_admin_file" INSTALL_DATA_REDIS_ADMIN_FILE="$redis_admin_file" \
    bash "$here/../host/install-data.sh" verify 2>&1
}

# ---- read the stack definition ----

flat="$T_TMP/compose-flat"
if ! ys_flatten < "$here/compose.yaml" > "$flat"; then
  echo "FAIL: compose.yaml is outside the YAML subset the tests understand"
  exit 1
fi
pgimg="$(ys_get "$flat" services/postgres/image)"
rdimg="$(ys_get "$flat" services/redis/image)"
pg_mem="$(ys_get "$flat" services/postgres/mem_limit)"
rd_mem="$(ys_get "$flat" services/redis/mem_limit)"

for img in "$pgimg" "$rdimg"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    timeout 300 docker pull -q "$img" >/dev/null 2>"$T_TMP/pull-err" || { cat "$T_TMP/pull-err"; skip "cannot pull $img (offline or rate-limited)"; }
  fi
done

# ---- generate the compose file under test and prove how it differs ----

mkdir -p "$payload" "$secrets" "$T_TMP/var"
chmod 2710 "$secrets"
cp "$here/pg_hba.conf" "$payload/pg_hba.conf"
cp "$here/redis-entrypoint.sh" "$payload/redis-entrypoint.sh"
chmod 0644 "$payload/pg_hba.conf"
chmod 0755 "$payload/redis-entrypoint.sh"
# Throwaway admin passwords (mode 0644: an unprivileged runner cannot create root:64322 0640 files; Step 8 checks that).
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
  "$here/compose.yaml" | awk -v n="$net" '{ print } /^    external: true$/ { print "    name: " n }' > "$gen"

back="$T_TMP/compose.reversed"
awk -v n="    name: $net" '$0 != n { print }' "$gen" \
  | sed -e "s#^name: $proj\$#name: platform-data#" \
    -e "s#^\\(      - \\)$pg_admin_file:#\\1/etc/platform/postgres-admin.password:#" \
    -e "s#^\\(      - \\)$redis_admin_file:#\\1/etc/platform/redis-admin.password:#" \
    -e "s#^\\(      - \\)$payload/pg_hba.conf:#\\1/opt/platform/data/pg_hba.conf:#" \
    -e "s#^\\(      - \\)$payload/redis-entrypoint.sh:#\\1/opt/platform/data/redis-entrypoint.sh:#" \
    -e "s#$rid-#platform-data-#g" > "$back"
if cmp -s "$back" "$here/compose.yaml"; then _pass; else _fail "the generated compose differs from compose.yaml beyond mount sources, names and project" "$(diff "$here/compose.yaml" "$back" | head -n 12)"; fi
if cmp -s "$gen" "$here/compose.yaml"; then _fail "the generated compose is identical to compose.yaml (no isolation applied)"; else _pass; fi
for p in "$pg_admin_file" "$redis_admin_file" "$payload/pg_hba.conf" "$payload/redis-entrypoint.sh"; do
  expect_eq "generated compose mounts the throwaway ${p##*/} exactly once" "$(grep -cF -- "      - $p:" "$gen")" 1
done
expect_eq "no real host mount source remains in the generated compose" "$(grep -cE '^      - /(etc/platform|opt/platform)/' "$gen")" 0
expect_eq "hardening kept: read_only on both services" "$(grep -c '^    read_only: true$' "$gen")" 2
expect_eq "hardening kept: every file mount stays read-only" "$(grep -c ':ro$' "$gen")" 4
# No mount source, container name, volume or network of the real stack remains in the generated file.
if grep -nE '(^|[^a-z-])platform-data-(postgres|redis)' "$gen" | grep -v '^[0-9]*:#' >/dev/null; then _fail "the generated compose still names a real platform-data object"; else _pass; fi

docker network create --label "pdlive=$rid" "$net" >/dev/null || { echo "FAIL: network create"; exit 1; }

# ---- 1. fresh stack ----

if ! dc up -d >"$T_TMP/up.txt" 2>&1; then
  echo "FAIL: compose up"
  cat "$T_TMP/up.txt"
  exit 1
fi
if wait_healthy "$PGC" && wait_healthy "$RDC"; then _pass; else _fail "a fresh stack becomes healthy"; exit 1; fi
cap "docker inspect state|health (Postgres, Redis)" "$(docker inspect --format '{{.State.Status}}|{{.State.Health.Status}}' "$PGC" "$RDC")"
cap "docker ps --format Status (health suffixes)" "$(docker ps -a --filter "name=^${rid}-" --format '{{.Names}} {{.State}} | {{.Status}}')"

# Redis: only default (off), admin and health on a fresh stack; the admin login works (one-trailing-newline variant).
out="$(rdadmin ping)"
expect_eq "admin login works (admin file with one trailing newline)" "$out" PONG
users="$(rdadmin acl users | sort | tr '\n' ' ')"
expect_eq "fresh Redis has only admin, default and health" "$users" "admin default health "
acl="$(rdadmin acl list)"
cap "ACL LIST (fresh)" "$acl"
expect_re "fresh Redis: default is off" "$(grep '^user default ' <<<"$acl")" '^user default off'
# default rejected, paired with the admin PONG above (same run).
out="$(docker exec "$RDC" redis-cli --no-auth-warning ping 2>&1)"
expect_re "default user (no auth) is rejected" "$out" 'NOAUTH|WRONGPASS'
out="$(docker exec "$RDC" redis-cli --user default --pass wrong --no-auth-warning ping 2>&1)"
expect_re "default user with a password is rejected" "$out" 'WRONGPASS|NOAUTH'
# Postgres admin password file (with a trailing newline) really is the postgres password over TCP; peer works locally.
out="$(printf '%s\n' "$pg_pw" | docker exec -i "$PGC" sh -c 'IFS= read -r PGPASSWORD; export PGPASSWORD; exec psql -X -h 127.0.0.1 -U postgres -d postgres -At -c "select 1"' 2>&1)"
expect_eq "Postgres admin password (file with a trailing newline) works over scram" "$out" 1
expect_eq "Postgres admin works over the local socket (peer)" "$(pg_admin 'select 2')" 2
cap "SHOW hba_file; log settings" "$(pg_admin 'SHOW hba_file'; pg_admin 'SHOW log_statement'; pg_admin 'SHOW log_min_error_statement')"
cap "pg_hba_file_rules" "$(pg_admin 'SELECT rule_number, line_number, type, database, user_name, address, auth_method, error FROM pg_hba_file_rules')"

# verify before any app exists
vout="$(verify)"
cap "install-data verify (no apps)" "$vout"
expect_has "verify before new-db: no apps yet" "$vout" "already: no apps yet"
expect_has "verify: containers running and healthy" "$vout" "PASS: both containers are running and healthy"
expect_has "verify: Redis ACL users pass on a fresh stack" "$vout" "PASS: Redis ACL users"
expect_has "verify: hba_file is the installed file" "$vout" "PASS: Postgres hba_file is /etc/postgresql/pg_hba.conf"
expect_has "verify: every pg_hba rule parses" "$vout" "PASS: every pg_hba rule parses and uses peer or scram-sha-256"
expect_has "verify: log_statement" "$vout" "PASS: Postgres log_statement is none"
expect_has "verify: log_min_error_statement" "$vout" "PASS: Postgres log_min_error_statement is panic"
expect_has "verify: Redis eviction policy" "$vout" "PASS: Redis eviction policy is noeviction"
expect_has "verify: Redis AOF" "$vout" "PASS: Redis AOF is on"
expect_re "verify: Redis memory" "$vout" '^(PASS|WARN): Redis memory is at'
expect_has "verify: Postgres container only on the test network" "$vout" "PASS: $PGC is only on the $net network"
expect_has "verify: Redis container only on the test network" "$vout" "PASS: $RDC is only on the $net network"
expect_has "verify: no admin password in Postgres Env/Cmd/Healthcheck" "$vout" "PASS: the Postgres admin password is not in the Env, Cmd or Healthcheck of $PGC"
expect_has "verify: no admin password in Redis Env/Cmd/Healthcheck" "$vout" "PASS: the Redis admin password is not in the Env, Cmd or Healthcheck of $RDC"

# ---- 2. two apps ----

app_a="$rid-a"
app_b="$rid-b"
role_a="${app_a//-/_}"
role_b="${app_b//-/_}"
out="$(newdb "$app_a")"
rc=$?
expect_eq "new-db app A exits 0" "$rc" 0
expect_has "new-db app A reports its role" "$out" "changed: postgres role and database $role_a"
expect_has "new-db app A reports its Redis user" "$out" "changed: redis user $app_a"
[ "$rc" -eq 0 ] || echo "$out"
out="$(newdb "$app_b")"
rc=$?
expect_eq "new-db app B exits 0" "$rc" 0
[ "$rc" -eq 0 ] || echo "$out"
pwa="$secrets/$app_a/db-password"
pwb="$secrets/$app_b/db-password"
rpa="$secrets/$app_a/redis-password"
rpb="$secrets/$app_b/redis-password"
for f in "$pwa" "$pwb" "$rpa" "$rpb"; do
  expect_eq "secret file exists with mode 440: ${f##*/}" "$(stat -c '%a' "$f" 2>/dev/null)" 440
done

# Re-run is a no-op: every line says already, and no password changes.
before_sum="$(cat "$pwa" "$pwb" "$rpa" "$rpb" | sha256sum)"
out="$(newdb "$app_a")"
rc=$?
expect_eq "re-run new-db exits 0" "$rc" 0
expect_lacks "re-run new-db changes nothing" "$out" "changed:"
expect_has "re-run new-db says already (postgres)" "$out" "already: postgres role and database $role_a"
expect_has "re-run new-db says already (redis)" "$out" "already: redis user $app_a"
expect_eq "re-run keeps every password" "$(cat "$pwa" "$pwb" "$rpa" "$rpb" | sha256sum)" "$before_sum"

# ---- 3. Postgres isolation ----

out="$(pg_as "$role_a" "$pwa" "$role_a" 'select current_database()')"
expect_eq "A connects to its own database (control)" "$out" "$role_a"
out="$(pg_as "$role_b" "$pwb" "$role_b" 'select current_database()')"
expect_eq "B connects to its own database (control)" "$out" "$role_b"
out="$(pg_as "$role_a" "$pwa" "$role_b" 'select 1')"
expect_has "A cannot connect to B's database" "$out" "permission denied for database"
out="$(pg_as "$role_b" "$pwb" "$role_a" 'select 1')"
expect_has "B cannot connect to A's database" "$out" "permission denied for database"
out="$(pg_as "$role_a" "$pwa" postgres 'select 1')"
expect_has "A cannot connect to postgres" "$out" "permission denied for database"
out="$(pg_as "$role_a" "$pwa" template1 'select 1')"
expect_has "A cannot connect to template1" "$out" "permission denied for database"
cap "psql refusal text (cross database)" "$out"
# The admin still reaches both (control that the databases exist and the refusal is a privilege matter).
expect_eq "admin sees both app databases" "$(pg_admin "select count(*) from pg_database where datname in ('$role_a','$role_b')")" 2
# public schema: PUBLIC rights revoked in app databases, still present in the unrevoked postgres database (control).
n_a="$(pg_admin "select count(*) from aclexplode((select nspacl from pg_namespace where nspname='public')) where grantee = 0" "$role_a")"
t_a="$(pg_admin "select count(*) from aclexplode((select nspacl from pg_namespace where nspname='public'))" "$role_a")"
n_pg="$(pg_admin "select count(*) from aclexplode((select nspacl from pg_namespace where nspname='public')) where grantee = 0" postgres)"
expect_eq "control: postgres.public still has a PUBLIC grant" "$n_pg" 1
expect_eq "app database public schema has no PUBLIC privileges" "$n_a" 0
[ "$t_a" -ge 1 ] 2>/dev/null && _pass || _fail "control: the app database's public schema still has its owner grant (got '$t_a')"
expect_eq "app role is not superuser, limit 3" "$(pg_admin "select rolsuper::text || rolconnlimit::text || rolcreatedb::text || rolcreaterole::text from pg_roles where rolname='$role_a'")" "false3falsefalse"
# A cannot see B's objects (and can use its own): create in A, B has no route to it (cannot connect).
out="$(pg_as "$role_a" "$pwa" "$role_a" 'create table t(x int); insert into t values (7); select x from t')"
expect_has "A creates and reads its own table" "$out" "7"

# Connection cap: three connections succeed (counted by the admin), the fourth fails with the limit error.
pids=()
for _ in 1 2 3; do
  pg_as "$role_a" "$pwa" "$role_a" 'select pg_sleep(60)' >/dev/null 2>&1 &
  pids+=($!)
done
cnt=0
for _ in $(seq 1 20); do
  cnt="$(pg_admin "select count(*) from pg_stat_activity where usename='$role_a' and query like '%pg_sleep%' and pid <> pg_backend_pid()")"
  [ "$cnt" = 3 ] && break
  sleep 1
done
expect_eq "control: three connections of A are open" "$cnt" 3
out="$(pg_as "$role_a" "$pwa" "$role_a" 'select 1')"
expect_re "the fourth connection of A fails" "$out" 'too many connections for role'
pg_admin "select pg_terminate_backend(pid) from pg_stat_activity where usename='$role_a'" >/dev/null
kill "${pids[@]}" 2>/dev/null
wait "${pids[@]}" 2>/dev/null
for _ in $(seq 1 10); do
  cnt="$(pg_admin "select count(*) from pg_stat_activity where usename='$role_a' and pid <> pg_backend_pid()")"
  [ "$cnt" = 0 ] && break
  sleep 1
done
out="$(pg_as "$role_a" "$pwa" "$role_a" 'select 1')"
expect_eq "A connects again once the others are gone (control)" "$out" 1

# Log leak: a failing CREATE ROLE ... PASSWORD must not put the password into docker logs; the ERROR text must be there.
planted="Planted$(rand 20)"
pg_admin 'create role pdlive_leak login' >/dev/null
out="$(pg_admin "create role pdlive_leak login password '$planted'")"
expect_has "the failing statement ran and failed" "$out" 'already exists'
for _ in $(seq 1 10); do
  docker logs "$PGC" > "$T_TMP/pg.log" 2>&1
  grep -qF 'role "pdlive_leak" already exists' "$T_TMP/pg.log" && break
  sleep 1
done
expect_has "control: the ERROR text is in docker logs" "$(<"$T_TMP/pg.log")" 'role "pdlive_leak" already exists'
expect_lacks "the planted password is not in docker logs" "$(<"$T_TMP/pg.log")" "$planted"
expect_lacks "no app db password is in docker logs" "$(<"$T_TMP/pg.log")" "$(<"$pwa")"
expect_lacks "the statement text is not logged" "$(<"$T_TMP/pg.log")" "STATEMENT"
pg_admin 'drop role pdlive_leak' >/dev/null

# ---- 4. Redis isolation ----

out="$(redis_as "$app_a" "$rpa" set "$app_a:x" 1)"
expect_eq "Redis A can SET its own key" "$out" OK
out="$(redis_as "$app_a" "$rpa" get "$app_a:x")"
expect_eq "Redis A can GET its own key (control)" "$out" 1
rdadmin set "$app_b:x" seeded >/dev/null
expect_eq "control: admin sees B's seeded key" "$(rdadmin get "$app_b:x")" seeded
expect_re "control: admin SCAN sees B's key" "$(rdadmin scan 0 match "$app_b:*")" "$app_b:x"
expect_ne_empty "control: admin RANDOMKEY returns a key" "$(rdadmin randomkey)"
dbs="$(rdadmin dbsize)"
[ "$dbs" -ge 2 ] 2>/dev/null && _pass || _fail "control: admin DBSIZE counts the seeded keys (got '$dbs')"
out="$(redis_as "$app_a" "$rpa" set "$app_b:x" 1)"
expect_has "Redis A cannot SET B's key" "$out" NOPERM
cap "Redis NOPERM text (key)" "$out"
out="$(redis_as "$app_a" "$rpa" get "$app_b:x")"
expect_has "Redis A cannot GET B's key" "$out" NOPERM
for c in "keys *" "flushall" "flushdb" "config get maxmemory" "scan 0" "randomkey" "dbsize" "acl list" "info" "eval return 1 0" "publish ch msg"; do
  # Split by hand with globbing off: "keys *" must reach Redis as two words, not as a file list.
  set -f
  read -r -a cmdv <<<"$c"
  set +f
  out="$(redis_as "$app_a" "$rpa" "${cmdv[@]}")"
  expect_has "Redis A is refused: $c" "$out" NOPERM
  [ "$c" != "keys *" ] || cap "Redis NOPERM text (command)" "$out"
done
out="$(redis_as "$app_a" "$rpa" ping)"
expect_eq "Redis A can PING (control for the refusals)" "$out" PONG
expect_eq "B's key survived A's refused FLUSHALL" "$(rdadmin get "$app_b:x")" seeded
out="$(printf '%s\n' wrong | docker exec -i "$RDC" sh -c 'IFS= read -r REDISCLI_AUTH; export REDISCLI_AUTH; exec redis-cli --user "$0" --no-auth-warning ping' "$app_a" 2>&1)"
expect_re "Redis A with a wrong password is rejected" "$out" 'WRONGPASS'

# verify after two apps
vout="$(verify)"
cap "install-data verify (two apps)" "$vout"
expect_has "verify after two apps: Redis ACL users accepted" "$vout" "PASS: Redis ACL users"
expect_has "verify after two apps: PUBLIC CONNECT revoked" "$vout" "PASS: PUBLIC has no CONNECT on postgres and template1"
expect_lacks "verify after two apps: no 'no apps yet' line" "$vout" "no apps yet"
cap "ACL LIST (two apps)" "$(rdadmin acl list)"
cap "CONFIG GET maxmemory-policy / appendonly" "$(rdadmin config get maxmemory-policy; rdadmin config get appendonly)"
cap "INFO memory (head)" "$(rdadmin info memory | head -n 6)"

# Rogue Redis user (key scope ~*), then reverted by ACL LOAD from the saved file.
rdadmin acl setuser pdrogue on nopass '~*' +@all >/dev/null
vout="$(verify)"
expect_has "verify fails for a rogue Redis user" "$vout" "FAIL: Redis ACL users: Redis user pdrogue lacks the key scope"
expect_eq "ACL LOAD reverts the rogue user" "$(rdadmin acl load)" OK
vout="$(verify)"
expect_has "verify passes again after the rogue user is reverted" "$vout" "PASS: Redis ACL users"
# default enabled, then reverted.
rdadmin acl setuser default on nopass '~*' +@all >/dev/null
vout="$(verify)"
expect_has "verify fails for an enabled default user" "$vout" "FAIL: Redis ACL users: the Redis default user is enabled"
expect_eq "ACL LOAD reverts the enabled default user" "$(rdadmin acl load)" OK
vout="$(verify)"
expect_has "verify passes again after default is reverted" "$vout" "PASS: Redis ACL users"
out="$(docker exec "$RDC" redis-cli --no-auth-warning ping 2>&1)"
expect_re "default is rejected again after ACL LOAD" "$out" 'NOAUTH|WRONGPASS'

# ---- 5. restart survival ----

out="$(redis_as "$app_a" "$rpa" lpush "$app_a:queue" job1)"
expect_eq "Redis A queues a job" "$out" 1
docker restart "$RDC" >/dev/null
wait_healthy "$RDC" && _pass || _fail "Redis healthy after restart"
out="$(redis_as "$app_a" "$rpa" lrange "$app_a:queue" 0 -1)"
expect_eq "the queued key survives a Redis restart" "$out" job1
out="$(redis_as "$app_a" "$rpa" set "$app_a:y" 2)"
expect_eq "the ACL (A's login) survives a Redis restart" "$out" OK
out="$(redis_as "$app_a" "$rpa" keys '*')"
expect_has "A is still refused KEYS after the restart" "$out" NOPERM

# ---- 6. memory budgets (informational numbers; the assertions are: no OOM kill, no restart, under the limit) ----

# Redis: fill past maxmemory with 1 KB values as admin (the fill keys are removed afterwards).
awk 'BEGIN { v = ""; for (j = 0; j < 100; j++) v = v "xxxxxxxxxx"; for (i = 0; i < 150000; i++) printf "SET fill:%d %s\r\n", i, v }' \
  | docker exec -i "$RDC" sh -c "$snippet" sh /etc/platform/redis-admin.password --pipe > "$T_TMP/fill.txt" 2>&1
cap "redis-cli --pipe fill result" "$(tail -n 3 "$T_TMP/fill.txt")"
out="$(rdadmin set fill:probe x)"
expect_re "Redis rejects writes at maxmemory (noeviction)" "$out" '^OOM'
rinfo="$(rdadmin info memory | tr -d '\r')"
used="$(sed -n 's/^used_memory:\([0-9]*\)$/\1/p' <<<"$rinfo")"
maxm="$(sed -n 's/^maxmemory:\([0-9]*\)$/\1/p' <<<"$rinfo")"
echo "memory: redis used_memory=$used maxmemory=$maxm"
[ -n "$used" ] && [ "$used" -le $((maxm + maxm / 10)) ] && _pass || _fail "Redis used_memory stays near maxmemory (used '$used', max '$maxm')"
rpeak="$(docker exec "$RDC" cat /sys/fs/cgroup/memory.peak 2>/dev/null || true)"
rdlimit="$(docker exec "$RDC" cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"
echo "memory: redis cgroup peak=${rpeak:-n/a} limit=${rdlimit:-n/a} ($rd_mem in compose.yaml)"
docker stats --no-stream --format 'memory: stats {{.Name}} {{.MemUsage}}' "$RDC"
expect_eq "Redis was not OOM-killed" "$(docker inspect --format '{{.State.OOMKilled}} {{.RestartCount}}' "$RDC")" "false 0"
if [ -n "$rpeak" ] && [ -n "$rdlimit" ] && [ "$rdlimit" != max ]; then
  [ "$rpeak" -lt "$rdlimit" ] && _pass || _fail "Redis cgroup peak $rpeak reached the limit $rdlimit"
fi
# Drop the fill (this also drops the seeded and queued keys; the saved ACL users are untouched).
oom_check "$RDC" "after the fill"
expect_eq "admin FLUSHALL drops the fill" "$(rdadmin flushall)" OK
expect_eq "admin ACL SAVE keeps the users" "$(rdadmin acl save)" OK

# Postgres: a burst of concurrent sort + hash-aggregate sessions as admin, then compare the cgroup peak with the limit.
burst='select count(*) from (select m, count(*) from (select md5(g::text) m from generate_series(1,600000) g) t group by m order by m) s'
plimit="$(docker exec "$PGC" cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"
echo "memory: postgres idle $(docker exec "$PGC" grep -E '^(anon|shmem|file) ' /sys/fs/cgroup/memory.stat | tr '\n' ' ')limit=${plimit:-n/a} ($pg_mem in compose.yaml)"
PG_BURSTS="${PDLIVE_PG_BURSTS:-6 12 18 24}"
for n in $PG_BURSTS; do
  pids=()
  for _ in $(seq 1 "$n"); do
    timeout 120 docker exec "$PGC" psql -X -U postgres -d postgres -At -c "$burst" >/dev/null 2>&1 &
    pids+=($!)
  done
  # Bounded wait (8s, non-failing) until about half of the sessions are active, then sample.
  for _ in $(seq 1 16); do
    act="$(pg_admin "select count(*) from pg_stat_activity where state='active' and query like 'select count(*) from (select m, count%' and pid <> pg_backend_pid()")"
    [ "$act" -ge $((n / 2)) ] 2>/dev/null && break
    sleep 0.5
  done
  echo "memory: postgres with $n concurrent heavy sessions: current=$(docker exec "$PGC" cat /sys/fs/cgroup/memory.current 2>/dev/null) $(docker exec "$PGC" grep -E '^(anon|shmem|file) ' /sys/fs/cgroup/memory.stat 2>/dev/null | tr '\n' ' ')"
  failed=0
  for p in "${pids[@]}"; do
    wait "$p" 2>/dev/null || failed=$((failed + 1))
  done
  expect_eq "every one of the $n heavy sessions finished cleanly" "$failed" 0
  oom_check "$PGC" "with $n concurrent heavy sessions"
  oomk="$(docker inspect --format '{{.State.OOMKilled}} {{.RestartCount}}' "$PGC")"
  expect_eq "Postgres was not OOM-killed with $n concurrent heavy sessions" "$oomk" "false 0"
  [ "$oomk" = "false 0" ] || { wait_healthy "$PGC" 120 || true; break; }
done
ppeak="$(docker exec "$PGC" cat /sys/fs/cgroup/memory.peak 2>/dev/null || true)"
echo "memory: postgres cgroup peak=${ppeak:-n/a} limit=${plimit:-n/a} (work_mem x max_connections is the budget under test)"
expect_eq "Postgres still answers after the bursts" "$(pg_admin 'select 3')" 3

# ---- 7. down + up: data survives on the named volume, no anonymous volume ----

# The fill was flushed above; queue the job again so the key crossing down + up is the one asserted below.
out="$(redis_as "$app_a" "$rpa" lpush "$app_a:queue" job1)"
expect_eq "Redis A queues a job again after the flush" "$out" 1

dc down >/dev/null 2>&1
expect_eq "down removed both containers" "$(docker ps -aq --filter "name=^${rid}-" | wc -l)" 0
dc up -d >"$T_TMP/up2.txt" 2>&1 || { echo "FAIL: compose up (second)"; cat "$T_TMP/up2.txt"; }
if wait_healthy "$PGC" && wait_healthy "$RDC"; then _pass; else _fail "the stack is healthy again after down + up"; fi
out="$(pg_as "$role_a" "$pwa" "$role_a" 'select x from t')"
expect_eq "Postgres data survives down + up" "$out" 7
out="$(redis_as "$app_a" "$rpa" lrange "$app_a:queue" 0 -1)"
expect_eq "Redis queued key survives down + up" "$out" job1
# The container Mounts check below is the authoritative anonymous-volume check (the engine does not label anonymous
# volumes with the compose project, so the label listing can only ever show the named ones).
vols="$(docker volume ls -q --filter "label=com.docker.compose.project=$proj" | sort | tr '\n' ' ')"
expect_eq "only the two prefixed named volumes belong to the test project" "$vols" "$rid-postgres $rid-redis "
mounts="$(docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Name}}{{"\n"}}{{end}}{{end}}' "$PGC" "$RDC" | grep -v '^$' | sort | tr '\n' ' ')"
expect_eq "the containers mount only the named volumes (no anonymous volume)" "$mounts" "$rid-postgres $rid-redis "
vdests="$(docker inspect --format '{{range .Mounts}}{{if eq .Type "volume"}}{{.Destination}}{{"\n"}}{{end}}{{end}}' "$PGC" "$RDC" | grep -v '^$' | sort | tr '\n' ' ')"
expect_eq "volume mounts sit only at /var/lib/postgresql and /data" "$vdests" "/data /var/lib/postgresql "
cap "docker inspect Mounts (Type Name Destination)" "$(docker inspect --format '{{range .Mounts}}{{.Type}} {{.Name}} {{.Destination}} rw={{.RW}}{{"\n"}}{{end}}' "$PGC" "$RDC")"

# ---- 8. the second admin-file variant: no trailing newline, Redis recreated on a fresh volume ----

dc rm -sf redis >/dev/null 2>&1
docker volume rm "$rid-redis" >/dev/null 2>&1
printf '%s' "$redis_pw" > "$redis_admin_file"
dc up -d redis >"$T_TMP/up3.txt" 2>&1 || { echo "FAIL: compose up redis (variant)"; cat "$T_TMP/up3.txt"; }
if wait_healthy "$RDC"; then _pass; else _fail "Redis healthy on the fresh volume (admin file without a trailing newline)"; fi
expect_eq "admin login works (admin file without a trailing newline)" "$(rdadmin ping)" PONG
expect_eq "fresh volume: only admin, default and health" "$(rdadmin acl users | sort | tr '\n' ' ')" "admin default health "
out="$(docker exec "$RDC" redis-cli --no-auth-warning ping 2>&1)"
expect_re "default is rejected on the fresh volume" "$out" 'NOAUTH|WRONGPASS'

# ---- 9. platform ls on live containers ----

# A labelled helper with a healthcheck, started from the Redis image. platform.sh ls reads `docker ps` for every
# container with the platform.app label on this daemon; only this test's row is asserted.
ls_app="$rid-ls"
docker run -d --name "$LSC" --label "platform.app=$ls_app" --label "pdlive=$rid" --health-cmd 'true' --health-interval 1s \
  --entrypoint sleep "$rdimg" 300 >/dev/null 2>&1 || _fail "cannot start the labelled helper container"
for _ in $(seq 1 20); do
  [ "$(docker inspect --format '{{.State.Health.Status}}' "$LSC" 2>/dev/null)" = healthy ] && break
  sleep 1
done
cap "docker ps --format (platform.app state status)" "$(docker ps -a --filter "label=platform.app=$ls_app" --format '{{.Label "platform.app"}}	{{.State}}	{{.Status}}')"
lsout="$(bash "$here/../host/platform.sh" ls 2>&1)"
expect_has "platform ls: running + healthy for a live healthy container" "$lsout" "$(printf '%s\t%s\t%s' "$ls_app" running healthy)"
docker stop -t 1 "$LSC" >/dev/null 2>&1
lsout="$(bash "$here/../host/platform.sh" ls 2>&1)"
expect_has "platform ls: exited for a stopped container" "$lsout" "$(printf '%s\t%s\t' "$ls_app" exited)"
docker rm -fv "$LSC" >/dev/null 2>&1

t_finish
