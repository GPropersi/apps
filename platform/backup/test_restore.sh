#!/usr/bin/env bash
# Offline tests for restore.sh (list, app, secrets, host-files, full).
# Every case runs restore.sh as a real child process with an EMPTY caller environment (env -i, as under `sudo -n`) plus
# the shared PLATFORM_BACKUP_* overrides pointing into a per-case temp dir. restic, docker, getent, chown, stat and sleep
# are stateful stubs on PATH (failure injection through $CASE_DIR/fail_<key> files holding the exit code). The restic
# stub serves `restore` from a fixture tree $CASE_DIR/snap that mirrors absolute paths. No real credentials: every
# secret below is a fake marker string. Each negative assertion is paired with a positive control (the passing scenario
# of the same family shows the expected call).
# SC2016: stub and case bodies are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# SC2154: $out and $rc are set by run_cmd in lib.sh. SC2034: some fixture variables are only read by sub-functions.
# shellcheck disable=SC1091,SC2016,SC2034,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
SCRIPT="$here/restore.sh"
BACKUP_SCRIPT="$here/backup.sh"
NEWDB_SCRIPT="$here/../data/new-db.sh"
INSTALL_DATA_SCRIPT="$here/../host/install-data.sh"

t_init

if command -v flock > /dev/null 2>&1; then _pass; else _fail "flock is available for the lock tests"; fi

PW_SECRET='Pw+/=Zq9xSecretMarker'
AWS_SECRET='sk+/=testsecretmarker0002'
HOOK_SECRET='https://discord.example.test/api/webhooks/111/tokenmarker'
SID="$(printf 'ab%.0s' {1..32})"
SID2="$(printf 'cd%.0s' {1..32})"
LOADER=platform-data-redis-restore-loader

# ---- stubs ----

# restic: logs argv, records the credentials it saw. snapshots --json prints one snapshot (the explicit 64-hex id when
# one is given), `snapshots` alone prints a table, restore copies each --include path from $CASE_DIR/snap into --target.
cat > "$STUB_BIN/restic" <<'EOF'
#!/usr/bin/env bash
printf 'restic' >> "$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
printf 'REPO=[%s] PW=[%s] AK=[%s] SK=[%s] REG=[%s] HOOK=[%s]\n' "${RESTIC_REPOSITORY-}" "${RESTIC_PASSWORD-}" "${AWS_ACCESS_KEY_ID-}" "${AWS_SECRET_ACCESS_KEY-}" "${AWS_DEFAULT_REGION-}" "${DISCORD_WEBHOOK-}" > "$CASE_DIR/restic-env"
key="$1"
if [ -f "$CASE_DIR/fail_$key" ]; then
  echo "Fatal: injected failure $key repo $RESTIC_REPOSITORY pw $RESTIC_PASSWORD" >&2
  exit "$(cat "$CASE_DIR/fail_$key")"
fi
case "$1" in
  snapshots)
    json=0
    id=""
    for a in "$@"; do
      if [ "$a" = --json ]; then json=1; fi
      if [[ "$a" =~ ^[0-9a-f]{64}$ ]]; then id="$a"; fi
    done
    if [ "$json" -eq 0 ]; then echo "ID Time Host Tags Paths"; echo "abcdef01 2026-10-22 platform platform /x"; exit 0; fi
    if [ -f "$CASE_DIR/nosnap" ]; then echo '[]'; exit 0; fi
    [ -n "$id" ] || id="$(printf 'ab%.0s' {1..32})"
    printf '[{"time":"2026-10-22T03:35:00Z","tree":"t","paths":["/x"],"hostname":"platform","id":"%s","short_id":"%s"}]\n' "$id" "${id:0:8}"
    ;;
  restore)
    target=""
    inc=()
    prev=""
    exc=0
    for a in "$@"; do
      if [ "$prev" = --target ]; then target="$a"; fi
      if [ "$prev" = --include ]; then inc+=("$a"); fi
      if [ "$a" = --exclude ]; then exc=1; fi
      prev="$a"
    done
    if [ "$exc" -eq 1 ] && [ "${#inc[@]}" -gt 0 ]; then
      echo "Fatal: exclude and include patterns are mutually exclusive" >&2
      exit 1
    fi
    for p in "${inc[@]}"; do
      if [ -e "$CASE_DIR/snap$p" ]; then
        mkdir -p "$target$(dirname "$p")"
        cp -a "$CASE_DIR/snap$p" "$target$p"
      fi
    done
    ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN/restic"

# docker: logs argv. Postgres SQL on stdin is logged as `SQL[<db>]: <text>` (the globals load as PSQL-GLOBALS); pg_restore
# logs its stdin's first line. Redis: the admin snippet (ACL USERS, INFO keyspace) and the one-shot loader (INFO
# persistence reads $CASE_DIR/loader_seq, one "<loading> <aof_in_progress> <status> [<aof_scheduled>]" line per call, the
# last repeating; `inspect` answers image/mount only from $CASE_DIR/image_<name> and mount_<name>, rc 1 for an unknown name).
# Failure keys: globals, revoke, create, pgrestore_<db>, compose_stop, compose_start, run_replace, run_loader, stop, rm.
cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker' >> "$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
inject() {
  if [ -f "$CASE_DIR/fail_$1" ]; then
    echo "docker: injected failure $1" >&2
    exit "$(cat "$CASE_DIR/fail_$1")"
  fi
}
all=" $* "
case "$1" in
  inspect)
    case "$all" in
      *Config.Image*) [ -f "$CASE_DIR/image_${*: -1}" ] || { echo "Error: No such container: ${*: -1}" >&2; exit 1; }; cat "$CASE_DIR/image_${*: -1}" ;;
      *Mounts*) [ -f "$CASE_DIR/mount_${*: -1}" ] || { echo "Error: No such container: ${*: -1}" >&2; exit 1; }; cat "$CASE_DIR/mount_${*: -1}" ;;
      *State.Running*)
        # After `compose stop` the real Redis is down unless a case plants running_<name> (the stop selected no container).
        if [ -f "$CASE_DIR/running_${*: -1}" ]; then echo true; else echo false; fi
        ;;
      *State.Status*)
        name="${*: -1}"
        if [ -f "$CASE_DIR/health_$name" ]; then cat "$CASE_DIR/health_$name"; else echo "running|healthy"; fi
        ;;
    esac
    exit 0
    ;;
  compose)
    inject "compose_${*: -2:1}"
    exit 0
    ;;
  run)
    case "$all" in *" -d "*) inject run_loader; echo "loader-container-id" ;; *) inject run_replace ;; esac
    exit 0
    ;;
  stop) inject stop; exit 0 ;;
  rm) inject rm; exit 0 ;;
  exec) ;;
  *) exit 0 ;;
esac
case "$all" in
  *" $LOADER redis-cli INFO persistence"*)
    n="$(cat "$CASE_DIR/loader_n" 2> /dev/null || echo 0)"
    n=$((n + 1))
    echo "$n" > "$CASE_DIR/loader_n"
    line="$(sed -n "${n}p" "$CASE_DIR/loader_seq")"
    if [ -z "$line" ]; then line="$(tail -n 1 "$CASE_DIR/loader_seq")"; fi
    sc=0
    read -r l p s sc <<< "$line"
    printf '# Persistence\r\nloading:%s\r\naof_rewrite_in_progress:%s\r\naof_rewrite_scheduled:%s\r\naof_last_bgrewrite_status:%s\r\n' "$l" "$p" "${sc:-0}" "$s"
    exit 0
    ;;
  *" $LOADER ls /data/appendonlydir"*)
    if [ -f "$CASE_DIR/noaof" ]; then exit 0; fi
    printf 'appendonly.aof.1.base.rdb\nappendonly.aof.manifest\n'
    exit 0
    ;;
  *" $LOADER redis-cli BGREWRITEAOF"*)
    if [ -f "$CASE_DIR/bgrewrite_reply" ]; then cat "$CASE_DIR/bgrewrite_reply"; else echo "Background append only file rewriting started"; fi
    exit 0
    ;;
  *" psql "*)
    db=""
    prev=""
    for a in "$@"; do if [ "$prev" = -d ]; then db="$a"; fi; prev="$a"; done
    sql="$(cat)"
    one="${sql//$'\n'/ ; }"
    case "$sql" in
      *"CREATE ROLE"*)
        printf '%s' "$sql" > "$CASE_DIR/globals-seen"
        echo "PSQL-GLOBALS" >> "$CALL_LOG"
        inject globals
        exit 0
        ;;
    esac
    echo "SQL[$db]: $one" >> "$CALL_LOG"
    case "$sql" in
      *"CREATE DATABASE"*) inject create ;;
      *"REVOKE CONNECT ON DATABASE postgres, template1"*) inject revoke ;;
      *"pg_database WHERE datname ="*) cat "$CASE_DIR/app_check" ;;
      *"NOT datistemplate"*) cat "$CASE_DIR/pgdb_count" ;;
      *"FROM pg_tables"*) cat "$CASE_DIR/tables" ;;
      *"count(*) FROM"*) cat "$CASE_DIR/rowcount" ;;
    esac
    exit 0
    ;;
  *" pg_restore "*)
    body="$(cat)"
    echo "PGRESTORE-STDIN ${body%%$'\n'*}" >> "$CALL_LOG"
    first="${body%%$'\n'*}"
    inject "pgrestore_${first#DUMP-}"
    exit 0
    ;;
  *" ACL USERS"*) cat "$CASE_DIR/acl_users"; exit 0 ;;
  *" INFO keyspace"*) { echo "# Keyspace"; cat "$CASE_DIR/keyspace"; }; exit 0 ;;
esac
exit 0
EOF
chmod +x "$STUB_BIN/docker"

cat > "$STUB_BIN/getent" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = passwd ] && [ "$2" = deploy ]; then
  if [ -f "$CASE_DIR/no_deploy" ]; then exit 2; fi
  echo "deploy:x:1234:1234::/home/deploy:/bin/sh"
  exit 0
fi
exit 2
EOF
chmod +x "$STUB_BIN/getent"

# chown <owner[:group]> -- <path>: logs, records the owner for the stat stub (a bare uid keeps group 0).
cat > "$STUB_BIN/chown" <<'EOF'
#!/usr/bin/env bash
printf 'chown' >> "$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
owner="$1"
shift
if [ "$1" = -- ]; then shift; fi
path="$1"
case "$owner" in *:*) ;; *) owner="$owner:0" ;; esac
mkdir -p "$CASE_DIR/owners"
printf '%s' "$owner" > "$CASE_DIR/owners/$(printf '%s' "$path" | tr / _)"
exit 0
EOF
chmod +x "$STUB_BIN/chown"

# stat: a recorded owner (from the chown stub) with the real mode; everything else is the real stat.
cat > "$STUB_BIN/stat" <<'EOF'
#!/usr/bin/env bash
fmt=""
if [ "$1" = -c ]; then fmt="$2"; shift 2; fi
if [ "$1" = -- ]; then shift; fi
path="$1"
rec="$CASE_DIR/owners/$(printf '%s' "$path" | tr / _)"
case "$fmt" in
  '%u:%g %a') if [ -f "$rec" ]; then echo "$(cat "$rec") $(/usr/bin/stat -c %a -- "$path")"; exit 0; fi ;;
  %u) if [ -f "$rec" ]; then cut -d: -f1 "$rec"; exit 0; fi ;;
esac
exec /usr/bin/stat -c "$fmt" -- "$path"
EOF
chmod +x "$STUB_BIN/stat"

# sleep: no pause (the bounded polls then run out at once).
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB_BIN/sleep"
chmod +x "$STUB_BIN/sleep"

# ---- per-case fixtures ----

ncase=0
OVS=()
mkenv() {
  local f="$C/backup.env"
  printf '%s\n' "RESTIC_REPOSITORY=s3:https://acct.example.test/bucket" "RESTIC_PASSWORD=$PW_SECRET" \
    "AWS_ACCESS_KEY_ID=TESTKEYIDMARKER0001" "AWS_SECRET_ACCESS_KEY=$AWS_SECRET" "AWS_DEFAULT_REGION=auto" \
    "DISCORD_WEBHOOK=$HOOK_SECRET" > "$f"
  chmod 600 "$f"
}

new_case() {
  ncase=$((ncase + 1))
  C="$T_TMP/case$ncase"
  mkdir -p "$C"
  t_reset_calls
  export C CASE_DIR="$C" LOADER
  R="$C/root"
  SR="$C/secrets"
  PGPW="$C/etc/pg.pw"
  RDPW="$C/etc/redis.pw"
  S="$C/snap"
  mkdir -p "$R" "$C/logs" "$SR" "$C/etc" "$S$R/staging/postgres" "$S$R/staging/redis" "$S$SR/app-one" "$S$SR/my-app" "$S$C/etc"
  OVS=("CASE_DIR=$C" "CALL_LOG=$CALL_LOG" "LOADER=$LOADER" "PLATFORM_RESTORE_ALLOW_NONROOT=1"
    "PLATFORM_BACKUP_ENV_FILE=$C/backup.env" "PLATFORM_BACKUP_ENV_OWNER=$(id -u):$(id -g)" "PLATFORM_BACKUP_ROOT=$R"
    "PLATFORM_BACKUP_STATE_DIR=$C/status" "PLATFORM_BACKUP_LOG_DIR=$C/logs" "PLATFORM_BACKUP_LOCK=$C/lock"
    "PLATFORM_BACKUP_SECRETS_ROOT=$SR" "PLATFORM_BACKUP_PG_ADMIN_FILE=$PGPW" "PLATFORM_BACKUP_REDIS_ADMIN_FILE=$RDPW"
    "PLATFORM_RESTORE_COMPOSE=$C/compose.yaml" "PLATFORM_RESTORE_INSTALL_DATA=$C/install-data.sh")
  : > "$C/compose.yaml"
  mkenv
  # snapshot fixture (paths mirror the absolute layout)
  printf -- '-- globals\nCREATE ROLE postgres;\nALTER ROLE postgres WITH SUPERUSER;\nCREATE ROLE app_one;\nCREATE ROLE my_app;\n' > "$S$R/staging/postgres/globals.sql"
  printf 'DUMP-app_one\nbody' > "$S$R/staging/postgres/app_one.dump"
  printf 'DUMP-my_app\nbody' > "$S$R/staging/postgres/my_app.dump"
  printf 'RDB' > "$S$R/staging/redis/dump.rdb"
  printf 'user default off\n' > "$S$R/staging/redis/users.acl"
  printf 'one-db' > "$S$SR/app-one/db-password"
  printf 'my-db' > "$S$SR/my-app/db-password"
  printf 'my-redis' > "$S$SR/my-app/redis-password"
  chmod 0400 "$S$SR/app-one/db-password" "$S$SR/my-app/db-password" "$S$SR/my-app/redis-password"
  printf 'pgpass\n' > "$S$PGPW"
  printf 'redispass\n' > "$S$RDPW"
  # a live host that already has matching admin files and an empty data stack
  printf 'pgpass\n' > "$PGPW"
  printf 'redispass\n' > "$RDPW"
  printf '0|1\n' > "$C/app_check"
  printf '0\n' > "$C/pgdb_count"
  printf 'public.items\n' > "$C/tables"
  printf '3\n' > "$C/rowcount"
  printf 'default\nadmin\nhealth\n' > "$C/acl_users"
  : > "$C/keyspace"
  printf 'registry.test/redis:9@sha256:%s\n' "$(printf 'ee%.0s' {1..32})" > "$C/image_platform-data-redis"
  printf 'volume|platform-data-redis|/var/lib/docker/volumes/x/_data\n' > "$C/mount_platform-data-redis"
  printf '0 0 ok\n0 0 ok\n' > "$C/loader_seq"
  printf '#!/usr/bin/env bash\necho "INSTALL-DATA $*" >> "$CALL_LOG"\n' > "$C/install-data.sh"
  chmod +x "$C/install-data.sh"
}

# rs <args>: restore.sh as a child with an empty caller environment.
rs() {
  rc=0
  out="$(env -i PATH="$PATH" HOME="$C" "${OVS[@]}" bash "$SCRIPT" "$@" 2>&1 < /dev/null)" || rc=$?
}

ov_set() { OVS+=("$@"); }

# line_of <fixed string>: first call-log line number of an entry (empty when absent); last_line_of the last.
line_of() { grep -nF -m1 -- "$1" "$CALL_LOG" | cut -d: -f1; }
last_line_of() { grep -nF -- "$1" "$CALL_LOG" | tail -n 1 | cut -d: -f1; }

# expect_order <label> <n1> <n2>: both exist and n1 < n2.
expect_order() {
  if [ -n "$2" ] && [ -n "$3" ] && [ "$2" -lt "$3" ]; then _pass; else _fail "$1" "order check failed ('$2' before '$3')"; fi
}

MUT_RE='^docker (run|stop|rm|compose)|^docker exec -i [^ ]+ pg_restore|^SQL\[[a-z0-9_]+\]: (CREATE|REVOKE|GRANT)|^PSQL-GLOBALS|^chown'
expect_no_mut() {
  if grep -qE "$MUT_RE" "$CALL_LOG"; then _fail "$1" "a mutating call was made: $(grep -E "$MUT_RE" "$CALL_LOG" | head -n 2 | tr '\n' '|')"; else _pass; fi
}
expect_mut() {
  if grep -qE "$MUT_RE" "$CALL_LOG"; then _pass; else _fail "$1" "no mutating call in the call log (positive control)"; fi
}

# expect_loader_removed <label>: the LAST `docker rm -f <loader>` comes after the last loader INFO poll, i.e. it is the
# on-exit cleanup and not the best-effort removal of a stale loader that runs before the loader starts.
expect_loader_removed() {
  expect_order "$1" "$(last_line_of "$LOADER redis-cli INFO persistence")" "$(last_line_of "docker rm -f $LOADER")"
}

# expect_no_exclude <label>: no restic restore carried --exclude (restic refuses it together with --include).
expect_no_exclude() {
  if grep -E '^restic restore ' "$CALL_LOG" | grep -q -- '--exclude'; then _fail "$1" "a restic restore carried --exclude"; else _pass; fi
}

# ---- 1. list and snapshot selection ----

new_case
rs list
expect_rc "list exits 0" 0
expect_calls_has "list runs restic snapshots filtered by host" "restic snapshots --host platform"
expect_out_has "list prints the snapshots" "abcdef01"
expect_no_mut "list changes nothing"

new_case
rs app app-one --into app_one_r
expect_rc "app (latest) succeeds" 0
expect_calls_has "default latest is host-filtered" "restic restore latest --host platform --target"
expect_calls_has "restic restore (positive control: it ran)" "restic restore"
expect_no_exclude "no restic restore carries --exclude (restic rejects it with --include)"
expect_calls_has "the restore target is under the backup root" "--target $R/restore/"
new_case
rs app app-one --into app_one_r --snapshot "$SID"
expect_rc "app with an explicit snapshot succeeds" 0
expect_calls_has "explicit snapshot id is in the restore argv" "restic restore $SID --target"
expect_calls_lacks "an explicit snapshot is not also host-filtered/latest" "restore latest"
new_case
rs secrets app-one --snapshot "$SID2"
expect_rc "secrets with an explicit snapshot succeeds" 0
expect_calls_has "secrets restore carries the explicit id (positive control: other id)" "restic restore $SID2 --target"
expect_calls_lacks "secrets restore does not carry the other id" "$SID "
new_case
rm -f "$PGPW" "$RDPW"
rs host-files --snapshot "$SID"
expect_rc "host-files with an explicit snapshot succeeds" 0
expect_calls_has "host-files restore carries the explicit id" "restic restore $SID --target"
expect_calls_has "host-files resolves the snapshot first" "restic snapshots --json $SID"
expect_out_has "host-files logs the explicit snapshot id" "resolved id=$SID"
new_case
rs full --confirm-destroy --snapshot "$SID2"
expect_rc "full with an explicit snapshot succeeds" 0
expect_calls_has "full restore carries the explicit id" "restic restore $SID2 --target"
expect_out_has "full logs the explicit snapshot id" "resolved id=$SID2"
expect_no_exclude "full: no restic restore carries --exclude"
new_case
rs full --confirm-destroy
expect_rc "full (latest) succeeds" 0
expect_calls_has "full latest is host-filtered" "restic restore latest --host platform --target"
expect_out_has "full logs the resolved id also for latest" "resolved id=$SID"
expect_out_has "full logs the snapshot time" "time=2026-10-22T03:35:00Z"
n_snap="$(grep -n 'snapshot selector=' <<< "$out" | head -n 1 | cut -d: -f1)"
n_mut="$(grep -n 'phase=pg-globals start' <<< "$out" | head -n 1 | cut -d: -f1)"
expect_order "the snapshot is logged before the first mutating step" "$n_snap" "$n_mut"
expect_order "restic snapshots is called before any mutating call" "$(line_of 'restic snapshots --json')" "$(line_of 'chown')"

new_case
touch "$C/nosnap"
rs full --confirm-destroy
expect_rc "full fails closed when the selector resolves to no snapshot" 1
expect_out_has "the failing step is named" "snapshot-resolve"
expect_no_mut "no mutating call when the snapshot does not resolve"

# ---- 2. app ----

new_case
rs app my-app --into my_app_r
expect_rc "hyphenated app restores" 0
expect_calls_has "restores my_app.dump (not my-app)" "--include $R/staging/postgres/my_app.dump"
expect_calls_has "creates the database owned by role my_app" 'CREATE DATABASE "my_app_r" OWNER "my_app"'
expect_calls_has "REVOKE CONNECT FROM PUBLIC as new-db.sh does" 'REVOKE CONNECT ON DATABASE "my_app_r" FROM PUBLIC'
expect_calls_has "GRANT CONNECT to the app role" 'GRANT CONNECT ON DATABASE "my_app_r" TO "my_app"'
expect_calls_has "pg_restore runs with --no-owner and the app role into the new db" "pg_restore -U postgres --no-owner --role=my_app -d my_app_r"
expect_calls_has "the dump reaches pg_restore on stdin" "PGRESTORE-STDIN DUMP-my_app"
expect_out_has "prints the row count per table" "public.items: 3"
expect_order "CREATE DATABASE comes before pg_restore" "$(line_of 'CREATE DATABASE')" "$(line_of 'pg_restore')"
if [ -e "$R/restore" ] && [ -n "$(ls -A "$R/restore")" ]; then _fail "the restore dir is removed on exit"; else _pass; fi
expect_calls_has "the app lock file is chowned to the current deploy uid" "chown 1234 -- $SR/.my-app.lock"
expect_eq "the app lock is owned by the deploy uid (stat)" "$(stat -c %u "$SR/.my-app.lock")" "1234"
expect_eq "the app lock is mode 0600" "$(/usr/bin/stat -c %a "$SR/.my-app.lock")" "600"

new_case
printf '1|1\n' > "$C/app_check"
rs app app-one --into app_one_r
expect_rc "app refuses an existing --into" 2
expect_calls_lacks "no CREATE DATABASE for an existing --into" "CREATE DATABASE"
new_case
rs app app-one --into app_one
expect_rc "app refuses the live database name" 2
expect_calls_lacks "no CREATE DATABASE for the live name" "CREATE DATABASE"
new_case
rs app app-one --into 'Bad-Name'
expect_rc "app refuses a bad --into name" 2
expect_calls_lacks "no CREATE DATABASE for a bad name" "CREATE DATABASE"
new_case
rs app 'Bad_App' --into app_one_r
expect_rc "app refuses a bad app name" 2
expect_calls_lacks "no CREATE DATABASE for a bad app" "CREATE DATABASE"
new_case
rs app nodump --into nodump_r
expect_rc "app refuses a missing app dump" 2
expect_calls_has "the missing-dump case did restore (positive control: restic ran)" "restic restore"
expect_calls_lacks "no CREATE DATABASE for a missing dump" "CREATE DATABASE"
new_case
printf '0|0\n' > "$C/app_check"
rs app app-one --into app_one_r
expect_rc "app refuses a missing app role" 2
expect_calls_lacks "no CREATE DATABASE without the role" "CREATE DATABASE"
new_case
rs app app-one
expect_rc "app without --into is a usage error" 2
rs app app-one --into app_one_r --bogus
expect_rc "an unknown flag is a usage error" 2

new_case
: > "$SR/.my-app.lock"
exec 7>> "$SR/.my-app.lock"
flock -n 7
rs app my-app --into my_app_r
exec 7>&-
expect_rc "app with the app lock held fails" 1
expect_calls_lacks "the held app lock stops it before Postgres" "psql"
expect_calls_lacks "...and before restic" "restic restore"
new_case
rs app my-app --into my_app_r
expect_rc "app with no lock held works (positive control)" 0
expect_calls_has "...and talks to Postgres" "psql"

new_case
: > "$C/fail_pgrestore_my_app"
printf '3' > "$C/fail_pgrestore_my_app"
rs app my-app --into my_app_r
expect_rc "a failing pg_restore fails the run" 1
expect_out_has "the failing step is named" "app-pg-restore"
expect_out_has "the message says the half-restored database must be dropped before a retry" "drop it (DROP DATABASE \"my_app_r\") before retrying"
if [ -d "$R/restore" ] && [ -z "$(ls -A "$R/restore")" ]; then _pass; else _fail "the restore dir is removed after a failed run without --keep"; fi
if compgen -G "$R/.restore-work.*" > /dev/null; then _fail "the work dir is removed after a failed run"; else _pass; fi

new_case
printf '3' > "$C/fail_create"
rs app my-app --into my_app_r
expect_rc "a failing CREATE DATABASE fails the run" 1
expect_out_has "the failing step is named" "app-create"
expect_calls_lacks "pg_restore is not reached after a failing CREATE DATABASE" "pg_restore"

new_case
rs app my-app --into my_app_r --keep
expect_rc "app --keep succeeds" 0
kept="$(ls -A "$R/restore")"
if [ -n "$kept" ]; then _pass; else _fail "--keep leaves the restore dir in place"; fi
expect_eq "the kept restore dir is mode 0700" "$(/usr/bin/stat -c %a "$R/restore/$kept")" "700"
expect_eq "the restore base dir is mode 0700" "$(/usr/bin/stat -c %a "$R/restore")" "700"
expect_calls_has "--target is a dir under <root>/restore" "--target $R/restore/$kept"
expect_out_has "--keep logs where the dir was kept" "restore dir kept at $R/restore/$kept"
if compgen -G "$R/.restore-work.*" > /dev/null; then _fail "the work dir is removed even with --keep"; else _pass; fi

# ---- 3. secrets ----

new_case
rs secrets my-app
expect_rc "secrets restores an absent app dir" 0
expect_calls_has "chown to the current deploy uid and gid 64323 (dir)" "chown 1234:64323 -- $SR/my-app"
expect_calls_has "chown (file)" "chown 1234:64323 -- $SR/my-app/db-password"
expect_eq "the dir owner is recorded as deploy:64323 (stat)" "$(stat -c '%u:%g %a' "$SR/my-app")" "1234:64323 2750"
expect_eq "the file owner is recorded as deploy:64323 mode 440 (stat)" "$(stat -c '%u:%g %a' "$SR/my-app/db-password")" "1234:64323 440"
expect_eq "the other file is mode 440 too" "$(stat -c '%u:%g %a' "$SR/my-app/redis-password")" "1234:64323 440"
expect_eq "restored content" "$(cat "$SR/my-app/db-password")" "my-db"
new_case
mkdir -p "$SR/my-app"
printf 'live' > "$SR/my-app/db-password"
rs secrets my-app
expect_rc "secrets refuses when the dir exists" 2
expect_calls_lacks "no restic restore when the dir exists" "restic restore"
expect_eq "the live file is untouched" "$(cat "$SR/my-app/db-password")" "live"
new_case
rs secrets nodata
expect_rc "secrets refuses an app the snapshot does not hold" 2
new_case
touch "$C/no_deploy"
rs secrets my-app
expect_rc "secrets refuses without a deploy user" 2

# ---- 4. host-files ----

new_case
rm -f "$PGPW" "$RDPW"
rs host-files
expect_rc "host-files writes both absent files" 0
expect_eq "pg admin file content restored" "$(cat "$PGPW")" "pgpass"
expect_eq "redis admin file content restored" "$(cat "$RDPW")" "redispass"
expect_eq "admin file mode is 0640" "$(/usr/bin/stat -c %a "$PGPW")" "640"
expect_calls_has "admin files are chowned root:64322" "chown 0:64322 -- $C/etc/.tmp.restore."
new_case
rs host-files
expect_rc "host-files on identical files succeeds" 0
expect_out_has "identical file reports already:" "already: $PGPW"
expect_calls_lacks "an identical file is not rewritten" "chown 0:64322"
new_case
printf 'DIFFERENT\n' > "$PGPW"
rm -f "$RDPW"
rs host-files
expect_rc "host-files refuses a differing existing file" 2
expect_eq "the differing file is byte-identical to before" "$(cat "$PGPW")" "DIFFERENT"
if [ -e "$RDPW" ]; then _fail "the absent file is not written when another differs"; else _pass; fi
expect_calls_lacks "nothing is chowned on refusal" "chown"

# ---- 5. full: refusals ----

new_case
rs full
expect_rc "full without --confirm-destroy exits 2" 2
expect_no_mut "full without the flag has no mutating call"
expect_calls_lacks "...nor any docker call" "docker"
new_case
printf '1\n' > "$C/pgdb_count"
rs full --confirm-destroy
expect_rc "full refuses a cluster with an app database" 2
expect_no_mut "no mutating call when a database exists"
new_case
printf 'db0:keys=1,expires=0,avg_ttl=0\n' > "$C/keyspace"
rs full --confirm-destroy
expect_rc "full refuses a Redis with a key" 2
expect_no_mut "no mutating call when Redis holds a key"
new_case
printf 'default\nadmin\nhealth\nsomeapp\n' > "$C/acl_users"
rs full --confirm-destroy
expect_rc "full refuses a Redis with an extra ACL user" 2
expect_no_mut "no mutating call when Redis has an extra user"
new_case
printf 'ERR something\n' > "$C/acl_users"
rs full --confirm-destroy
expect_rc "full refuses on an unreadable Redis user list" 2
expect_no_mut "no mutating call on an unreadable Redis user list"
new_case
printf 'exited|\n' > "$C/health_platform-data-redis"
rs full --confirm-destroy
expect_rc "full refuses when Redis is not healthy" 2
expect_no_mut "no mutating call when Redis is down"
new_case
mkdir -p "$SR/app-one"
rs full --confirm-destroy
expect_rc "full refuses when a live secrets dir exists" 2
expect_no_mut "no mutating call when a live secrets dir exists"
new_case
rm -f "$PGPW" "$RDPW"
rs full --confirm-destroy
expect_rc "full refuses when the admin files were not restored first" 2
expect_no_mut "rebuilt-host path: no mutating call without the admin files"
expect_calls_lacks "...and no restic restore" "restic restore"
expect_out_has "...pointing at the runbook order" "host-files"
new_case
printf 'DIFFERENT\n' > "$PGPW"
rs full --confirm-destroy
expect_rc "full refuses when an admin file differs from the snapshot" 2
expect_no_mut "no mutating call when an admin file differs"
new_case
rm -f "$C/compose.yaml"
rs full --confirm-destroy
expect_rc "full refuses without the data compose file" 2
expect_no_mut "no mutating call without the compose file"

# full validates the whole snapshot before its first mutation (exit 2, nothing changed)
new_case
rm -f "$S$R/staging/postgres/globals.sql"
rs full --confirm-destroy
expect_rc "full refuses a snapshot without globals.sql" 2
expect_calls_has "(positive control: the snapshot was restored first)" "restic restore"
expect_no_mut "no mutating call when globals.sql is missing"
new_case
printf 'DUMP-x\n' > "$S$R/staging/postgres/Bad-Name.dump"
rs full --confirm-destroy
expect_rc "full refuses a dump with an invalid database name" 2
expect_no_mut "no mutating call when a dump name is invalid"
new_case
rm -f "$S$R/staging/redis/dump.rdb"
rs full --confirm-destroy
expect_rc "full refuses a snapshot without dump.rdb" 2
expect_no_mut "no mutating call (no secrets placed, no Postgres restore) when dump.rdb is missing"
new_case
rm -f "$S$R/staging/redis/users.acl"
rs full --confirm-destroy
expect_rc "full refuses a snapshot without users.acl" 2
expect_no_mut "no mutating call when users.acl is missing"
new_case
rm -rf "$S$SR/my-app"
ln -s /nonexistent "$S$SR/my-app"
rs full --confirm-destroy
expect_rc "full refuses a symlinked app secrets entry" 2
expect_no_mut "no app's secrets are placed when a LATER app entry is invalid"
if [ -e "$SR/app-one" ]; then _fail "the first app's directory was not moved"; else _pass; fi
new_case
printf '||\n' > "$C/mount_platform-data-redis"
rs full --confirm-destroy
expect_rc "full refuses a Redis container with no /data mount before any mutation" 2
expect_no_mut "no mutating call without a /data mount"
expect_calls_has "(positive control: the container was inspected)" "docker inspect --format {{range .Mounts}}"
new_case
rm -f "$C/image_platform-data-redis"
rs full --confirm-destroy
expect_rc "full fails when the Redis image cannot be inspected, before any mutation" 1
expect_no_mut "no mutating call when the Redis image is unknown"

# ---- 6. full: success, ordering ----

# rebuilt host: the admin files are absent, host-files writes them, then full succeeds on the same snapshot
new_case
rm -f "$PGPW" "$RDPW"
rs host-files --snapshot "$SID"
expect_rc "rebuilt host: host-files restores the absent admin files" 0
rs full --confirm-destroy --snapshot "$SID"
expect_rc "rebuilt host: full then succeeds in the same case" 0
expect_mut "rebuilt host: full made mutating calls (positive control)"
expect_out_has "rebuilt host: full prints the snapshot it used" "full restore done from snapshot $SID"

new_case
mkdir -p "$S$SR/.hidden"
before_mode="$(/usr/bin/stat -c '%a' "$SR")"
rs full --confirm-destroy
expect_rc "full succeeds on an empty stack" 0
expect_mut "positive control: full made mutating calls"
expect_calls_has "restores the postgres staging dir (override layout)" "--include $R/staging/postgres"
expect_calls_has "restores the redis staging dir" "--include $R/staging/redis"
expect_calls_has "restores the secrets root" "--include $SR"
expect_calls_has "restores both admin files" "--include $PGPW --include $RDPW"
expect_order "secrets are placed before the globals load" "$(line_of 'chown 1234:64323')" "$(line_of 'PSQL-GLOBALS')"
expect_order "globals load before any pg_restore" "$(line_of 'PSQL-GLOBALS')" "$(line_of 'pg_restore')"
if [ -f "$C/globals-seen" ] && grep -q 'CREATE ROLE app_one' "$C/globals-seen"; then _pass; else _fail "the globals reach psql (positive control)"; fi
if grep -qF 'CREATE ROLE postgres;' "$C/globals-seen"; then _fail "CREATE ROLE postgres is not emitted"; else _pass; fi
expect_calls_has "both dumps are restored with -C" "pg_restore -U postgres -C -d postgres --exit-on-error"
expect_calls_has "app_one dump restored" "PGRESTORE-STDIN DUMP-app_one"
expect_calls_has "my_app dump restored" "PGRESTORE-STDIN DUMP-my_app"
expect_eq "the secrets root mode is unchanged" "$(/usr/bin/stat -c '%a' "$SR")" "$before_mode"
if grep -qE -- " -- $SR\$" "$CALL_LOG"; then _fail "the secrets root itself is never chowned"; else _pass; fi
expect_eq "restored app secret owner/mode" "$(stat -c '%u:%g %a' "$SR/app-one/db-password")" "1234:64323 440"
expect_no_exclude "full success: no restic restore carries --exclude"
# full takes no per-app lock files (the glob must match nothing; a stray lock would be a behaviour change to look at)
if compgen -G "$SR/.*.lock" > /dev/null; then _fail "full creates no per-app lock file"; else _pass; fi
# Redis ordering
l_stop="$(line_of 'stop redis')"
l_replace="$(line_of 'docker run --rm')"
l_start_loader="$(line_of "docker run -d --name $LOADER")"
l_aof="$(line_of "$LOADER redis-cli BGREWRITEAOF")"
l_lstop="$(line_of "docker stop $LOADER")"
l_lrm="$(line_of "docker rm $LOADER")"
l_rstart="$(line_of 'start redis')"
expect_order "the old Redis is stopped before the files are replaced" "$l_stop" "$l_replace"
expect_order "the files are replaced before the loader starts" "$l_replace" "$l_start_loader"
expect_order "BGREWRITEAOF runs after the loader starts" "$l_start_loader" "$l_aof"
expect_order "the loader is stopped after the rewrite" "$l_aof" "$l_lstop"
expect_order "the loader is removed after it is stopped" "$l_lstop" "$l_lrm"
expect_order "the real Redis starts only after the loader is removed" "$l_lrm" "$l_rstart"
expect_calls_has "the loader runs with --appendonly no" "--appendonly no --save  --dir /data"
expect_order "the loader starts strictly after the old Redis stop (not before)" "$l_stop" "$l_start_loader"
# REVOKE and verify
l_revoke="$(line_of 'REVOKE CONNECT ON DATABASE postgres, template1 FROM PUBLIC')"
l_lastrestore="$(last_line_of 'PGRESTORE-STDIN')"
l_verify="$(line_of 'INSTALL-DATA verify')"
expect_order "REVOKE runs after the last pg_restore" "$l_lastrestore" "$l_revoke"
expect_order "install-data verify runs after the REVOKE" "$l_revoke" "$l_verify"
expect_out_has "full prints the snapshot it used" "full restore done from snapshot $SID"

new_case
printf '1' > "$C/fail_revoke"
rs full --confirm-destroy
expect_rc "a failing REVOKE exits nonzero" 1
expect_out_has "...naming the step" "pg-revoke"
expect_calls_lacks "verify is not reached after a failing REVOKE" "INSTALL-DATA"
expect_calls_lacks "Redis is not touched after a failing REVOKE" "stop redis"

new_case
rm -f "$C/install-data.sh"
rs full --confirm-destroy
expect_rc "full with no install-data.sh skips the verify and exits 0" 0
expect_out_has "...and logs the skip" "verify: skipped"
new_case
printf '#!/usr/bin/env bash\necho "INSTALL-DATA $*" >> "$CALL_LOG"\nexit 1\n' > "$C/install-data.sh"
rs full --confirm-destroy
expect_rc "a failing verify exits nonzero" 1
expect_out_has "...naming the verify step" "step 'verify'"
expect_calls_has "(positive control: the stub verify was called)" "INSTALL-DATA verify"

new_case
printf '3' > "$C/fail_globals"
rs full --confirm-destroy
expect_rc "a failing globals load exits nonzero" 1
expect_out_has "...naming the step" "pg-globals"
expect_calls_lacks "no pg_restore after a failing globals load" "pg_restore"
new_case
printf '3' > "$C/fail_pgrestore_my_app"
rs full --confirm-destroy
expect_rc "a failing pg_restore exits nonzero" 1
expect_out_has "...naming the step" "pg-restore:my_app"
expect_calls_lacks "Redis is untouched after a failing pg_restore" "stop redis"

# ---- 7. full: Redis loader failures ----

new_case
printf '0 0 ok\n0 1 ok\n0 1 ok\n0 0 ok\n' > "$C/loader_seq"
rs full --confirm-destroy
expect_rc "an in-progress rewrite keeps waiting, then proceeds" 0
expect_order "...the real Redis starts only after the rewrite finished" "$(line_of "docker rm $LOADER")" "$(line_of 'start redis')"

# A "scheduled" rewrite has not forked yet: in_progress 0 and status ok must NOT count as done.
new_case
printf 'Background append only file rewriting scheduled\n' > "$C/bgrewrite_reply"
printf '0 0 ok\n0 0 ok 1\n0 0 ok 1\n0 1 ok 0\n0 0 ok 0\n' > "$C/loader_seq"
rs full --confirm-destroy
expect_rc "a scheduled rewrite keeps waiting until it ran, then proceeds" 0
expect_eq "the loader was polled until the rewrite finished (4 INFO calls after BGREWRITEAOF)" "$(grep -c 'redis-cli INFO persistence' "$CALL_LOG")" "5"
new_case
printf 'Background append only file rewriting scheduled\n' > "$C/bgrewrite_reply"
printf '0 0 ok\n0 0 ok 1\n' > "$C/loader_seq"
rs full --confirm-destroy
expect_rc "a rewrite that stays scheduled times out" 1
expect_out_has "...naming the step" "redis-aof-wait"
expect_calls_lacks "the real Redis is not started while a rewrite is only scheduled" "start redis"
new_case
touch "$C/noaof"
rs full --confirm-destroy
expect_rc "a loader without append-only files fails" 1
expect_out_has "...naming the step" "redis-aof-check"
expect_calls_lacks "the real Redis is not started without an AOF" "start redis"
expect_loader_removed "the loader is removed on the aof-check failure"

new_case
printf '0 0 ok\n0 0 err\n' > "$C/loader_seq"
rs full --confirm-destroy
expect_rc "an AOF rewrite error exits nonzero" 1
expect_out_has "...naming the step" "redis-aof-wait"
expect_calls_has "the loader was started (positive control)" "docker run -d --name $LOADER"
expect_loader_removed "the one-shot container is removed by the exit cleanup (after the last poll)"
expect_calls_lacks "the real Redis is not started" "start redis"

new_case
printf '0 0 ok\n0 1 ok\n' > "$C/loader_seq"
rs full --confirm-destroy
expect_rc "a rewrite that never finishes times out" 1
expect_out_has "...naming the step" "redis-aof-wait"
expect_loader_removed "the one-shot container is removed after the timeout (after the last poll)"
expect_calls_lacks "the real Redis is not started after the timeout" "start redis"

new_case
printf 'ERR Background append only file rewriting refused\n' > "$C/bgrewrite_reply"
rs full --confirm-destroy
expect_rc "a refused BGREWRITEAOF exits nonzero" 1
expect_out_has "...naming the step" "redis-bgrewriteaof"
expect_loader_removed "the loader is removed after the refusal (after the last poll)"
expect_calls_lacks "the real Redis is not started" "start redis"

new_case
printf '1 0 ok\n' > "$C/loader_seq"
rs full --confirm-destroy
expect_rc "a loader stuck loading times out" 1
expect_out_has "...naming the step" "redis-loader-loading"
expect_calls_lacks "BGREWRITEAOF is not sent while loading" "BGREWRITEAOF"
expect_loader_removed "the stuck loader is removed (after the last poll)"

new_case
printf '3' > "$C/fail_run_loader"
rs full --confirm-destroy
expect_rc "a failing loader start exits nonzero" 1
expect_out_has "...naming the step" "redis-loader-start"
expect_calls_lacks "the real Redis is not started" "start redis"

new_case
printf '3' > "$C/fail_compose_start"
rs full --confirm-destroy
expect_rc "a failing real Redis start exits nonzero" 1
expect_out_has "...naming the step" "redis-start"

new_case
printf '3' > "$C/fail_compose_stop"
rs full --confirm-destroy
expect_rc "a failing Redis stop exits nonzero" 1
expect_out_has "...naming the step" "redis-stop"
expect_calls_lacks "the loader is not started when the old Redis did not stop" "docker run"

# compose stop exits 0 but selected no container (wrong project): the real Redis is still running, so nothing may touch /data.
new_case
printf 'x' > "$C/running_platform-data-redis"
rs full --confirm-destroy
expect_rc "a Redis that is still running after compose stop fails the restore" 1
expect_out_has "...naming the step" "redis-stop-check"
expect_calls_lacks "no file replace or loader runs against a still-running Redis" "docker run"

# ---- 8. loader image and mount come from docker inspect ----

new_case
ov_set "PLATFORM_BACKUP_REDIS_CONTAINER=other-redis" "LOADER=other-redis-restore-loader"
printf 'registry.test/redis:other@sha256:%s\n' "$(printf '12%.0s' {1..32})" > "$C/image_other-redis"
printf 'volume|vol-other|/var/lib/docker/volumes/o/_data\n' > "$C/mount_other-redis"
rs full --confirm-destroy
expect_rc "full with a different Redis container succeeds" 0
expect_calls_has "the loader name is derived from the Redis container" "docker run -d --name other-redis-restore-loader"
expect_calls_lacks "the shared default loader name is never used for another stack" "platform-data-redis-restore-loader"
expect_calls_lacks "compose is never given a hard-coded project name" "docker compose -p"
expect_calls_has "the stop of the named Redis is verified" "docker inspect --format {{.State.Running}} other-redis"
expect_calls_has "the image is inspected from the named container" "docker inspect --format {{.Config.Image}} other-redis"
expect_calls_has "the mount is inspected from the named container" "{{end}}{{end}} other-redis"
expect_calls_lacks "the default container is never inspected for image or mounts" "{{.Config.Image}} platform-data-redis"
expect_calls_has "the loader uses the inspected image" "registry.test/redis:other@sha256:"
expect_calls_has "the loader mounts the inspected volume" "-v vol-other:/data"
expect_calls_lacks "never the literal platform-data-redis volume" "platform-data-redis:/data"
new_case
printf 'bind||/srv/redis-data\n' > "$C/mount_platform-data-redis"
rs full --confirm-destroy
expect_rc "a bind mount is used as the loader source" 0
expect_calls_has "the loader mounts the bind source" "-v /srv/redis-data:/data"

# ---- 9. lock, dirs, credentials, overrides ----

new_case
exec 8> "$C/lock"
flock -n 8
rs app my-app --into my_app_r
exec 8>&-
expect_rc "restore while a backup holds the lock fails with exit 1" 1
expect_calls_lacks "...before any call" "docker"
new_case
rs list
expect_rc "list with the lock free works (positive control)" 0

new_case
rmdir "$R"
rs list
expect_rc "a missing backup root exits 2" 2
expect_out_has "...naming the dir" "$R"
expect_eq "...with no call and no created dir" "$(cat "$CALL_LOG")$([ -e "$R" ] && echo exists)" ""
new_case
rmdir "$C/logs"
rs list
expect_rc "a missing log dir exits 2" 2
expect_out_has "...naming the dir" "$C/logs"
if [ -e "$C/logs" ]; then _fail "the log dir is never created"; else _pass; fi
expect_eq "...with no call" "$(cat "$CALL_LOG")" ""
new_case
rm -rf "$C"/status
rs list
if [ -e "$C/status" ]; then _fail "the state dir is not created by restore"; else _pass; fi

# Credentials
new_case
for sub in "list" "app my-app --into my_app_r" "secrets nodata" "host-files" "full --confirm-destroy"; do
  : > "$C/restic-env"
  # shellcheck disable=SC2086
  rs $sub
  # HOOK=[] is deliberate: DISCORD_WEBHOOK is read (and masked) but never exported to children.
  want="REPO=[s3:https://acct.example.test/bucket] PW=[$PW_SECRET] AK=[TESTKEYIDMARKER0001] SK=[$AWS_SECRET] REG=[auto] HOOK=[]"
  expect_eq "empty caller environment: '$sub' reads the keys from the env file; DISCORD_WEBHOOK is not exported" "$(cat "$C/restic-env")" "$want"
  rm -rf "$SR/my-app" "$SR/.my-app.lock"
done
new_case
grep -v '^DISCORD_WEBHOOK=' "$C/backup.env" > "$C/backup.env.new"
mv "$C/backup.env.new" "$C/backup.env"
chmod 600 "$C/backup.env"
rs list
expect_rc "an env file without DISCORD_WEBHOOK is refused" 2
expect_out_has "...naming the missing key" "DISCORD_WEBHOOK"
expect_calls_lacks "...before any call" "restic"

# Masking: a restic failure that echoes the repository and password must not leak them into the run output or the log file
new_case
printf '3' > "$C/fail_restore"
rs full --confirm-destroy
expect_rc "a failing restic restore fails the run" 1
expect_out_has "...naming the step" "restic-restore-full"
expect_eq "(positive control) the stub saw the real password" "$(sed -n 's/.*PW=\[\([^]]*\)\].*/\1/p' "$C/restic-env")" "$PW_SECRET"
expect_out_has "(positive control) the injected failure reached the output, masked" "injected failure restore"
expect_out_has "the secrets are replaced by ***" "***"
expect_out_lacks "the restic password is not in the output" "$PW_SECRET"
expect_out_lacks "the repository is not in the output" "s3:https://acct.example.test/bucket"
if grep -qF -e "$PW_SECRET" -e "$AWS_SECRET" -e "$HOOK_SECRET" "$C"/logs/*.log; then _fail "no secret value reaches the file log"; else _pass; fi
if compgen -G "$C/logs/*.log" > /dev/null; then _pass; else _fail "(positive control) a file log was written"; fi
new_case
ln -s "$C/backup.env.real" "$C/backup.env.link"
mv "$C/backup.env" "$C/backup.env.real"
ln -s "$C/backup.env.real" "$C/backup.env"
rs list
expect_rc "a symlink env file is refused" 2
expect_calls_lacks "...before any call" "restic"
new_case
chmod 644 "$C/backup.env"
rs list
expect_rc "a wrong-mode env file is refused" 2
new_case
ov_set "PLATFORM_BACKUP_ENV_OWNER=$(($(id -u) + 1)):$(id -g)"
rs list
expect_rc "a wrong-owner env file is refused" 2
new_case
marker="$C/pwned"
printf '%s\n' "RESTIC_REPOSITORY=s3:x" "RESTIC_PASSWORD=\$(touch $marker)a" "AWS_ACCESS_KEY_ID=k" "AWS_SECRET_ACCESS_KEY=s" "AWS_DEFAULT_REGION=auto" "DISCORD_WEBHOOK=h" > "$C/backup.env"
chmod 600 "$C/backup.env"
rs list
expect_rc "a planted \$(...) value does not break the run" 0
if [ -e "$marker" ]; then _fail "the planted \$(...) did not execute"; else _pass; fi
expect_eq "(positive control: the literal reached the restic stub)" "$(sed -n 's/.*PW=\[\([^]]*\)\].*/\1/p' "$C/restic-env")" "\$(touch $marker)a"
new_case
printf '%s\n' "RESTIC_REPOSITORY=s3:x" "RESTIC_REPOSITORY=s3:y" > "$C/backup.env"
chmod 600 "$C/backup.env"
rs list
expect_rc "a duplicate key is refused" 2

# Overrides fail closed
if [ "$(id -u)" -ne 0 ]; then
  new_case
  OVS=("${OVS[@]/PLATFORM_RESTORE_ALLOW_NONROOT=1/PLATFORM_RESTORE_UNSET=1}")
  rs list
  expect_rc "a non-root run exits 2 with no override" 2
  expect_calls_lacks "...before any call" "restic"
  new_case
  OVS=("${OVS[@]/PLATFORM_RESTORE_ALLOW_NONROOT=1/PLATFORM_RESTORE_ALLOW_NONROOT=0}")
  rs list
  expect_rc "ALLOW_NONROOT=0 does not bypass the root check" 2
  new_case
  OVS=("${OVS[@]/PLATFORM_BACKUP_ENV_OWNER=*/PLATFORM_RESTORE_UNSET2=1}")
  rs list
  expect_rc "ALLOW_NONROOT alone does not relax the env-file owner check (non-root-owned env file, default 0:0)" 2
else
  echo "SKIP: running as root, the non-root fail-closed cases are skipped"
fi
new_case
ov_set "PLATFORM_RESTORE_COMPOSE=relative.yaml"
rs list
expect_rc "an unparsable compose override exits 2" 2
new_case
ov_set "PLATFORM_RESTORE_CHOWN=a b"
rs list
expect_rc "an unparsable chown override exits 2" 2
new_case
ov_set "PLATFORM_BACKUP_ENV_OWNER=bad"
rs list
expect_rc "an unparsable env-owner override exits 2" 2
new_case
ov_set "PLATFORM_BACKUP_PG_CONTAINER=bad name"
rs list
expect_rc "an invalid container override exits 2" 2
new_case
ov_set "PLATFORM_BACKUP_DEADLINE_SECS=abc"
rs list
expect_rc "restore ignores an invalid PLATFORM_BACKUP_DEADLINE_SECS" 0
rc=0
out="$(env -i PATH="$PATH" HOME="$C" "${OVS[@]}" bash "$BACKUP_SCRIPT" nightly 2>&1 < /dev/null)" || rc=$?
expect_rc "(control) backup.sh with the same value exits 2" 2

new_case
ov_set "PLATFORM_RESTORE_COMPOSE=$C/other.yaml" "PLATFORM_RESTORE_CHOWN=chown" "PLATFORM_BACKUP_DEADLINE_SECS=5"
: > "$C/other.yaml"
rs full
expect_rc "no override relaxes --confirm-destroy" 2
expect_no_mut "...(no mutating call)"
new_case
ov_set "PLATFORM_RESTORE_COMPOSE=$C/other.yaml" "PLATFORM_BACKUP_DEADLINE_SECS=5"
: > "$C/other.yaml"
printf '1\n' > "$C/pgdb_count"
rs full --confirm-destroy
expect_rc "no override relaxes the non-empty-cluster refusal" 2
expect_no_mut "...(no mutating call)"

# Production defaults and override-driven include paths (static: the default constants in the script)
for d in \
  '  ov_path ENV_FILE PLATFORM_BACKUP_ENV_FILE /etc/platform/backup.env' \
  '  ov_path BACKUP_ROOT PLATFORM_BACKUP_ROOT /var/lib/platform/backup' \
  '  ov_path STATE_DIR PLATFORM_BACKUP_STATE_DIR /var/lib/platform/backup-status' \
  '  ov_path LOG_DIR PLATFORM_BACKUP_LOG_DIR /var/log/platform-backup' \
  '  ov_path LOCK_FILE PLATFORM_BACKUP_LOCK /run/platform-backup.lock' \
  '  ov_path SECRETS_ROOT PLATFORM_BACKUP_SECRETS_ROOT /var/lib/platform/secrets' \
  '  ov_path PG_ADMIN_FILE PLATFORM_BACKUP_PG_ADMIN_FILE /etc/platform/postgres-admin.password' \
  '  ov_path REDIS_ADMIN_FILE PLATFORM_BACKUP_REDIS_ADMIN_FILE /etc/platform/redis-admin.password' \
  '  ov_name PG_CONTAINER PLATFORM_BACKUP_PG_CONTAINER platform-data-postgres' \
  '  ov_name REDIS_CONTAINER PLATFORM_BACKUP_REDIS_CONTAINER platform-data-redis' \
  '  ov_path COMPOSE_FILE PLATFORM_RESTORE_COMPOSE /opt/platform/data/compose.yaml' \
  '  ov_path INSTALL_DATA PLATFORM_RESTORE_INSTALL_DATA /opt/platform/data/install-data.sh'; do
  if grep -qxF -- "$d" "$SCRIPT"; then _pass; else _fail "the production default line is present verbatim in restore.sh: $d"; fi
done
if grep -qE '^  CHOWN="chown"$' "$SCRIPT"; then _pass; else _fail "the default chown command is chown"; fi
if grep -qE 'ENV_OWNER="0:0"' "$SCRIPT"; then _pass; else _fail "the default env owner is 0:0"; fi
new_case
rs secrets my-app
expect_calls_has "the include path is the override path" "--include $SR/my-app"
expect_calls_lacks "(positive control) the production secrets path is not used" "/var/lib/platform/secrets"
new_case
rs full --confirm-destroy
expect_calls_lacks "full restores no production path with overrides set" "--include /etc/platform"

# ---- 10. reader and snippet drift (static) ----

extract_reader() { sed -n '/^# BEGIN shared-env-reader/,/^# END shared-env-reader/p' "$1"; }
expect_eq "the env-reader body in restore.sh is byte-identical to backup.sh's" "$(extract_reader "$SCRIPT")" "$(extract_reader "$BACKUP_SCRIPT")"
if [ -n "$(extract_reader "$SCRIPT")" ]; then _pass; else _fail "the reader markers are present in restore.sh"; fi
mutated="$(extract_reader "$SCRIPT" | sed 's/mode is not 0600/mode is not 0601/')"
if [ "$mutated" = "$(extract_reader "$BACKUP_SCRIPT")" ]; then _fail "mutation positive control: a changed byte must make the comparison fail"; else _pass; fi
snippet() { grep -m1 '^readonly REDIS_ADMIN_SNIPPET=' "$1"; }
expect_eq "REDIS_ADMIN_SNIPPET matches backup.sh" "$(snippet "$SCRIPT")" "$(snippet "$BACKUP_SCRIPT")"
expect_eq "REDIS_ADMIN_SNIPPET matches new-db.sh" "$(snippet "$SCRIPT")" "$(snippet "$NEWDB_SCRIPT")"
if grep -qF -- "$(snippet "$SCRIPT" | sed "s/^readonly REDIS_ADMIN_SNIPPET=//")" "$INSTALL_DATA_SCRIPT"; then _pass; else _fail "REDIS_ADMIN_SNIPPET matches install-data.sh"; fi

# ---- 11. usage ----

new_case
rs
expect_rc "no subcommand is a usage error" 2
rs bogus
expect_rc "an unknown subcommand is a usage error" 2
rs list extra
expect_rc "list takes no arguments" 2
rs app app-one --into app_one_r --snapshot 'not-hex!'
expect_rc "a bad --snapshot value is a usage error" 2
rs host-files --confirm-destroy
expect_rc "--confirm-destroy is only for full" 2
expect_calls_lacks "usage errors make no call" "docker"

t_finish
