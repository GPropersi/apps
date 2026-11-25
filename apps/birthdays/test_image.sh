#!/usr/bin/env bash
# test-class: docker
# test_image.sh: builds the final image and runs it the way platform/deploy/deploy.sh does, against a REAL Postgres and
# Redis (the pinned images from platform/data/compose.yaml, the Redis ACL rule from new-db.sh, the Postgres role with
# CONNECTION LIMIT 3).
#
# Proves: the image has exactly one exposed port equal to app.yaml `port`, no labels, a numeric non-root user and no
# `dev` build tag or dev-identity code; the container answers /healthz within deploy's 60 s window; `/` serves the built
# SPA with the CSP header; /api/me and /_jobs/reminder-scan are 401 without credentials; the reminder jobs fail loudly
# (and record nothing) while notifs is unconfigured, then the scan queues one deduped send-reminder per seeded due
# reminder on the real Redis; the migrated schema's rules hold against the real Postgres (CHECKs reject Feb 30, Feb 29 in a common year,
# a bad year and bad offsets and accept Feb 29 with no year; deleting a birthday or a user cascades; the shipped
# access-rule queries return a viewer only their own and shared birthdays); the app role holds at most 2 connections;
# the Step 6 `-tags live` Go tests pass against that Redis; and the container exits non-zero when ACCESS_AUD is unset.
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

# The binary carries its own zoneinfo (platform.ScheduleZone needs America/Los_Angeles). distroless/static ships zoneinfo
# and a dev host's go test passes either way, so neither proves the `time/tzdata` import is still there: the package
# must be in the server's dependency list, and the zone table it embeds (a zone name no other part of the binary
# carries) must be in the binary built above, which is the stripped Dockerfile output.
if deps="$(cd "$here" && go list -deps ./cmd/server 2> "$T_TMP/go-list-err")"; then
  if grep -qx 'time/tzdata' <<< "$deps"; then _pass; else _fail "the server does not import time/tzdata (go list -deps ./cmd/server)"; fi
else
  _fail "go list -deps ./cmd/server" "$(cat "$T_TMP/go-list-err")"
fi
if grep -aq 'Antarctica/Troll' "$T_TMP/server"; then _pass; else _fail "the built binary does not embed the time/tzdata zoneinfo (no zone-name table in it)"; fi

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

job_body() { # <job> <queue_id>
  printf '{"v":1,"run_id":"run-%s","job":"%s","trigger":"queue","attempt":1,"scheduled_for":null,"queue_id":"%s","enqueued_at":null,"payload":{}}' "$2" "$1" "$2"
}
post_job() { # <job> <queue_id> [bearer]
  local auth=()
  [ -n "${3:-}" ] && auth=(-H "Authorization: Bearer $3")
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST -H 'Content-Type: application/json' \
    "${auth[@]+"${auth[@]}"}" -d "$(job_body "$1" "$2")" "$base/_jobs/$1"
}
for job in reminder-scan send-reminder; do
  expect_eq "POST /_jobs/$job without a bearer is 401" "$(post_job "$job" q1)" 401
  expect_eq "POST /_jobs/$job with a wrong bearer is 401" "$(post_job "$job" q1 wrong)" 401
done
expect_eq "POST /_jobs/add-note (the removed template job) is not a job" \
  "$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $jobs_secret" -d "$(job_body add-note q1)" "$base/_jobs/add-note")" 404

# ---- the schema's rules against the real Postgres (the app ran the migration at startup) ----

db() { pgsql -d "$pgrole" "$@"; }
dbq() { db -c "$1" < /dev/null; }
# gen_query <const name in db/queries.sql.go> <$1> [<$2> [<$3>]]: the shipped SQL text with its positional parameters filled.
gen_query() {
  local n="$1" sql
  shift
  sql="$(awk -v n="$n" '$0 ~ "^const " n " = `" { f = 1; next } f && /^`$/ { exit } f { print }' "$here/internal/app/db/queries.sql.go")"
  [ -n "$sql" ] || { echo "FAIL: cannot read $n from db/queries.sql.go"; exit 1; }
  local i=1 v
  for v in "$@"; do
    sql="${sql//\$$i/$v}"
    i=$((i + 1))
  done
  printf '%s' "$sql"
}
# rejects <what> <constraint name> <sql>: the statement fails and the error names the constraint.
rejects() {
  local out
  out="$(db -c "$3" < /dev/null)"
  if grep -q "violates check constraint \"$2\"" <<< "$out"; then _pass; else _fail "$1 is rejected by $2" "$out"; fi
}

if ! seed_out="$(db <<< "INSERT INTO users (email) VALUES ('owner@example.test'), ('friend@example.test'), ('other@example.test');")"; then
  echo "FAIL: seeding users"; echo "$seed_out"; exit 1
fi
owner_id="$(dbq "SELECT id FROM users WHERE email = 'owner@example.test'")"
friend_id="$(dbq "SELECT id FROM users WHERE email = 'friend@example.test'")"
other_id="$(dbq "SELECT id FROM users WHERE email = 'other@example.test'")"
[[ "$owner_id" =~ ^[0-9]+$ && "$friend_id" =~ ^[0-9]+$ && "$other_id" =~ ^[0-9]+$ ]] || { echo "FAIL: user ids ($owner_id/$friend_id/$other_id)"; exit 1; }

ins() { echo "INSERT INTO birthdays (owner_id, name, month, day, year) VALUES ($owner_id, 'T', $1, $2, $3)"; }
rejects "Feb 30" birthdays_day_valid "$(ins 2 30 NULL)"
rejects "Apr 31" birthdays_day_valid "$(ins 4 31 NULL)"
rejects "Feb 29 2023 (a common year)" birthdays_feb29_year_leap "$(ins 2 29 2023)"
rejects "Feb 29 1900 (not a leap year)" birthdays_feb29_year_leap "$(ins 2 29 1900)"
rejects "month 13" birthdays_month_check "$(ins 13 1 NULL)"
rejects "year 1899" birthdays_year_check "$(ins 1 1 1899)"
rejects "year 2201" birthdays_year_check "$(ins 1 1 2201)"
rejects "an upper-case user email" users_email_check "INSERT INTO users (email) VALUES ('Mixed@Example.test')"
expect_eq "Feb 29 with no year is accepted" "$(dbq "$(ins 2 29 NULL) RETURNING 'ok'" | head -n 1)" ok
expect_eq "Feb 29 2024 (a leap year) is accepted" "$(dbq "$(ins 2 29 2024) RETURNING 'ok'" | head -n 1)" ok
expect_eq "Feb 29 2000 (divisible by 400) is accepted" "$(dbq "$(ins 2 29 2000) RETURNING 'ok'" | head -n 1)" ok
dbq "DELETE FROM birthdays" > /dev/null

# The Go validator and the table CHECKs must agree on every date: the Go test emits the fixture's validDate rows plus a
# sweep (month -1..14, day -1..33, years around the century and leap rules) with ValidDate's answer, and each tuple is
# inserted for real; the insert is accepted exactly when Go says valid.
sweep="$T_TMP/date-sweep.sql"
if (cd "$here" && DATE_SWEEP_OUT="$sweep" go test -count=1 -run TestEmitValidDateSweepForTheDatabaseCheck ./internal/app/) > "$T_TMP/go-sweep.txt" 2>&1 && [ -s "$sweep" ]; then _pass; else _fail "emitting the date sweep from the Go validator" "$(tail -n 20 "$T_TMP/go-sweep.txt")"; fi
sweep_rows="$(grep -c '^(' "$sweep")"
if [ "$sweep_rows" -ge 1000 ]; then _pass; else _fail "the date sweep has at least 1000 rows (got $sweep_rows)"; fi
{
  printf 'CREATE TEMP TABLE vec (id serial PRIMARY KEY, m int, d int, y int, want boolean, got boolean);\n'
  printf 'INSERT INTO vec (m, d, y, want) VALUES\n'
  sed '$ s/,$//' "$sweep"
  printf ';\n'
  # shellcheck disable=SC2016
  printf 'DO $do$ DECLARE r record; BEGIN FOR r IN SELECT * FROM vec ORDER BY id LOOP BEGIN\n'
  printf "INSERT INTO birthdays (owner_id, name, month, day, year) VALUES (%s, 'sweep', r.m, r.d, r.y);\n" "$owner_id"
  printf 'UPDATE vec SET got = true WHERE id = r.id;\n'
  # shellcheck disable=SC2016
  printf 'EXCEPTION WHEN check_violation THEN UPDATE vec SET got = false WHERE id = r.id; END; END LOOP; END $do$;\n'
  printf 'SELECT count(*) FROM vec WHERE got IS DISTINCT FROM want;\n'
  printf "SELECT count(*) FROM vec WHERE got;\n"
  printf "DELETE FROM birthdays WHERE name = 'sweep';\n"
} > "$T_TMP/sweep-run.sql"
sweep_out="$(db < "$T_TMP/sweep-run.sql")"
sweep_counts="$(grep -E '^[0-9]+$' <<< "$sweep_out")" # the two SELECT counts; command tags are not bare numbers
expect_eq "the DB CHECKs disagree with the Go validator on 0 of $sweep_rows dates" "$(sed -n '1p' <<< "$sweep_counts")" 0
accepted="$(sed -n '2p' <<< "$sweep_counts")"
if [[ "$accepted" =~ ^[0-9]+$ ]] && [ "$accepted" -ge 100 ]; then _pass; else _fail "the sweep accepted at least 100 dates (the comparison really ran)" "$sweep_out"; fi

# Fixture: owner has a shared and an unshared birthday; other has one of their own.
if ! seed_out="$(db <<< "INSERT INTO birthdays (id, owner_id, name, month, day, year) VALUES
  (101, $owner_id, 'Shared with friend', 3, 1, 1990),
  (102, $owner_id, 'Owner private', 4, 2, NULL),
  (103, $other_id, 'Other private', 5, 3, NULL);
INSERT INTO birthday_shares (birthday_id, email) VALUES (101, 'friend@example.test');
INSERT INTO reminder_settings (birthday_id, user_id, offsets) VALUES (101, $friend_id, '{7,1}'), (101, $owner_id, '{0}');
INSERT INTO gift_ideas (birthday_id, author_id, text, shared) VALUES (101, $friend_id, 'a book', true), (101, $friend_id, 'secret', false), (101, $owner_id, 'owner idea', false);
INSERT INTO reminders_sent (birthday_id, user_id, occurrence, offset_days, outcome) VALUES (101, $friend_id, '2026-03-01', 1, 'skipped');")"; then
  echo "FAIL: seeding birthdays"; echo "$seed_out"; exit 1
fi

rejects "reminder offsets {2}" reminder_settings_offsets_check "UPDATE reminder_settings SET offsets = '{2}' WHERE birthday_id = 101 AND user_id = $owner_id"
rejects "empty reminder offsets" reminder_settings_offsets_check "UPDATE reminder_settings SET offsets = '{}' WHERE birthday_id = 101 AND user_id = $owner_id"
rejects "a share with an upper-case email" birthday_shares_email_check "INSERT INTO birthday_shares (birthday_id, email) VALUES (102, 'Friend@Example.test')"

# The access rule, run from the shipped query text: a viewer sees owned + shared birthdays and nothing else.
list_ids() { db -c "$(gen_query listViewerBirthdays "$1" "'$2'") " < /dev/null | cut -d '|' -f 1 | paste -sd ',' -; }
expect_eq "the owner's list is their two birthdays" "$(list_ids "$owner_id" owner@example.test)" "101,102"
expect_eq "a friend's list is only the shared birthday" "$(list_ids "$friend_id" friend@example.test)" "101"
expect_eq "an unrelated user's list is only their own" "$(list_ids "$other_id" other@example.test)" "103"
expect_eq "a share is matched by email, not by id" "$(list_ids "$other_id" friend@example.test)" "101,103"
get_ids() { db -c "$(gen_query getViewerBirthday "$1" "$2" "'$3'") " < /dev/null | cut -d '|' -f 1 | paste -sd ',' -; }
expect_eq "GetViewerBirthday: a friend gets the shared birthday" "$(get_ids "$friend_id" 101 friend@example.test)" "101"
expect_eq "GetViewerBirthday: a friend gets nothing for an unshared birthday" "$(get_ids "$friend_id" 102 friend@example.test)" ""
expect_eq "GetViewerBirthday: an unrelated user gets nothing for the owner's birthday" "$(get_ids "$other_id" 101 other@example.test)" ""
expect_eq "the friend's own reminder offsets come back" "$(db -c "$(gen_query listViewerBirthdays "$friend_id" "'friend@example.test'") " < /dev/null | cut -d '|' -f 8)" "{7,1}"

# The projected columns: is_mine, owner_email and the viewer's own offsets ({} when reminders are off).
list_row() { db -c "$(gen_query listViewerBirthdays "$1" "'$2'") " < /dev/null | grep "^$3|"; }
expect_eq "owner's row for the shared birthday" "$(list_row "$owner_id" owner@example.test 101)" "101|Shared with friend|3|1|1990|t|owner@example.test|{0}"
expect_eq "owner's row for the private birthday (no reminder row = {})" "$(list_row "$owner_id" owner@example.test 102)" "102|Owner private|4|2||t|owner@example.test|{}"
expect_eq "the friend's row for the shared birthday (not theirs)" "$(list_row "$friend_id" friend@example.test 101)" "101|Shared with friend|3|1|1990|f|owner@example.test|{7,1}"

# Cascades. Deleting a user removes what hangs off the user FK (their settings, gifts, destinations, sent records) while
# the birthday they were shared on survives; deleting a birthday removes its shares, settings, gifts and sent records.
state() { dbq "SELECT (SELECT count(*) FROM birthday_shares) || ',' || (SELECT count(*) FROM reminder_settings) || ',' || (SELECT count(*) FROM gift_ideas) || ',' || (SELECT count(*) FROM reminders_sent) || ',' || (SELECT count(*) FROM destinations)"; }
dbq "INSERT INTO destinations (user_id, notifs_id, kind, label, hint) VALUES ($other_id, 1, 'discord', 'x', 'abc')" > /dev/null
expect_eq "the fixture rows exist before any delete (shares,settings,gifts,sent,destinations)" "$(state)" "1,2,3,1,1"
dbq "DELETE FROM users WHERE id = $friend_id" > /dev/null
expect_eq "deleting a user cascades to their settings, gifts and sent records but not to the shared birthday" "$(state)" "1,1,1,0,1"
expect_eq "the birthday the deleted user was shared on survives" "$(dbq "SELECT count(*) FROM birthdays WHERE id = 101")" 1
dbq "DELETE FROM birthdays WHERE id = 101" > /dev/null
expect_eq "deleting a birthday cascades to shares, settings, gifts and sent records" "$(state)" "0,0,0,0,1"
dbq "DELETE FROM users WHERE id = $other_id" > /dev/null
expect_eq "deleting a user cascades to their birthdays and destinations" \
  "$(dbq "SELECT (SELECT count(*) FROM birthdays WHERE owner_id = $other_id) || ',' || (SELECT count(*) FROM destinations)")" "0,0"
expect_eq "other users' birthdays survive" "$(dbq "SELECT count(*) FROM birthdays WHERE owner_id = $owner_id")" 1

# ---- sharing, gifts, reminders and settings: the shipped SQL against real Postgres (fakeStore cannot catch a wrong JOIN) ----

if ! seed_out="$(db <<< "INSERT INTO users (email) VALUES ('s5owner@example.test'), ('s5friend@example.test'), ('s5stranger@example.test');")"; then
  echo "FAIL: seeding the sharing fixture users"; echo "$seed_out"; exit 1
fi
o5="$(dbq "SELECT id FROM users WHERE email = 's5owner@example.test'")"
f5="$(dbq "SELECT id FROM users WHERE email = 's5friend@example.test'")"
x5="$(dbq "SELECT id FROM users WHERE email = 's5stranger@example.test'")"
[[ "$o5" =~ ^[0-9]+$ && "$f5" =~ ^[0-9]+$ && "$x5" =~ ^[0-9]+$ ]] || { echo "FAIL: sharing fixture user ids ($o5/$f5/$x5)"; exit 1; }
fe=s5friend@example.test

# Birthday 201 is the owner's, shared with the friend; the friend has reminders and two ideas, the owner one reminder and two ideas.
seed5() {
  if ! out="$(db <<< "DELETE FROM birthdays WHERE id = 201;
INSERT INTO birthdays (id, owner_id, name, month, day, year) VALUES (201, $o5, 'S5', 6, 7, NULL);
INSERT INTO birthday_shares (birthday_id, email) VALUES (201, '$fe');
INSERT INTO reminder_settings (birthday_id, user_id, offsets) VALUES (201, $f5, '{7,1}'), (201, $o5, '{1}');
INSERT INTO gift_ideas (birthday_id, author_id, text, shared) VALUES (201, $f5, 'f-private', false), (201, $f5, 'f-shared', true), (201, $o5, 'o-private', false), (201, $o5, 'o-shared', true);")"; then
    echo "FAIL: seeding birthday 201"; echo "$out"; exit 1
  fi
}
# state5: shares, friend reminders, friend ideas, owner reminders, owner ideas (all on birthday 201).
state5() {
  dbq "SELECT (SELECT count(*) FROM birthday_shares WHERE birthday_id = 201) || ',' || (SELECT count(*) FROM reminder_settings WHERE birthday_id = 201 AND user_id = $f5) || ',' || (SELECT count(*) FROM gift_ideas WHERE birthday_id = 201 AND author_id = $f5) || ',' || (SELECT count(*) FROM reminder_settings WHERE birthday_id = 201 AND user_id = $o5) || ',' || (SELECT count(*) FROM gift_ideas WHERE birthday_id = 201 AND author_id = $o5)"
}
# gifts_for <viewer id> <viewer email>: idea texts the viewer sees on birthday 201 (a SQL error yields text that fails every comparison).
gifts_for() {
  local out
  out="$(db -c "$(gen_query listViewerGifts "$1" 201 "'$2'") " < /dev/null)"
  if grep -q '^ERROR' <<< "$out"; then echo "SQL-ERROR: $out"; return; fi
  cut -d '|' -f 2 <<< "$out" | paste -sd ',' -
}
# dml <sql>: runs a write whose effect is checked afterwards; the statement itself must not error (a type or parameter
# mistake would otherwise make a "changes nothing" expectation pass vacuously).
dml() {
  local out
  out="$(dbq "$1")"
  if grep -q '^ERROR' <<< "$out"; then _fail "the statement ran without a SQL error" "$out"; else _pass; fi
}

seed5
expect_eq "the sharing fixture is seeded (shares,friend reminders,friend ideas,owner reminders,owner ideas)" "$(state5)" "1,1,2,1,2"
expect_eq "get-by-id: the owner reads their birthday" "$(get_ids "$o5" 201 s5owner@example.test)" "201"
expect_eq "get-by-id: the recipient reads the shared birthday" "$(get_ids "$f5" 201 "$fe")" "201"
expect_eq "get-by-id: a stranger gets nothing" "$(get_ids "$x5" 201 s5stranger@example.test)" ""
expect_eq "gift visibility: the owner sees their own and the shared idea of the recipient, not the private one" "$(gifts_for "$o5" s5owner@example.test)" "f-shared,o-private,o-shared"
expect_eq "gift visibility: the recipient sees their own and the owner's shared idea" "$(gifts_for "$f5" "$fe")" "f-private,f-shared,o-shared"
expect_eq "gift visibility: a stranger sees none" "$(gifts_for "$x5" s5stranger@example.test)" ""

# A non-owner (the stranger as "owner") cannot unshare or clear anyone's data.
dml "$(gen_query deleteOwnedShare 201 "$x5" "'$fe'")"
dml "$(gen_query deleteSharedPersonReminders 201 "$x5" "'$fe'")"
dml "$(gen_query deleteSharedPersonGifts 201 "$x5" "'$fe'")"
expect_eq "a stranger's unshare, reminder clear and gift clear change nothing" "$(state5)" "1,1,2,1,2"

# Owner-scoped share insert and the owner's delete (cascade) against the real SQL.
dml "$(gen_query insertOwnedShare "'$fe'" 201 "$x5")"
expect_eq "a non-owner cannot add a share" "$(dbq "SELECT count(*) FROM birthday_shares WHERE birthday_id = 201")" "1"
dml "$(gen_query insertOwnedShare "'$fe'" 201 "$o5")"
expect_eq "an existing share is not duplicated (ON CONFLICT DO NOTHING)" "$(dbq "SELECT count(*) FROM birthday_shares WHERE birthday_id = 201")" "1"
dml "$(gen_query insertOwnedShare "'s5stranger@example.test'" 201 "$o5")"
expect_eq "the owner can add a share" "$(dbq "SELECT count(*) FROM birthday_shares WHERE birthday_id = 201")" "2"
dml "$(gen_query deleteOwnedShare 201 "$o5" "'s5stranger@example.test'")"
dml "$(gen_query deleteOwnedBirthday 201 "$x5")"
expect_eq "a non-owner cannot delete the birthday" "$(dbq "SELECT count(*) FROM birthdays WHERE id = 201")" "1"

# Viewer-scoped writes: a stranger cannot set a reminder or add an idea on a birthday they cannot see.
dml "$(gen_query upsertViewerReminder "$x5" "'{1}'" 201 "'s5stranger@example.test'")"
dml "$(gen_query insertViewerGift "$x5" "'sneaky'" false 201 "'s5stranger@example.test'")"
expect_eq "a stranger's reminder and idea writes insert nothing" \
  "$(dbq "SELECT (SELECT count(*) FROM reminder_settings WHERE user_id = $x5) || ',' || (SELECT count(*) FROM gift_ideas WHERE author_id = $x5)")" "0,0"
dml "$(gen_query upsertViewerReminder "$f5" "'{0}'" 201 "'$fe'")"
expect_eq "a recipient's reminder upsert replaces their offsets" "$(dbq "SELECT offsets FROM reminder_settings WHERE birthday_id = 201 AND user_id = $f5")" "{0}"

# Gift author scoping.
gid="$(dbq "SELECT id FROM gift_ideas WHERE text = 'f-private'")"
expect_eq "GetOwnGiftBirthday: the author gets the birthday id" "$(db -c "$(gen_query getOwnGiftBirthday "$gid" "$f5") " < /dev/null | head -n 1)" "201"
expect_eq "GetOwnGiftBirthday: another user gets nothing" "$(db -c "$(gen_query getOwnGiftBirthday "$gid" "$o5") " < /dev/null | head -n 1)" ""
dml "$(gen_query updateOwnGiftShared true "$gid" "$o5")"
expect_eq "a non-author cannot mark an idea shared" "$(dbq "SELECT shared FROM gift_ideas WHERE id = $gid")" "f"
dml "$(gen_query updateOwnGiftShared true "$gid" "$f5")"
expect_eq "the author can mark an idea shared" "$(dbq "SELECT shared FROM gift_ideas WHERE id = $gid")" "t"
expect_eq "a shared idea becomes visible to the owner" "$(gifts_for "$o5" s5owner@example.test)" "f-private,f-shared,o-private,o-shared"
dml "$(gen_query deleteOwnGift "$gid" "$o5")"
expect_eq "a non-author cannot delete an idea" "$(dbq "SELECT count(*) FROM gift_ideas WHERE id = $gid")" "1"

# Unshare (owner): the share row, then that person's reminders and ideas on the birthday; the owner's own data stays.
seed5
dml "$(gen_query deleteOwnedShare 201 "$o5" "'$fe'")"
dml "$(gen_query deleteSharedPersonReminders 201 "$o5" "'$fe'")"
dml "$(gen_query deleteSharedPersonGifts 201 "$o5" "'$fe'")"
expect_eq "unshare removes the share, the person's reminders and their ideas, and nothing of the owner's" "$(state5)" "0,0,0,1,2"
expect_eq "after unshare the ex-recipient reads nothing" "$(get_ids "$f5" 201 "$fe")" ""
expect_eq "after unshare the ex-recipient sees no ideas" "$(gifts_for "$f5" "$fe")" ""
expect_eq "after unshare the owner keeps their two ideas" "$(gifts_for "$o5" s5owner@example.test)" "o-private,o-shared"
dml "$(gen_query upsertViewerReminder "$f5" "'{1}'" 201 "'$fe'")"
expect_eq "an ex-recipient cannot set a reminder" "$(state5)" "0,0,0,1,2"

# Remove from my list (recipient): their share row, reminders and ideas.
seed5
dml "$(gen_query deleteOwnShare 201 "'$fe'")"
dml "$(gen_query deleteOwnReminders 201 "$f5")"
dml "$(gen_query deleteOwnGifts 201 "$f5")"
expect_eq "remove-from-my-list removes the share, the person's reminders and ideas, and nothing of the owner's" "$(state5)" "0,0,0,1,2"
expect_eq "after leaving, the recipient reads nothing" "$(get_ids "$f5" 201 "$fe")" ""
seed5
dml "$(gen_query deleteViewerReminder 201 "$f5" "'$fe'")"
expect_eq "turning reminders off deletes only the viewer's own row" "$(state5)" "1,0,2,1,2"

# Settings: a one-column UPDATE leaves the other columns unchanged; the enum CHECKs reject bad values.
settings_row() { dbq "SELECT auto_remind::text || '|' || default_offsets::text || '|' || start_tab || '|' || list_view || '|' || calendar_zoom || '|' || color_scheme FROM users WHERE id = $o5"; }
expect_eq "the settings defaults" "$(settings_row)" "false|{14,7,1}|auto|upcoming|month|confetti"
dml "$(gen_query updateSettings NULL NULL NULL "'name'" NULL NULL "$o5")"
expect_eq "a one-column settings UPDATE leaves the other columns unchanged" "$(settings_row)" "false|{14,7,1}|auto|name|month|confetti"
dml "$(gen_query updateSettings true "'{0}'" NULL NULL "'week'" "'candle'" "$o5")"
expect_eq "a multi-column settings UPDATE sets just those columns" "$(settings_row)" "true|{0}|auto|name|week|candle"
rejects "an unknown start_tab" users_start_tab_check "$(gen_query updateSettings NULL NULL "'bogus'" NULL NULL NULL "$o5")"
rejects "an unknown list_view" users_list_view_check "$(gen_query updateSettings NULL NULL NULL "'bogus'" NULL NULL "$o5")"
rejects "an unknown calendar_zoom" users_calendar_zoom_check "$(gen_query updateSettings NULL NULL NULL NULL "'bogus'" NULL "$o5")"
rejects "an unknown color_scheme" users_color_scheme_check "$(gen_query updateSettings NULL NULL NULL NULL NULL "'bogus'" "$o5")"
expect_eq "rejected settings UPDATEs changed nothing" "$(settings_row)" "true|{0}|auto|name|week|candle"
rejects "reminder offsets with a value outside the allowed set" reminder_settings_offsets_check "$(gen_query upsertViewerReminder "$o5" "'{2}'" 201 "'s5owner@example.test'")"
rejects "reminder offsets {8} (not a whole week)" reminder_settings_offsets_check "$(gen_query upsertViewerReminder "$o5" "'{8}'" 201 "'s5owner@example.test'")"
rejects "reminder offsets {365} (past 52 weeks)" reminder_settings_offsets_check "$(gen_query upsertViewerReminder "$o5" "'{365}'" 201 "'s5owner@example.test'")"
rejects "empty reminder offsets through the upsert" reminder_settings_offsets_check "$(gen_query upsertViewerReminder "$o5" "'{}'" 201 "'s5owner@example.test'")"
dml "$(gen_query upsertViewerReminder "$o5" "'{14}'" 201 "'s5owner@example.test'")"
expect_eq "reminder offsets {14} are accepted" "$(dbq "SELECT offsets FROM reminder_settings WHERE birthday_id = 201 AND user_id = $o5")" "{14}"
dml "$(gen_query upsertViewerReminder "$o5" "'{364}'" 201 "'s5owner@example.test'")"
expect_eq "reminder offsets {364} are accepted" "$(dbq "SELECT offsets FROM reminder_settings WHERE birthday_id = 201 AND user_id = $o5")" "{364}"
dml "$(gen_query upsertViewerReminder "$o5" "'{364,0}'" 201 "'s5owner@example.test'")"
expect_eq "reminder offsets {364,0} are accepted" "$(dbq "SELECT offsets FROM reminder_settings WHERE birthday_id = 201 AND user_id = $o5")" "{364,0}"

# Migration 00002 moves only users still on the old {7,1} default. This script has no goose binary (the app applies
# migrations at startup), so it runs the shipped UPDATE statement text, extracted from the migration file, against rows
# seeded with an explicit default; it does not test goose ordering.
mig_stmt="$(sed -n 's/^\(UPDATE users SET default_offsets .*\)$/\1/p' "$here/migrations/00002_custom_reminder_offsets.sql")"
[ -n "$mig_stmt" ] && [ "$(wc -l <<< "$mig_stmt")" -eq 1 ] || { echo "FAIL: cannot extract the UPDATE statement from migrations/00002_custom_reminder_offsets.sql"; exit 1; }
dml "INSERT INTO users (email, default_offsets) VALUES ('mig-old@example.test', '{7,1}'), ('mig-custom@example.test', '{0}')"
dml "$mig_stmt"
expect_eq "the migration moves an untouched {7,1} default to {14,7,1}" "$(dbq "SELECT default_offsets FROM users WHERE email = 'mig-old@example.test'")" "{14,7,1}"
expect_eq "the migration leaves a custom default alone" "$(dbq "SELECT default_offsets FROM users WHERE email = 'mig-custom@example.test'")" "{0}"

# Identity: the upsert is keyed by the (already lowercase) email, so a repeat returns the same row, and a share matches by that email.
expect_eq "UpsertUser returns the existing row for a repeated email" "$(db -c "$(gen_query upsertUser "'$fe'") " < /dev/null | head -n 1 | cut -d '|' -f 1)" "$f5"
rejects "a mixed-case identity reaching the users table" users_email_check "$(gen_query upsertUser "'S5Friend@Example.test'")"
expect_eq "a share matches the lowercase identity email" "$(get_ids "$f5" 201 "$fe")" "201"

# Notification destinations are owner-scoped: the shipped get / set-stale / delete SQL with another user's id matches
# nothing, with the owner's id it acts, and the list is ordered by id.
dbq "INSERT INTO destinations (user_id, notifs_id, kind, label, hint) VALUES ($o5, 9001, 'webhook', 'first', 'aaa'), ($o5, 5001, 'discord', 'second', 'bbb'), ($x5, 7001, 'webhook', 'foreign', 'ccc')" > /dev/null
d_own="$(dbq "SELECT id FROM destinations WHERE label = 'first'")"
d_foreign="$(dbq "SELECT id FROM destinations WHERE label = 'foreign'")"
dest_state() { dbq "SELECT string_agg(label || ':' || stale::text, ',' ORDER BY id) FROM destinations WHERE user_id IN ($o5, $x5)"; }
expect_eq "ListDestinations: the owner's rows in id order, not another user's" \
  "$(db -c "$(gen_query listDestinations "$o5") " < /dev/null | cut -d '|' -f 4 | paste -sd ',' -)" "first,second"
expect_eq "GetOwnDestination: the owner reads their row" "$(db -c "$(gen_query getOwnDestination "$d_own" "$o5") " < /dev/null | head -n 1 | cut -d '|' -f 1)" "$d_own"
expect_eq "GetOwnDestination: another user's id gets nothing" "$(db -c "$(gen_query getOwnDestination "$d_own" "$x5") " < /dev/null | head -n 1)" ""
dml "$(gen_query setOwnDestinationStale true "$d_own" "$x5")"
expect_eq "SetOwnDestinationStale: another user changes nothing" "$(dest_state)" "first:false,second:false,foreign:false"
dml "$(gen_query setOwnDestinationStale true "$d_own" "$o5")"
expect_eq "SetOwnDestinationStale: the owner marks their row" "$(dest_state)" "first:true,second:false,foreign:false"
dml "$(gen_query deleteOwnDestination "$d_own" "$x5")"
expect_eq "DeleteOwnDestination: another user deletes nothing" "$(dest_state)" "first:true,second:false,foreign:false"
dml "$(gen_query deleteOwnDestination "$d_own" "$o5")"
expect_eq "DeleteOwnDestination: the owner deletes their row" "$(dest_state)" "second:false,foreign:false"
expect_eq "a foreign id is untouched by the owner's delete" "$(dbq "SELECT count(*) FROM destinations WHERE id = $d_foreign")" "1"
dbq "DELETE FROM destinations WHERE user_id IN ($o5, $x5)" > /dev/null

# Notification settings: the per-user advisory lock that serializes the first ntfy provision. The exact shipped SQL
# (extracted from the generated code, never retyped) runs in two overlapping sessions on one user id: the second must
# block until the first commits. Only locks on this user id count, so another advisory lock cannot upset the counts.
lock_sql="$(gen_query lockUserNtfy "$o5")"
now_ms="SELECT (extract(epoch from clock_timestamp()) * 1000)::bigint;"
advisory() { pgsql -At -c "SELECT count(*) FILTER (WHERE granted) || ',' || count(*) FILTER (WHERE NOT granted) FROM pg_locks WHERE locktype = 'advisory' AND classid::bigint = 0 AND objid::bigint = $o5" < /dev/null; }
lockA="$T_TMP/ntfy-lock-a.txt"
lockB="$T_TMP/ntfy-lock-b.txt"
printf 'BEGIN;\n%s;\nSELECT pg_sleep(8);\n%s\nCOMMIT;\n' "$lock_sql" "$now_ms" | db > "$lockA" &
pidA=$!
holder=""
for _ in $(seq 1 50); do
  holder="$(advisory)"
  [ "$holder" = "1,0" ] && break
  sleep 0.2
done
expect_eq "the first session holds the per-user advisory lock" "$holder" "1,0"
printf 'BEGIN;\n%s;\n%s\nCOMMIT;\n' "$lock_sql" "$now_ms" | db > "$lockB" &
pidB=$!
waiter=""
for _ in $(seq 1 50); do
  waiter="$(advisory)"
  [ "$waiter" = "1,1" ] && break
  sleep 0.2
done
expect_eq "the second session waits on the lock while the first holds it" "$waiter" "1,1"
wait "$pidA" "$pidB"
a_commit="$(grep -E '^[0-9]{10,}$' "$lockA" | tail -n 1)"
b_got="$(grep -E '^[0-9]{10,}$' "$lockB" | tail -n 1)"
if [[ "$a_commit" =~ ^[0-9]+$ && "$b_got" =~ ^[0-9]+$ && "$b_got" -ge "$a_commit" ]]; then
  _pass
else
  _fail "the second session got the advisory lock only after the first finished" "first=$a_commit second=$b_got $(cat "$lockA" "$lockB")"
fi
expect_eq "no advisory lock is left held" "$(advisory)" "0,0"

# ---- reminder jobs against the real database and Redis ----
# The container's clock cannot be injected, so every seed date derives from the real Los Angeles date in SQL: a birthday
# whose occurrence is tomorrow with offset 1 is due today.
la_today="(now() at time zone 'America/Los_Angeles')::date"
dbq "INSERT INTO users (email, ntfy_user_id) VALUES ('jobs@example.test', 'nu-jobs')" > /dev/null
j_uid="$(dbq "SELECT id FROM users WHERE email = 'jobs@example.test'")"
dbq "INSERT INTO birthdays (owner_id, name, month, day) SELECT $j_uid, 'Jobs Person', extract(month FROM d), extract(day FROM d) FROM (SELECT $la_today + 1 AS d) x" > /dev/null
j_bid="$(dbq "SELECT id FROM birthdays WHERE owner_id = $j_uid")"
# Earlier blocks seeded reminder settings at fixed dates, and the Step 6 flow may have left queue items: clear both so the
# exact counts below do not depend on the real calendar day.
dbq "DELETE FROM reminder_settings" > /dev/null
rdadmin DEL "$app:jobs:queue" > /dev/null
dbq "INSERT INTO reminder_settings (birthday_id, user_id, offsets) VALUES ($j_bid, $j_uid, '{1}')" > /dev/null
j_occ="$(dbq "SELECT $la_today + 1")"
jobs_payload() { printf '{"birthday_id":%s,"user_id":%s,"occurrence":"%s","offset_days":1}' "$j_bid" "$j_uid" "$j_occ"; }
post_body() { # <job> <body> -> http code
  curl -s -o /dev/null -w '%{http_code}' --max-time 20 -X POST -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $jobs_secret" -d "$2" "$base/_jobs/$1"
}
scan_body() { printf '{"v":1,"run_id":"%s","job":"reminder-scan","trigger":"schedule","attempt":1,"scheduled_for":null,"queue_id":null,"enqueued_at":null,"payload":{}}' "$1"; }
send_body() { printf '{"v":1,"run_id":"run-send","job":"send-reminder","trigger":"queue","attempt":1,"scheduled_for":null,"queue_id":"01JOBSQUEUEID0000000000001","enqueued_at":null,"payload":%s}' "$(jobs_payload)"; }
queue_len() { rdadmin LLEN "$app:jobs:queue"; }
job_runs_count() { dbq "SELECT count(*) FROM job_runs"; }

# Without the four notifs-* files the scan fails before queueing anything, and a send errors (a skip would be a 200 and
# a skipped row): both are runner-visible errors with nothing recorded.
runs_before="$(job_runs_count)"
log_lines_before="$(docker logs "$APPC" 2>&1 | wc -l)"
expect_eq "reminder-scan with notifs unconfigured is a runner-visible error" "$(post_body reminder-scan "$(scan_body run-scan-0)")" 500
expect_eq "the unconfigured scan queued nothing" "$(queue_len)" 0
expect_eq "send-reminder with notifs unconfigured is an error" "$(post_body send-reminder "$(send_body)")" 500
expect_eq "send-reminder with notifs unconfigured errors again on the retry (same queue id)" "$(post_body send-reminder "$(send_body)")" 500
expect_eq "no reminders_sent row was recorded for the unconfigured send" "$(dbq "SELECT count(*) FROM reminders_sent WHERE user_id = $j_uid")" 0
expect_eq "no job_runs row was recorded for the unconfigured send" "$(job_runs_count)" "$runs_before"
if docker logs "$APPC" 2>&1 | tail -n +"$((log_lines_before + 1))" | grep -q 'unconfigured'; then _pass; else _fail "the container log names the unconfigured notifs client" "$(docker logs "$APPC" 2>&1 | tail -n 8)"; fi

# Dummy notifs-* files (the scan only checks they exist and the base URL parses; it makes no notifs call).
printf 'dummy-key' > "$sec/secrets/notifs-key"
printf 'dummy-id' > "$sec/secrets/notifs-access-client-id"
printf 'dummy-secret' > "$sec/secrets/notifs-access-client-secret"
printf 'http://127.0.0.1:9' > "$sec/secrets/notifs-base-url"
chmod 644 "$sec/secrets/"notifs-*
scan1_code="$(post_body reminder-scan "$(scan_body run-scan-1)")"
if [ "$scan1_code" != 200 ]; then echo "test_image: scan answered $scan1_code; container log tail:"; docker logs "$APPC" 2>&1 | tail -n 15; fi
expect_eq "reminder-scan with the notifs files present succeeds" "$scan1_code" 200
expect_eq "the scan queued exactly one send-reminder for the seeded due reminder" "$(queue_len)" 1
queued="$(rdadmin LRANGE "$app:jobs:queue" 0 -1)"
if grep -q '"job":"send-reminder"' <<< "$queued" && grep -q "\"birthday_id\":$j_bid" <<< "$queued" && grep -q "\"occurrence\":\"$j_occ\"" <<< "$queued"; then
  _pass
else
  _fail "the queued envelope is a send-reminder for the seeded reminder" "$queued"
fi
expect_eq "a second scan inside the dedupe window queues nothing more" "$(post_body reminder-scan "$(scan_body run-scan-2)")" 200
expect_eq "still exactly one queued send-reminder (real Redis dedupe)" "$(queue_len)" 1

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
if [ "$live_passed" -ge 4 ]; then _pass; else _fail "fewer than 4 live tests passed ($live_passed): the live tests did not really run"; fi

# ---- missing Access settings make the container exit, not serve ----

if ! run_app "$NOAUDC" no > "$T_TMP/noaud-run" 2>&1; then
  echo "FAIL: docker run without ACCESS_AUD"; cat "$T_TMP/noaud-run"; exit 1
fi
exit_code="$(timeout 40 docker wait "$NOAUDC" 2> /dev/null)"
if [[ "$exit_code" =~ ^[0-9]+$ ]] && [ "$exit_code" -ne 0 ]; then _pass; else _fail "the container exits non-zero when ACCESS_AUD is unset" "docker wait gave '$exit_code'"; fi
if docker logs "$NOAUDC" 2>&1 | grep -q 'ACCESS_AUD'; then _pass; else _fail "the exit log names the missing ACCESS_AUD key" "$(docker logs "$NOAUDC" 2>&1 | tail -n 5)"; fi

t_finish
