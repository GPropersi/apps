#!/usr/bin/env bash
# Pre-merge run of the jobs runner's queue consumer against a REAL Redis: the pinned image from
# platform/data/compose.yaml, started with the same command flags (noeviction, AOF, --aclfile,
# --proto-max-bulk-len 1mb), with the real runner user (RUNNER_ACL_RULE from install-data.sh) and a real app user
# (the rule new-db.sh builds). It then runs `go test -tags live` (internal/queue/live_test.go).
#
# Needs docker; without a usable docker daemon it skips with a loud notice and exits 0. Use REQUIRE_DOCKER=1 so a
# missing docker, daemon or image is a failure instead of a skip (a skip is not a pass):
#   REQUIRE_DOCKER=1 bash platform/jobs/test_jobs_live.sh > /tmp/claude/jobs-live.txt 2>&1
# PJLIVE_SKIP=1 opts out (ordinary developer `make test` runs): it skips with a notice, and is still a failure under
# REQUIRE_DOCKER=1.
#
# What it proves against the real server (each negative assertion has a positive control in the same run):
#   - the runner's real `ACL LIST` line passes install-data.sh's acl_problems check, and a tampered rule fails it;
#   - the Go live tests (see live_test.go): NOPERM boundary, enqueue order, LREM of the raw item, promotion
#     atomicity, the delayed bound, the 1 MB bulk limit, OOM variants, Redis down / invalid, dead-letter atomicity,
#     wrong-type parking, a lost EXEC reply, recovery and crash exhaustion.
#
# Isolation: every container, network and volume carries the unique prefix pjlive-<pid>-<random>; everything is
# removed on every exit path. Passwords are throwaway and never leave this run.
#
# Hints:
#   "OOM case did not trigger"              -> maxmemory was not lowered below used_memory
#   "NOPERM on the OOM Redis"               -> RUNNER_ACL_RULE was not applied before the test
#   leftover containers after a killed run  -> docker ps -a --filter name=pjlive-   (remove by prefix)
#   FAIL: cannot pull <image>               -> image pull failure (network or registry), not a code failure
# shellcheck disable=SC1091
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
# shellcheck source=../lib/yaml-subset.sh
. "$here/../lib/yaml-subset.sh"
# shellcheck source=go-env.sh
. "$here/go-env.sh" || { echo "test_jobs_live: FAIL: the pinned Go toolchain is not usable"; exit 1; }

skip() {
  if [ "${REQUIRE_DOCKER:-0}" = 1 ]; then
    echo "FAIL: $(basename "$0"): $1 (REQUIRE_DOCKER=1 turns a skip into a failure)"
    exit 1
  fi
  echo "################################################################"
  echo "## $(basename "$0") SKIPPED: $1"
  echo "## The real-Redis queue check did NOT run. Run it on a docker host before merge (REQUIRE_DOCKER=1)."
  echo "################################################################"
  exit 0
}

[ "${PJLIVE_SKIP:-0}" != 1 ] || skip "PJLIVE_SKIP=1"
command -v docker >/dev/null 2>&1 || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "the docker daemon is not reachable by this user"

t_init

rid="pjlive-$$-$RANDOM"
RDC="$rid-redis"
vol="$rid-data"
acl_seed="$T_TMP/users.acl"

cleanup() {
  docker rm -fv "$RDC" >/dev/null 2>&1
  docker volume rm -f "$vol" >/dev/null 2>&1
  t_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

rand() { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }

# ---- the stack definition under test ----

flat="$T_TMP/compose-flat"
if ! ys_flatten < "$here/../data/compose.yaml" > "$flat"; then
  echo "FAIL: platform/data/compose.yaml is outside the YAML subset the tests understand"
  exit 1
fi
img="$(ys_get "$flat" services/redis/image)"
[ -n "$img" ] || { echo "FAIL: cannot read the redis image from compose.yaml"; exit 1; }

# The command flags come from compose.yaml itself (never retyped): the list items under services/redis/command.
mapfile -t flags < <(awk '/^  redis:/{r=1} r&&/^    command:/{c=1;next} c&&/^      - /{sub(/^      - /,""); gsub(/"/,""); print; next} c{exit}' "$here/../data/compose.yaml")
[ "${#flags[@]}" -ge 8 ] || { echo "FAIL: cannot read the redis command flags from compose.yaml (got ${#flags[@]})"; exit 1; }
want_flags="--maxmemory 96mb --maxmemory-policy noeviction --appendonly yes --appendfsync everysec --aclfile /data/users.acl --proto-max-bulk-len 1mb"
if [ "${flags[*]}" = "$want_flags" ]; then _pass; else _fail "the redis command flags in compose.yaml are the ones this test documents" "got: ${flags[*]}"; fi

if ! docker image inspect "$img" >/dev/null 2>&1; then
  if ! timeout 300 docker pull -q "$img" >/dev/null 2>"$T_TMP/pull-err"; then
    cat "$T_TMP/pull-err"
    skip "cannot pull $img (image pull failure: offline or rate-limited, not a code failure)"
  fi
fi

# ---- start Redis with a bootstrap ACL file (default off, admin, health), like redis-entrypoint.sh builds ----

admin_pw="$(rand 24)"
runner_pw="$(rand 24)"
app_pw="$(rand 24)"
other_pw="$(rand 24)"
app="$rid-a"
other="$rid-b"
hash="$(printf '%s' "$admin_pw" | sha256sum | cut -d ' ' -f 1)"
{
  printf 'user default off\n'
  printf 'user admin on #%s ~* &* +@all\n' "$hash"
  printf 'user health on nopass -@all +ping\n'
} > "$acl_seed"

docker volume create "$vol" >/dev/null || { echo "FAIL: volume create"; exit 1; }
docker run --rm -i -v "$vol:/data" --entrypoint sh "$img" -c 'cat > /data/users.acl && chown 999:999 /data/users.acl && chmod 600 /data/users.acl' < "$acl_seed" \
  || { echo "FAIL: seeding users.acl"; exit 1; }
docker run -d --name "$RDC" -p 127.0.0.1::6379 -v "$vol:/data" "$img" "${flags[@]}" >/dev/null || { echo "FAIL: redis start"; exit 1; }

rdadmin() { docker exec -i -e REDISCLI_AUTH="$admin_pw" "$RDC" redis-cli --user admin --no-auth-warning "$@" 2>&1 </dev/null; }

ready=0
for _ in $(seq 1 60); do
  if [ "$(docker exec "$RDC" redis-cli --user health --pass x --no-auth-warning ping 2>/dev/null)" = PONG ]; then ready=1; break; fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "FAIL: redis did not become ready"
  docker logs "$RDC" 2>&1 | tail -n 15
  exit 1
fi
expect_eq "admin login works" "$(rdadmin ping)" PONG

# ---- the real runner and app users ----

install_data="$here/../host/install-data.sh"
rule="$(sed -n "s/^readonly RUNNER_ACL_RULE='\(.*\)'\$/\1/p" "$install_data")"
[ -n "$rule" ] || { echo "FAIL: cannot read RUNNER_ACL_RULE from install-data.sh"; exit 1; }
rule="${rule//<password>/$runner_pw}"
set -f # the rule holds '*'
# shellcheck disable=SC2086
out="$(rdadmin ACL SETUSER $rule)"
set +f
expect_eq "applying RUNNER_ACL_RULE" "$out" OK

# The app rule is the one new-db.sh builds (read from the real script, with the placeholders substituted).
# shellcheck disable=SC2016
app_rule="$(sed -n 's/^  rule="ACL SETUSER \$APP \(.*\)"$/\1/p' "$here/../data/new-db.sh")"
[ -n "$app_rule" ] || { echo "FAIL: cannot read the app ACL rule from new-db.sh"; exit 1; }
for pair in "$app:$app_pw" "$other:$other_pw"; do
  name="${pair%%:*}"
  pw="${pair#*:}"
  r="${app_rule//\$REDIS_PW/$pw}"
  r="${r//\$APP/$name}"
  set -f
  # shellcheck disable=SC2086
  out="$(rdadmin ACL SETUSER "$name" $r)"
  set +f
  expect_eq "applying the new-db.sh rule for $name" "$out" OK
done

# ---- the real ACL LIST passes acl_problems; a tampered runner rule fails it ----

# shellcheck disable=SC2034  # read by the sourced acl_problems
APP_RE="$(sed -n "s/^readonly APP_RE='\(.*\)'\$/\1/p" "$install_data" | head -n 1)"
reserved_names() { sed -e 's/#.*//' -e 's/[[:space:]]*$//' "$here/../registry/reserved-names.txt" | grep -v '^$' || true; }
fns="$T_TMP/acl-fns.sh"
awk '/^acl_tok\(\) \{/{p=1} p{print} /^acl_problems\(\) \{/{ap=1} ap && /^\}$/{exit}' "$install_data" > "$fns"
[ -s "$fns" ] || { echo "FAIL: cannot extract acl_problems from install-data.sh"; exit 1; }
# shellcheck disable=SC1090
. "$fns"

acl_list="$(rdadmin ACL LIST)"
expect_eq "the live ACL LIST has the runner user" "$(grep -c '^user runner ' <<<"$acl_list")" 1
problems="$(acl_problems "$acl_list")"
expect_eq "the real ACL LIST passes acl_problems" "$problems" ""

set -f
rdadmin ACL SETUSER runner +@dangerous >/dev/null
set +f
tampered="$(acl_problems "$(rdadmin ACL LIST)")"
if [ -n "$tampered" ]; then _pass; else _fail "a runner rule with +@dangerous must fail acl_problems (positive control)"; fi
# Re-applying the whole rule restores it: resetpass, resetkeys, resetchannels and -@all clear what the tamper added.
set -f
# shellcheck disable=SC2086
rdadmin ACL SETUSER $rule >/dev/null
set +f
expect_eq "the restored runner rule passes acl_problems again" "$(acl_problems "$(rdadmin ACL LIST)")" ""

# ---- run the Go live tests ----

hostport="$(docker port "$RDC" 6379/tcp | head -n 1)"
[ -n "$hostport" ] || { echo "FAIL: no published port for $RDC"; exit 1; }

export CGO_ENABLED=1
export PJLIVE_ADDR="$hostport" PJLIVE_ADMIN_PW="$admin_pw" PJLIVE_RUNNER_PW="$runner_pw"
export PJLIVE_APP="$app" PJLIVE_APP_PW="$app_pw" PJLIVE_OTHER="$other" PJLIVE_OTHER_PW="$other_pw"
echo "test_jobs_live: go$GO_VERSION, go test -tags live -race against $img"
if (cd "$here" && go test -tags live -race -count=1 -timeout 4m ./internal/queue/ -run "${PJLIVE_RUN:-TestLive}" -v) > "$T_TMP/go-live.txt" 2>&1; then
  _pass
  grep -E '^\s*(--- (PASS|FAIL|SKIP)|PASS|FAIL|ok)' "$T_TMP/go-live.txt" | head -n 120
else
  _fail "go test -tags live (build or test failure, not an image pull)" "$(grep -E '^(\s*--- FAIL|=== RUN|panic:|FAIL|\s+[a-z_]+_test\.go:[0-9]+:)' "$T_TMP/go-live.txt" | tail -n 40; echo '--- tail ---'; tail -n 25 "$T_TMP/go-live.txt")"
fi
[ -z "${PJLIVE_OUT:-}" ] || cp "$T_TMP/go-live.txt" "$PJLIVE_OUT"
if grep -q -- '--- SKIP' "$T_TMP/go-live.txt"; then _fail "a live subtest was skipped (a skip is not a pass)" "$(grep -- '--- SKIP' "$T_TMP/go-live.txt")"; fi

# A green `go test` with nothing selected (a build-tag typo, an empty filter) prints "no tests to run" and exits 0, so
# require that the subtests really passed. A PJLIVE_RUN filter selects fewer, so the floor only applies to a full run.
passed="$(grep -c -E '^\s*--- PASS: TestLive/' "$T_TMP/go-live.txt")"
echo "test_jobs_live: $passed TestLive subtests passed"
if [ -n "${PJLIVE_RUN:-}" ]; then
  [ "$passed" -ge 1 ] || _fail "no TestLive subtest passed for PJLIVE_RUN=$PJLIVE_RUN (an empty selection is not a pass)"
else
  [ "$passed" -ge 20 ] || _fail "fewer than 20 TestLive subtests passed ($passed): the live tests did not really run"
fi

t_finish
