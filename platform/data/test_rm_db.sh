#!/usr/bin/env bash
# Stub tests for rm-db.sh, mirroring test_new_db.sh. The docker stub is stateful (containers, roles, databases, the Redis
# user and keys, local images live as files under $STATE) and records argv (CALL_LOG) and stdin (STATE/stdin.log). The
# data roots are real temp directories, the lock is the real flock, and the reserved-names list is a copy of the tracked
# registry file. The "run as deploy" prefix is a stub (`asdeploy`) that logs the delete and then runs it, so a case can
# make a delete silently do nothing and prove the final re-scan catches it.
#
# The real removal against real Postgres and Redis (and a clean new-db afterwards) is in test_data_live.sh.
#
# SC2016: stub bodies are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# SC2154: $out and $rc are set by run_cmd in lib.sh. SC2034: some fixture variables are only read by sub-functions.
# shellcheck disable=SC1091,SC2016,SC2034,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/rm-db.sh"
RESERVED_SRC="$here/../registry/reserved-names.txt"
REAL_CHMOD="$(command -v chmod)"

t_init
STATE="$T_TMP/state"
SECRETS="$T_TMP/secrets"
JOBS="$T_TMP/job-secrets"
DSTATE="$T_TMP/deploy-state"
REG="$T_TMP/registry"
LOCKS="$T_TMP/locks"
RESERVED="$T_TMP/reserved-names.txt"
LOGGER_LOG="$T_TMP/logger.log"
NS=example.test/apps
export STATE LOGGER_LOG SECRETS JOBS DSTATE REG

PGC=test-data-postgres
RDC=test-data-redis

if command -v flock >/dev/null 2>&1; then _pass; else _fail "flock is available for the lock tests"; fi

# ---- stubs ----

mkstub() { # <name>: the body comes from stdin; the stub first logs "<name> <argv...>" to the call log
  local name="$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s" %q >> "$CALL_LOG"\n' "$name"
    printf 'for a in "$@"; do printf " %%s" "$a" >> "$CALL_LOG"; done\n'
    printf 'printf "\\n" >> "$CALL_LOG"\n'
    cat
  } > "$STUB_BIN/$name"
  "$REAL_CHMOD" +x "$STUB_BIN/$name"
}

mkstub logger <<'EOF'
printf '%s\n' "$*" >> "$LOGGER_LOG"
exit 0
EOF

# asdeploy rm -rf -- <path>: the deploy-user prefix. $STATE/fail_files makes it fail; $STATE/noop_<root> (registry,
# secrets, jobsecrets, state) makes a delete of that root's path report success without deleting anything.
mkstub asdeploy <<'EOF'
[ ! -f "$STATE/fail_files" ] || exit "$(cat "$STATE/fail_files")"
path="${*: -1}"
case "$path" in
  "$REG"/*) k=registry ;;
  "$SECRETS"/*) k=secrets ;;
  "$JOBS"/*) k=jobsecrets ;;
  "$DSTATE"/*) k=state ;;
  *) echo "stub: unexpected delete path $path" >&2; exit 97 ;;
esac
[ ! -f "$STATE/fail_files_$k" ] || exit "$(cat "$STATE/fail_files_$k")"
echo "MARK $k" >> "$CALL_LOG"
[ ! -f "$STATE/noop_$k" ] || exit 0
exec "$@"
EOF

# docker: stateful. Failure switches are files $STATE/fail_<key> holding the exit code (124 = timeout).
# keys: ps rmctr pg-drop-db pg-drop-role pg-final rd-scan rd-deluser rd-save rd-users rmi imgls; health: fail_health_<name>.
# Leave-behind switches: noop_dropdb noop_droprole noop_delkeys noop_deluser noop_rmi.
# Files: ctr_<app> (container names, one per line), db_<name>, role_<name>, ruser_<name>, rkey_<key>, images
# ("<id> <repo> <tag> <digest>" lines).
mkstub docker <<'EOF'
S="$STATE"
sub="$1"
shift
stubfail() { [ ! -f "$S/fail_$1" ] || exit "$(cat "$S/fail_$1")"; }
case "$sub" in
  inspect)
    name="${*: -1}"
    [ ! -f "$S/fail_health_$name" ] || exit "$(cat "$S/fail_health_$name")"
    echo "running|healthy"
    exit 0 ;;
  ps)
    stubfail ps
    app=""
    for a in "$@"; do case "$a" in label=platform.app=*) app="${a#label=platform.app=}" ;; esac; done
    cat "$S/ctr_$app" 2>/dev/null
    exit 0 ;;
  rm)
    stubfail rmctr
    echo "MARK ctr" >> "$CALL_LOG"
    [ ! -f "$S/noop_rmctr" ] || exit 0
    name="${*: -1}"
    for f in "$S"/ctr_*; do
      [ -e "$f" ] || continue
      grep -vxF -- "$name" "$f" > "$f.new" || true
      mv "$f.new" "$f"
    done
    exit 0 ;;
  image)
    # image ls: prints every image line regardless of the repository argument (rm-db.sh must filter by itself)
    stubfail imgls
    cat "$S/images" 2>/dev/null
    exit 0 ;;
  rmi)
    stubfail rmi
    [ ! -f "$S/noop_rmi" ] || exit 0
    ref="${*: -1}"
    awk -v ref="$ref" '{ if ($3 != "<none>" && $2 ":" $3 == ref) next; if ($3 == "<none>" && $2 "@" $4 == ref) next; print }' "$S/images" > "$S/images.new"
    mv "$S/images.new" "$S/images"
    exit 0 ;;
  exec)
    shift # -i
    shift # container
    input="$(cat)"
    if [ "$1" = psql ]; then
      printf '### psql\n%s\n' "$input" >> "$S/stdin.log"
      case "$input" in
        *"DROP DATABASE"*)
          stubfail pg-drop-db
          echo "MARK dropdb" >> "$CALL_LOG"
          r="$(sed -n 's/.*DROP DATABASE IF EXISTS "\([a-z0-9_]*\)".*/\1/p' <<<"$input" | head -n 1)"
          [ -f "$S/noop_dropdb" ] || rm -f "$S/db_$r" ;;
        *"DROP ROLE"*)
          stubfail pg-drop-role
          echo "MARK droprole" >> "$CALL_LOG"
          r="$(sed -n 's/.*DROP ROLE IF EXISTS "\([a-z0-9_]*\)".*/\1/p' <<<"$input" | head -n 1)"
          [ -f "$S/noop_droprole" ] || rm -f "$S/role_$r" ;;
        *"count(*) FROM pg_roles"*)
          stubfail pg-final
          r="$(sed -n "s/.*rolname = '\([a-z0-9_]*\)'.*/\1/p" <<<"$input" | head -n 1)"
          n=0; [ ! -f "$S/role_$r" ] || n=1
          d=0; [ ! -f "$S/db_$r" ] || d=1
          echo "$n|$d" ;;
        *) echo "stub: unknown psql input" >&2; exit 97 ;;
      esac
      exit 0
    fi
    [ "$1 $2" = "sh -c" ] || { echo "stub: unexpected redis argv" >&2; exit 98; }
    printf '### redis\n%s\n' "$input" >> "$S/stdin.log"
    case "$input" in
      "EVAL "*)
        stubfail rd-scan
        set -f
        set -- $input
        set +f
        mode="${!#}"
        eval "pat=\${$(($# - 1))}"
        pre="${pat%\*}"
        n=0
        [ "$mode" != del ] || echo "MARK redis-del" >> "$CALL_LOG"
        for f in "$S"/rkey_"$pre"*; do
          [ -e "$f" ] || continue
          n=$((n + 1))
          if [ "$mode" = del ] && [ ! -f "$S/noop_delkeys" ]; then rm -f "$f"; fi
        done
        printf '0\n%s\n' "$n" ;;
      "ACL DELUSER "*)
        stubfail rd-deluser
        echo "MARK deluser" >> "$CALL_LOG"
        u="${input#ACL DELUSER }"
        if [ -f "$S/ruser_$u" ]; then
          [ -f "$S/noop_deluser" ] || rm -f "$S/ruser_$u"
          echo 1
        else
          echo 0
        fi ;;
      "ACL SAVE")
        stubfail rd-save
        echo OK ;;
      "ACL USERS")
        stubfail rd-users
        printf 'default\nadmin\nhealth\n'
        for f in "$S"/ruser_*; do [ ! -e "$f" ] || basename "${f#*ruser_}"; done ;;
      *) echo "stub: unknown redis command" >&2; exit 99 ;;
    esac
    exit 0 ;;
esac
exit 0
EOF

# ---- harness ----

fresh() {
  rm -rf "$STATE" "$SECRETS" "$JOBS" "$DSTATE" "$REG" "$LOCKS" "$RESERVED"
  mkdir -p "$STATE" "$SECRETS" "$JOBS" "$DSTATE" "$REG" "$LOCKS"
  "$REAL_CHMOD" 1777 "$LOCKS"
  cp "$RESERVED_SRC" "$RESERVED"
  : > "$STATE/stdin.log"
  : > "$STATE/images"
  : > "$LOGGER_LOG"
  t_reset_calls
  export RM_DB_TESTING=1
  export RM_DB_SECRETS_ROOT="$SECRETS"
  export RM_DB_JOB_SECRETS_ROOT="$JOBS"
  export RM_DB_STATE_ROOT="$DSTATE"
  export RM_DB_REGISTRY_ROOT="$REG"
  export RM_DB_LOCK_DIR="$LOCKS"
  export RM_DB_RESERVED_NAMES="$RESERVED"
  export RM_DB_PG_CONTAINER="$PGC"
  export RM_DB_REDIS_CONTAINER="$RDC"
  export RM_DB_IMAGE_NS="$NS"
  export RM_DB_AS_DEPLOY="$STUB_BIN/asdeploy"
  unset RM_DB_REDIS_CTR_ADMIN_FILE RM_DB_EXEC_TIMEOUT
}

# seed <app>: every kind of object the app owns
seed() {
  local app="$1" role="${1//-/_}"
  mkdir -p "$SECRETS/$app" "$JOBS/$app" "$DSTATE/$app/current" "$DSTATE/$app/previous" "$REG/$app"
  printf 'x' > "$SECRETS/$app/db-password"
  printf 'x' > "$SECRETS/$app/redis-password"
  printf 'x' > "$JOBS/$app/jobs-secret"
  printf 'v1' > "$DSTATE/$app/current/tag"
  printf 'v0' > "$DSTATE/$app/previous/tag"
  printf 'name: x' > "$REG/$app/app.yaml"
  touch "$STATE/role_$role" "$STATE/db_$role" "$STATE/ruser_$app"
  touch "$STATE/rkey_$app:a" "$STATE/rkey_$app:b:c"
  printf 'id%s %s/%s v1 <none>\nid%s %s/%s v0 <none>\nid%sd %s/%s <none> sha256:aaaa\n' "$app" "$NS" "$app" "${app}0" "$NS" "$app" "$app" "$NS" "$app" >> "$STATE/images"
}

# present <app>: how many kinds of object remain (0 = fully removed)
present() {
  local app="$1" role="${1//-/_}" n=0 f
  for f in "$SECRETS/$app" "$JOBS/$app" "$DSTATE/$app" "$REG/$app" "$STATE/role_$role" "$STATE/db_$role" "$STATE/ruser_$app"; do
    if [ -e "$f" ]; then n=$((n + 1)); fi
  done
  n=$((n + $(find "$STATE" -maxdepth 1 -name "rkey_$app:*" | wc -l)))
  n=$((n + $(grep -c " $NS/$app " "$STATE/images" || true)))
  echo "$n"
}

rd() { run_cmd bash "$script" "$@"; }
docker_calls() { grep -c '^docker ' "$CALL_LOG" || true; }
delete_calls() { grep -c '^asdeploy ' "$CALL_LOG" || true; }
mutations() { grep -E 'DROP|ACL DELUSER|ACL SAVE|DEL' "$STATE/stdin.log" || true; }

# ---- 0. the Redis admin snippet is the same text as new-db.sh's ----

a="$(grep -F 'readonly REDIS_ADMIN_SNIPPET=' "$script")"
b="$(grep -F 'readonly REDIS_ADMIN_SNIPPET=' "$here/new-db.sh")"
if [ -n "$a" ] && [ "$a" = "$b" ]; then _pass; else _fail "rm-db.sh and new-db.sh carry the same REDIS_ADMIN_SNIPPET"; fi

# the image namespace default equals deploy.sh's, so a removal finds what a deploy pulled
ns_rm="$(sed -n 's/^IMAGE_NS="\${RM_DB_IMAGE_NS:-\(.*\)}"$/\1/p' "$script")"
ns_dep="$(sed -n 's/^readonly IMAGE_NS="\(.*\)"$/\1/p' "$here/../deploy/deploy.sh")"
if [ -n "$ns_rm" ] && [ "$ns_rm" = "$ns_dep" ]; then _pass; else _fail "rm-db.sh and deploy.sh use the same image namespace" "rm='$ns_rm' deploy='$ns_dep'"; fi

# ---- 1. usage, names, confirmation: no docker call and nothing changed ----

fresh
seed foo
rd
expect_rc "no argument is a usage error" 2
rd foo
expect_rc "no --confirm is a usage error" 2
rd foo --confirm
expect_rc "--confirm without a value is a usage error" 2
rd foo --confirm foo --confirm foo
expect_rc "a repeated --confirm is a usage error" 2
rd foo --confirm foo extra
expect_rc "an extra argument is a usage error" 2
rd foo --confirm foo --bogus
expect_rc "an unknown flag is a usage error" 2
RM_DB_EXEC_TIMEOUT=abc rd foo --confirm foo
expect_rc "a non-numeric timeout is a usage error" 2
rd foo --confirm bar
expect_rc "a mismatched confirmation exits 1" 1
expect_out_has "the mismatch is named" "does not match"
rd foo --confirm "foo "
expect_rc "a confirmation with a trailing space mismatches" 1
rd foo --confirm FOO
expect_rc "a confirmation in another case mismatches" 1
rd foo --confirm ""
expect_rc "an empty confirmation mismatches" 1
expect_eq "usage and mismatch cases make no docker call" "$(docker_calls)" "0"
expect_eq "usage and mismatch cases make no delete" "$(delete_calls)" "0"
expect_eq "usage and mismatch cases change nothing" "$(present foo)" "12"

refuse_case() { # label name
  fresh
  rd "$2" --confirm "$2"
  expect_rc "refused: $1" 1
  expect_eq "refused, no docker call: $1" "$(docker_calls)" "0"
  expect_eq "refused, no delete: $1" "$(delete_calls)" "0"
}
refuse_case "uppercase" "MyApp"
refuse_case "underscore" "my_app"
refuse_case "leading digit" "1app"
refuse_case "one character" "a"
refuse_case "32 characters" "a$(printf 'b%.0s' $(seq 1 31))"
refuse_case "leading dash" "-app"
refuse_case "a path" "../x"
refuse_case "reserved: admin" "admin"
refuse_case "reserved: default" "default"
refuse_case "reserved: health" "health"
refuse_case "reserved: postgres" "postgres"
refuse_case "pg_ prefix after mapping" "pg-x"
refuse_case "template0" "template0"

# the overrides are test hooks: without RM_DB_TESTING=1 they are dropped with a warning (production paths apply)
fresh
seed foo
run_cmd env -u RM_DB_TESTING RM_DB_RESERVED_NAMES="$RESERVED" bash "$script" foo --confirm foo
expect_out_has "overrides without RM_DB_TESTING=1 are named in a warning" "ignoring test overrides without RM_DB_TESTING=1"
expect_out_has "the warning names the variable" "RM_DB_RESERVED_NAMES"
expect_out_lacks "the warning never prints a value" "$RESERVED"
expect_eq "ignored overrides leave the app untouched" "$(present foo)" "12"
expect_eq "ignored overrides make no docker call" "$(docker_calls)" "0"

for lst in absent dir empty; do
  fresh
  case "$lst" in
    absent) rm -f "$RESERVED" ;;
    dir) rm -f "$RESERVED"; mkdir "$RESERVED" ;;
    empty) printf '# only comments\n' > "$RESERVED" ;;
  esac
  rd foo --confirm foo
  expect_rc "reserved list ($lst) fails closed" 1
  expect_eq "reserved list ($lst) makes no docker call" "$(docker_calls)" "0"
done

# ---- 2. a full removal ----

fresh
seed foo
seed foo-bar
foo_bar_before="$(present foo-bar)"
rd foo --confirm foo
expect_rc "a full removal succeeds" 0
expect_out_has "it reports the end" "rm-db: done foo"
expect_out_has "it says R2 snapshots keep the data" "R2 snapshots keep"
expect_eq "everything of foo is gone" "$(present foo)" "0"
expect_eq "foo-bar (a name that starts with foo) is untouched" "$(present foo-bar)" "$foo_bar_before"
expect_file "foo-bar secrets survive" "$SECRETS/foo-bar/db-password"
expect_file "foo-bar role survives" "$STATE/role_foo_bar"
expect_file "foo-bar Redis keys survive" "$STATE/rkey_foo-bar:a"
expect_eq "another app's images are untouched (rm-db filters by repository itself)" "$(grep -c "$NS/foo-bar " "$STATE/images")" "3"
expect_calls_lacks "no image of foo-bar was removed" "rmi -- $NS/foo-bar"
expect_calls_has "the registry delete ran through the deploy prefix" "asdeploy rm -rf -- $REG/foo"
expect_calls_has "the secrets delete ran through the deploy prefix" "asdeploy rm -rf -- $SECRETS/foo"
expect_calls_has "the job-secrets delete ran through the deploy prefix" "asdeploy rm -rf -- $JOBS/foo"
expect_calls_has "the state delete ran through the deploy prefix" "asdeploy rm -rf -- $DSTATE/foo"
if grep -E '^(rm|asdeploy) ' "$CALL_LOG" | grep -q 'foo-bar'; then _fail "no delete names foo-bar"; else _pass; fi
if grep -qF 'DROP DATABASE IF EXISTS "foo" WITH (FORCE);' "$STATE/stdin.log"; then _pass; else _fail "DROP DATABASE ... WITH (FORCE) was sent"; fi
if grep -qF 'DROP ROLE IF EXISTS "foo";' "$STATE/stdin.log"; then _pass; else _fail "DROP ROLE was sent"; fi
if grep -qF 'ACL DELUSER foo' "$STATE/stdin.log" && grep -qF 'ACL SAVE' "$STATE/stdin.log"; then _pass; else _fail "ACL DELUSER and ACL SAVE were sent"; fi
if grep -qF "foo:*" "$STATE/stdin.log"; then _pass; else _fail "the scan matches foo:* only"; fi
# the order: containers, registry, redis, postgres, secrets/state, images, then the final scans
order="$(grep '^MARK ' "$CALL_LOG" | cut -d' ' -f2 | tr '\n' ' ')"
expect_eq "the steps run in order: registry, Redis, Postgres, then secrets, job-secrets, state" "$order" "registry redis-del deluser dropdb droprole secrets jobsecrets state "
seq_ok=1
last=0
for pat in "^docker ps " "^asdeploy rm -rf -- $REG/foo" "^docker image ls"; do
  ln="$(grep -n -- "$pat" "$CALL_LOG" | head -n 1 | cut -d: -f1)"
  [ -n "$ln" ] && [ "$ln" -gt "$last" ] || seq_ok=0
  last="${ln:-0}"
done
expect_eq "containers come before the registry delete, which comes before the image listing" "$seq_ok" "1"
rd foo --confirm foo
expect_rc "a second removal of the same app is a clean no-op" 0
expect_eq "the second removal leaves foo-bar alone too" "$(present foo-bar)" "$foo_bar_before"

# an app that never existed converges to done
fresh
rd ghost --confirm ghost
expect_rc "removing an app that does not exist succeeds" 0

# ---- 3. containers: a labelled container, including a leftover -old, refuses without --stop ----

fresh
seed foo
printf 'app-foo\napp-foo-old\n' > "$STATE/ctr_foo"
rd foo --confirm foo
expect_rc "labelled containers without --stop refuse" 1
expect_out_has "the refusal names the live container" "app-foo"
expect_out_has "the refusal names the leftover -old" "app-foo-old"
expect_out_has "the refusal points at --stop" "--stop"
expect_eq "refusal changed nothing" "$(present foo)" "12"
expect_eq "refusal removed no container" "$(wc -l < "$STATE/ctr_foo")" "2"
expect_eq "refusal made no delete" "$(delete_calls)" "0"
if [ -n "$(mutations)" ]; then _fail "refusal sent no SQL or ACL text"; else _pass; fi

printf 'app-foo-old\n' > "$STATE/ctr_foo"
rd foo --confirm foo
expect_rc "a leftover -old alone also refuses" 1
expect_eq "the leftover -old alone changed nothing" "$(present foo)" "12"

printf 'app-foo\napp-foo-old\n' > "$STATE/ctr_foo"
rd foo --confirm foo --stop
expect_rc "--stop removes both containers and finishes" 0
expect_eq "no labelled container is left" "$(grep -c . "$STATE/ctr_foo" || true)" "0"
expect_calls_has "the live container was force-removed" "docker rm -f -v -- app-foo"
expect_calls_has "the leftover -old was force-removed" "docker rm -f -v -- app-foo-old"
expect_eq "everything is gone after --stop" "$(present foo)" "0"
fresh
seed foo
printf 'app-foo\n' > "$STATE/ctr_foo"
rd foo --stop --confirm foo
expect_rc "--stop may come before --confirm" 0

# ---- 4. the lock ----

fresh
seed foo
rd foo --confirm foo
expect_rc "a run that creates the lock file succeeds" 0
lock="$LOCKS/foo.lock"
expect_file "the lock file was created" "$lock"
expect_eq "the lock file is created with mode 666 (the deploy user must reopen it)" "$(stat -c '%a' "$lock")" "666"
# new-db.sh and deploy.sh open the lock for append, then flock it: both still work on the file rm-db created
if ( exec 9>>"$lock" && flock -n 9 ); then _pass; else _fail "an append-opened descriptor can take the lock after rm-db"; fi

# a held lock exits 1 and changes nothing
fresh
seed foo
: > "$LOCKS/foo.lock"
( exec 8<"$LOCKS/foo.lock"; flock 8; exec sleep 20 ) &
holder=$!
held=0
for _ in $(seq 1 100); do
  if ! ( exec 7<"$LOCKS/foo.lock"; flock -n 7 ); then held=1; break; fi
  sleep 0.1
done
expect_eq "the background holder took the lock" "$held" "1"
rd foo --confirm foo
expect_rc "a held lock exits 1" 1
expect_out_has "the held lock is named" "holds the lock"
expect_eq "a held lock changed nothing" "$(present foo)" "12"
expect_eq "a held lock made no docker call" "$(docker_calls)" "0"
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
rd foo --confirm foo
expect_rc "after the holder exits the removal succeeds" 0

# a symlink in place of the lock is refused
fresh
seed foo
ln -s "$T_TMP/elsewhere" "$LOCKS/foo.lock"
rd foo --confirm foo
expect_rc "a symlinked lock path is refused" 1
expect_eq "a symlinked lock changed nothing" "$(present foo)" "12"

# a missing data root is refused before any change
fresh
seed foo
rm -rf "$DSTATE"
rd foo --confirm foo
expect_rc "a missing deploy state root is refused" 1
expect_eq "a missing root made no docker call" "$(docker_calls)" "0"

# ---- 5. a rerun after a failure at each step completes ----

fail_case() { # label key exitcode [extra args]
  local label="$1" key="$2" code="$3"
  shift 3
  fresh
  seed foo
  printf 'app-foo-old\n' > "$STATE/ctr_foo"
  echo "$code" > "$STATE/fail_$key"
  rd foo --confirm foo --stop
  expect_rc "failure at $label exits 1" 1
  expect_out_has "failure at $label names the phase" "failed (rc $code)"
  rm -f "$STATE/fail_$key"
  rd foo --confirm foo --stop
  expect_rc "rerun after a failure at $label completes" 0
  expect_eq "rerun after a failure at $label removes everything" "$(present foo)" "0"
}
fail_case "the container listing" ps 3
fail_case "the container removal" rmctr 3
fail_case "the registry/secrets/state delete" files 3
fail_case "the Redis scan" rd-scan 3
fail_case "ACL DELUSER" rd-deluser 3
fail_case "ACL SAVE" rd-save 3
fail_case "DROP DATABASE" pg-drop-db 3
fail_case "DROP ROLE" pg-drop-role 3
fail_case "a timed-out Postgres call" pg-drop-db 124
fail_case "the image listing" imgls 3
fail_case "the secrets delete" files_secrets 3
fail_case "the job-secrets delete" files_jobsecrets 3
fail_case "the deploy-state delete" files_state 3
fail_case "the registry delete" files_registry 3
fail_case "the final Postgres check" pg-final 3
fail_case "the final Redis user list" rd-users 3

# an image that cannot be removed: judged by the final re-scan, and a rerun converges
fresh
seed foo
echo 3 > "$STATE/fail_rmi"
rd foo --confirm foo
expect_rc "failure at the image removal exits 1" 1
expect_out_has "failure at the image removal is named by the re-scan" "images: "
rm -f "$STATE/fail_rmi"
rd foo --confirm foo
expect_rc "rerun after a failure at the image removal completes" 0
expect_eq "rerun after a failure at the image removal removes everything" "$(present foo)" "0"

# a failure after the Redis step must not have touched the secrets (secrets go last)
fresh
seed foo
echo 3 > "$STATE/fail_pg-drop-db"
rd foo --confirm foo
expect_file "secrets survive a failure before the Postgres drop" "$SECRETS/foo/db-password"
expect_file "job secret survives a failure before the Postgres drop" "$JOBS/foo/jobs-secret"
expect_file "the deploy state survives a failure before the Postgres drop" "$DSTATE/foo/current/tag"

# an unhealthy data container stops the removal before any change
fresh
seed foo
echo 1 > "$STATE/fail_health_$RDC"
rd foo --confirm foo
expect_rc "an unhealthy Redis container stops the run" 1
expect_eq "an unhealthy container changed nothing" "$(present foo)" "12"

# ---- 6. the final re-scan exits 1 when any one thing is left ----

left_case() { # label switch expected-text
  fresh
  seed foo
  : > "$STATE/$2"
  rd foo --confirm foo
  expect_rc "left behind: $1 exits 1" 1
  expect_out_has "left behind: $1 is named" "$3"
  expect_out_has "left behind: the re-scan header is printed" "final re-scan"
}
left_case "the registry dir" noop_registry "path: $REG/foo"
left_case "secrets/<app>" noop_secrets "path: $SECRETS/foo"
left_case "job-secrets/<app>" noop_jobsecrets "path: $JOBS/foo"
left_case "the deploy state" noop_state "path: $DSTATE/foo"
left_case "the Redis keys" noop_delkeys "redis keys: 2"
left_case "the Redis user" noop_deluser "redis user: foo"
left_case "the Postgres database" noop_dropdb "postgres database: foo"
left_case "the Postgres role" noop_droprole "postgres role: foo"
left_case "the local images" noop_rmi "images: "

# a labelled container that survives its removal is caught by the final re-scan
fresh
seed foo
printf 'app-foo\n' > "$STATE/ctr_foo"
: > "$STATE/noop_rmctr"
rd foo --confirm foo --stop
expect_rc "left behind: a labelled container exits 1" 1
expect_out_has "left behind: the container is named" "containers: app-foo"

# a clean run with no container passes
fresh
seed foo
rd foo --confirm foo
expect_rc "a clean run with an empty container list passes" 0

# ---- 7. logging ----

fresh
seed foo
rd foo --confirm foo
if grep -qE 'rm-db app=foo phase=registry-rm end rc=0 dur=[0-9]+s' <<<"$out"; then _pass; else _fail "a phase end line carries rc and duration"; fi
if grep -q 'rm-db app=foo end rc=0' "$LOGGER_LOG"; then _pass; else _fail "the audit log (logger) carries the end line"; fi
fresh
seed foo
echo 124 > "$STATE/fail_pg-drop-db"
rd foo --confirm foo
expect_out_has "a timeout names its phase in the log" "phase=postgres-drop-database end rc=124"

# ---- 8. rm-db is unreachable through the dispatcher and the login shell ----

for f in platform.sh login-shell.sh; do
  if grep -q 'rm-db' "$here/../host/$f"; then _fail "$f does not mention rm-db"; else _pass; fi
done

t_finish
