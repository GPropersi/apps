#!/usr/bin/env bash
# test-class: docker
# test_image.sh: builds the final image and runs it the way platform/deploy/deploy.sh does, against a REAL Postgres and
# Redis (the pinned images from platform/data/compose.yaml, the Redis ACL rule from new-db.sh, the Postgres role with
# CONNECTION LIMIT 3).
#
# Proves: the image has exactly one exposed port equal to app.yaml `port`, no labels, a numeric non-root user and no
# `dev` build tag or dev-identity code; the container answers /healthz within deploy's 60 s window; `/` serves the built
# SPA with the CSP header; /api/me and /_jobs/add-note are 401 without credentials; the job runs once per queue_id; the
# app role holds at most 2 connections; the Step 6 `-tags live` Go tests pass against that Redis; and the container exits
# non-zero when ACCESS_AUD is unset.
#
# Needs docker; without a usable docker daemon it skips with a loud notice and exits 0. REQUIRE_DOCKER=1 turns a skip
# into a failure (a skip is not a pass):
#   REQUIRE_DOCKER=1 bash templates/go-react/test_image.sh > /tmp/claude/image.txt 2>&1
#
# Isolation: every container, network, volume and image carries the unique prefix tmpl-<pid>-<random>; everything is
# removed on every exit path. Passwords are throwaway and never leave this run.
#   leftover resources after a killed run -> docker ps -a --filter name=tmpl-   (remove by prefix)
# shellcheck disable=SC1091
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../../platform/test/lib.sh
. "$here/../../platform/test/lib.sh"
# shellcheck source=../../platform/lib/yaml-subset.sh
. "$here/../../platform/lib/yaml-subset.sh"
# shellcheck source=../../platform/jobs/go-env.sh
. "$here/../../platform/jobs/go-env.sh" || { echo "test_image: FAIL: the pinned Go toolchain is not usable"; exit 1; }
platform_dir="$here/../../platform"

skip() {
  if [ "${REQUIRE_DOCKER:-0}" = 1 ]; then
    echo "FAIL: $(basename "$0"): $1 (REQUIRE_DOCKER=1 turns a skip into a failure)"
    exit 1
  fi
  echo "################################################################"
  echo "## $(basename "$0") SKIPPED: $1"
  echo "## The image run against real Postgres and Redis did NOT happen. Run it on a docker host before merge (REQUIRE_DOCKER=1)."
  echo "################################################################"
  exit 0
}

command -v docker > /dev/null 2>&1 || skip "docker is not installed"
docker info > /dev/null 2>&1 || skip "the docker daemon is not reachable by this user"
command -v curl > /dev/null 2>&1 || { echo "FAIL: test_image: curl is not installed"; exit 1; }

t_init

rid="tmpl-$$-$RANDOM"
NET="$rid-net"
PGC="$rid-pg"
RDC="$rid-redis"
APPC="$rid-app"
NOAUDC="$rid-noaud"
IMG="$rid-img"
vol="$rid-redis-data"
sec="$(mktemp -d)"

cleanup() {
  docker rm -fv "$APPC" "$NOAUDC" "$PGC" "$RDC" "$rid-extract" > /dev/null 2>&1
  docker network rm "$NET" > /dev/null 2>&1
  docker volume rm -f "$vol" > /dev/null 2>&1
  docker image rm -f "$IMG" > /dev/null 2>&1
  rm -rf -- "$sec"
  t_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$1"; }

# ---- app.yaml and the data stack definition ----

flat="$T_TMP/app-flat"
ys_flatten < "$here/app.yaml" > "$flat" || { echo "FAIL: app.yaml is outside the YAML subset the tests understand"; exit 1; }
app="$(ys_get "$flat" name)"
port="$(ys_get "$flat" port)"
memcap="$(ys_get "$flat" memory_cap)"
[[ "$app" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { echo "FAIL: cannot read a valid name from app.yaml (got '$app')"; exit 1; }
[[ "$port" =~ ^[0-9]+$ ]] || { echo "FAIL: cannot read port from app.yaml (got '$port')"; exit 1; }
[[ "$memcap" =~ ^[0-9]+m$ ]] || { echo "FAIL: cannot read memory_cap from app.yaml (got '$memcap')"; exit 1; }
pgrole="${app//-/_}"

dflat="$T_TMP/compose-flat"
ys_flatten < "$platform_dir/data/compose.yaml" > "$dflat" || { echo "FAIL: platform/data/compose.yaml is outside the YAML subset"; exit 1; }
pgimg="$(ys_get "$dflat" services/postgres/image)"
rdimg="$(ys_get "$dflat" services/redis/image)"
[ -n "$pgimg" ] && [ -n "$rdimg" ] || { echo "FAIL: cannot read the postgres and redis images from compose.yaml"; exit 1; }
mapfile -t flags < <(awk '/^  redis:/{r=1} r&&/^    command:/{c=1;next} c&&/^      - /{sub(/^      - /,""); gsub(/"/,""); print; next} c{exit}' "$platform_dir/data/compose.yaml")
[ "${#flags[@]}" -ge 8 ] || { echo "FAIL: cannot read the redis command flags from compose.yaml (got ${#flags[@]})"; exit 1; }

pull_if_missing() {
  if ! docker image inspect "$1" > /dev/null 2>&1; then
    if ! timeout 300 docker pull -q "$1" > /dev/null 2> "$T_TMP/pull-err"; then
      cat "$T_TMP/pull-err"
      skip "cannot pull $1 (image pull failure: offline or rate-limited, not a code failure)"
    fi
  fi
}
pull_if_missing "$pgimg"
pull_if_missing "$rdimg"

# ---- build the final image ----

echo "test_image: docker build (final stage)"
if timeout 900 docker build --tag "$IMG" "$here" > "$T_TMP/build.txt" 2>&1; then
  _pass
else
  echo "FAIL: docker build of the final image"
  tail -n 60 "$T_TMP/build.txt"
  exit 1
fi

# ---- the image passes deploy.sh's inspect rules, and carries no dev code ----

ports="$(docker image inspect --format '{{range $p, $_ := .Config.ExposedPorts}}{{$p}} {{end}}' "$IMG")"
expect_eq "exactly one exposed port, equal to app.yaml port" "${ports% }" "$port/tcp"
labels="$(docker image inspect --format '{{len .Config.Labels}}' "$IMG")"
expect_eq "the image has no labels" "$labels" 0
imguser="$(docker image inspect --format '{{.Config.User}}' "$IMG")"
if [[ "$imguser" =~ ^[0-9]+(:[0-9]+)?$ ]] && [[ ! "${imguser%%:*}" =~ ^0+$ ]]; then _pass; else _fail "the image user is numeric and non-root" "got '$imguser'"; fi
expect_eq "the image user is 65532:65532" "$imguser" "65532:65532"

docker create --name "$rid-extract" "$IMG" > /dev/null || { echo "FAIL: docker create for the binary extract"; exit 1; }
docker cp "$rid-extract:/server" "$T_TMP/server" > /dev/null || { echo "FAIL: cannot copy /server out of the image"; exit 1; }
docker rm -f "$rid-extract" > /dev/null 2>&1
modinfo="$(go version -m "$T_TMP/server" 2>&1)"
expect_out_has_text "$modinfo" "CGO_ENABLED=0" "go version -m reads the binary (build settings are listed)"
if grep -qE '^\s+build\s+-tags=' <<< "$modinfo"; then _fail "the binary was built with -tags" "$(grep -E 'build\s+-tags' <<< "$modinfo")"; else _pass; fi
if grep -aq 'ACCESS_DEV_EMAIL' "$T_TMP/server"; then _fail "the dev identity code (ACCESS_DEV_EMAIL) is compiled into the image"; else _pass; fi

# ---- Postgres and Redis ----

docker network create "$NET" > /dev/null || { echo "FAIL: network create"; exit 1; }

pg_admin_pw="$(rand 24)"
db_pw="$(rand 40)"
redis_admin_pw="$(rand 24)"
redis_app_pw="$(rand 40)"
jobs_secret="$(rand 40)"

docker run -d --name "$PGC" --network "$NET" -e "POSTGRES_PASSWORD=$pg_admin_pw" "$pgimg" > /dev/null || { echo "FAIL: postgres start"; exit 1; }
docker volume create "$vol" > /dev/null || { echo "FAIL: volume create"; exit 1; }
hash="$(printf '%s' "$redis_admin_pw" | sha256sum | cut -d ' ' -f 1)"
{
  printf 'user default off\n'
  printf 'user admin on #%s ~* &* +@all\n' "$hash"
  printf 'user health on nopass -@all +ping\n'
} > "$T_TMP/users.acl"
docker run --rm -i -v "$vol:/data" --entrypoint sh "$rdimg" -c 'cat > /data/users.acl && chown 999:999 /data/users.acl && chmod 600 /data/users.acl' < "$T_TMP/users.acl" \
  || { echo "FAIL: seeding users.acl"; exit 1; }
docker run -d --name "$RDC" --network "$NET" -p 127.0.0.1::6379 -v "$vol:/data" "$rdimg" "${flags[@]}" > /dev/null || { echo "FAIL: redis start"; exit 1; }

pgsql() { docker exec -i "$PGC" psql -X -h 127.0.0.1 -U postgres -At -v ON_ERROR_STOP=1 "$@" 2>&1; }
rdadmin() { docker exec -i -e REDISCLI_AUTH="$redis_admin_pw" "$RDC" redis-cli --user admin --no-auth-warning "$@" 2>&1 < /dev/null; }

ready=0
for _ in $(seq 1 90); do
  if [ "$(pgsql -c 'select 1' < /dev/null)" = 1 ]; then ready=1; break; fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then echo "FAIL: postgres did not become ready"; docker logs "$PGC" 2>&1 | tail -n 15; exit 1; fi
ready=0
for _ in $(seq 1 60); do
  if [ "$(docker exec "$RDC" redis-cli --user health --pass x --no-auth-warning ping 2> /dev/null)" = PONG ]; then ready=1; break; fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then echo "FAIL: redis did not become ready"; docker logs "$RDC" 2>&1 | tail -n 15; exit 1; fi

# The app role and database, as new-db.sh creates them (CONNECTION LIMIT 3, owner of its own database).
out="$(pgsql <<< "CREATE ROLE \"$pgrole\" LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 3 PASSWORD '$db_pw';
CREATE DATABASE \"$pgrole\" OWNER \"$pgrole\";")"
expect_out_has_text "$out" "CREATE DATABASE" "the app role and database were created"

# The app's Redis user: the rule new-db.sh builds, read from the real script.
# shellcheck disable=SC2016
app_rule="$(sed -n 's/^  rule="ACL SETUSER \$APP \(.*\)"$/\1/p' "$platform_dir/data/new-db.sh")"
[ -n "$app_rule" ] || { echo "FAIL: cannot read the app ACL rule from new-db.sh"; exit 1; }
r="${app_rule//\$REDIS_PW/$redis_app_pw}"
r="${r//\$APP/$app}"
set -f
# shellcheck disable=SC2086
out="$(rdadmin ACL SETUSER "$app" $r)"
set +f
expect_eq "applying the new-db.sh rule for the app user" "$out" OK

# ---- secret files (readable by uid 65532; throwaway values) ----

mkdir -p "$sec/secrets" "$sec/job-secrets"
printf '%s' "$db_pw" > "$sec/secrets/db-password"
printf '%s' "$redis_app_pw" > "$sec/secrets/redis-password"
printf '%s' "$jobs_secret" > "$sec/job-secrets/jobs-secret"
chmod 755 "$sec" "$sec/secrets" "$sec/job-secrets"
chmod 644 "$sec/secrets/"* "$sec/job-secrets/"*

fake_aud="$(printf '%064d' 0)"

# run_app <name> <publish: yes|no> [extra docker run args before the image]: deploy.sh's flags and environment.
run_app() {
  local name="$1" publish="$2" extra=()
  shift 2
  [ "$publish" = yes ] && extra+=(-p "127.0.0.1::$port")
  docker run -d --name "$name" --label "platform.app=$app" --network "$NET" \
    --group-add 64323 --group-add 64324 --cap-drop ALL --security-opt no-new-privileges:true --read-only --tmpfs /tmp \
    --memory "$memcap" --memory-swap "$memcap" --pids-limit 256 \
    -v "$sec/secrets:/run/platform/secrets:ro" -v "$sec/job-secrets:/run/platform/job-secrets:ro" \
    -e "DB_HOST=$PGC" -e "DB_PORT=5432" -e "DB_NAME=$pgrole" -e "DB_USER=$pgrole" \
    -e "DB_PASSWORD_FILE=/run/platform/secrets/db-password" \
    -e "REDIS_HOST=$RDC" -e "REDIS_PORT=6379" -e "REDIS_USER=$app" \
    -e "REDIS_PASSWORD_FILE=/run/platform/secrets/redis-password" -e "REDIS_KEY_PREFIX=$app:" \
    -e "JOBS_SECRET_FILE=/run/platform/job-secrets/jobs-secret" \
    -e "ACCESS_TEAM_DOMAIN=placeholder.cloudflareaccess.com" \
    "${extra[@]+"${extra[@]}"}" "$@" "$IMG"
}

# ---- run the app and wait for /healthz (deploy's health window is 60 s from container start) ----

if ! run_app "$APPC" yes -e "ACCESS_AUD=$fake_aud" > "$T_TMP/run-out" 2>&1; then
  echo "FAIL: docker run of the app"; cat "$T_TMP/run-out"; exit 1
fi
hostport="$(docker port "$APPC" "$port/tcp" | head -n 1)"
[ -n "$hostport" ] || { echo "FAIL: no published port for the app container"; exit 1; }
base="http://$hostport"

started=$SECONDS
healthy=0
while [ $((SECONDS - started)) -lt 60 ]; do
  if [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$base/healthz")" = 200 ]; then healthy=1; break; fi
  if [ "$(docker inspect --format '{{.State.Status}}' "$APPC" 2> /dev/null)" != running ]; then break; fi
  sleep 1
done
if [ "$healthy" -ne 1 ]; then
  echo "FAIL: /healthz was not 200 within 60 s of container start (state: $(docker inspect --format '{{.State.Status}} exit={{.State.ExitCode}}' "$APPC" 2>&1))"
  docker logs "$APPC" 2>&1 | tail -n 30
  exit 1
fi
_pass
echo "test_image: /healthz 200 after $((SECONDS - started)) s"

expect_eq "the container runs as 65532:65532" "$(docker inspect --format '{{.Config.User}}' "$APPC")" "65532:65532"
expect_eq "the root filesystem is read-only" "$(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$APPC")" true

# ---- HTTP probes ----

hdrs="$T_TMP/root-headers"
body="$T_TMP/root-body"
code="$(curl -s -D "$hdrs" -o "$body" -w '%{http_code}' --max-time 5 "$base/")"
expect_eq "GET / is 200" "$code" 200
if grep -qi '^content-security-policy: ' "$hdrs"; then _pass; else _fail "GET / carries the Content-Security-Policy header" "$(cat "$hdrs")"; fi
if grep -qi '^content-type: text/html' "$hdrs"; then _pass; else _fail "GET / is text/html" "$(cat "$hdrs")"; fi
if grep -qi '<!doctype html' "$body" && grep -q '/assets/' "$body"; then _pass; else _fail "GET / serves the built index.html (not the placeholder)" "$(head -c 400 "$body")"; fi

expect_eq "GET /api/me without a JWT is 401" "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$base/api/me")" 401

job_body() { # <queue_id>
  printf '{"v":1,"run_id":"run-%s","job":"add-note","trigger":"queue","attempt":1,"scheduled_for":null,"queue_id":"%s","enqueued_at":null,"payload":{}}' "$1" "$1"
}
jobs_url="$base/_jobs/add-note"
expect_eq "POST /_jobs/add-note without a bearer is 401" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Content-Type: application/json' -d "$(job_body q1)" "$jobs_url")" 401
expect_eq "POST /_jobs/add-note with a wrong bearer is 401" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Content-Type: application/json' -H 'Authorization: Bearer wrong' -d "$(job_body q1)" "$jobs_url")" 401
expect_eq "no item exists before an authorized job call" "$(pgsql -d "$pgrole" -c 'select count(*) from items' < /dev/null)" 0

post_job() { # <queue_id>
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $jobs_secret" -d "$(job_body "$1")" "$jobs_url"
}
expect_eq "POST /_jobs/add-note with the bearer is 200" "$(post_job 01TESTQUEUEID00000000000001)" 200
expect_eq "one items row after the first delivery" "$(pgsql -d "$pgrole" -c "select count(*) from items where source = 'task'" < /dev/null)" 1
expect_eq "the same queue_id again is 200" "$(post_job 01TESTQUEUEID00000000000001)" 200
expect_eq "still one items row after the redelivery" "$(pgsql -d "$pgrole" -c "select count(*) from items where source = 'task'" < /dev/null)" 1

conns="$(pgsql -c "select count(*) from pg_stat_activity where usename = '$pgrole'" < /dev/null)"
if [[ "$conns" =~ ^[0-9]+$ ]] && [ "$conns" -ge 1 ] && [ "$conns" -le 2 ]; then _pass; else _fail "the app role holds 1 or 2 connections (at most 2)" "got '$conns'"; fi

# ---- the Step 6 live Go tests against the same Redis ----

rdport="$(docker port "$RDC" 6379/tcp | head -n 1)"
[ -n "$rdport" ] || { echo "FAIL: no published port for $RDC"; exit 1; }
export CGO_ENABLED=1
export TLIVE_ADDR="$rdport" TLIVE_ADMIN_PW="$redis_admin_pw" TLIVE_APP="$app" TLIVE_APP_PW="$redis_app_pw" TLIVE_ALLOW_FLUSH=1
echo "test_image: go$GO_VERSION, go test -tags live against $rdimg"
if (cd "$here" && go test -tags live -race -count=1 -timeout 4m ./internal/platform/ -run Live -v) > "$T_TMP/go-live.txt" 2>&1; then
  _pass
else
  _fail "go test -tags live (build or test failure)" "$(grep -E '^(\s*--- FAIL|panic:|FAIL|\s+[a-z_]+_test\.go:[0-9]+:)' "$T_TMP/go-live.txt" | tail -n 30; echo '--- tail ---'; tail -n 25 "$T_TMP/go-live.txt")"
fi
if grep -q -- '--- SKIP' "$T_TMP/go-live.txt"; then _fail "a live test was skipped (a skip is not a pass)" "$(grep -- '--- SKIP' "$T_TMP/go-live.txt")"; fi
live_passed="$(grep -c -E '^--- PASS: TestLive' "$T_TMP/go-live.txt")"
echo "test_image: $live_passed live tests passed"
if [ "$live_passed" -ge 3 ]; then _pass; else _fail "fewer than 3 live tests passed ($live_passed): the live tests did not really run"; fi

# ---- missing Access settings make the container exit, not serve ----

if ! run_app "$NOAUDC" no > "$T_TMP/noaud-run" 2>&1; then
  echo "FAIL: docker run without ACCESS_AUD"; cat "$T_TMP/noaud-run"; exit 1
fi
exit_code="$(timeout 40 docker wait "$NOAUDC" 2> /dev/null)"
if [[ "$exit_code" =~ ^[0-9]+$ ]] && [ "$exit_code" -ne 0 ]; then _pass; else _fail "the container exits non-zero when ACCESS_AUD is unset" "docker wait gave '$exit_code'"; fi
if docker logs "$NOAUDC" 2>&1 | grep -q 'ACCESS_AUD'; then _pass; else _fail "the exit log names the missing ACCESS_AUD key" "$(docker logs "$NOAUDC" 2>&1 | tail -n 5)"; fi

t_finish
