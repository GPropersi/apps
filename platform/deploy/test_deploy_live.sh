#!/usr/bin/env bash
# test-class: docker
# Pre-merge run of deploy.sh against the REAL docker daemon: it builds a tiny local image (no GHCR) and deploys it with
# DEPLOY_SKIP_REGISTRY=1 (the local image has no registry, so login and pull are bypassed; the token line is still sent).
# It catches run-contract combinations a stub cannot: --read-only with --tmpfs, --group-add, the container IP lookup for
# the health curl, the rename/restore dance on a real daemon.
#
# Needs docker and the pinned busybox image; without a usable docker daemon it skips with a loud notice and exits 0. Use
# REQUIRE_DOCKER=1 so a missing docker, daemon or image is a failure instead of a skip (a skip is not a pass):
#   REQUIRE_DOCKER=1 bash platform/deploy/test_deploy_live.sh > /tmp/claude/deploy-live.txt 2>&1
# PDLIVE_SKIP=1 opts out (ordinary developer `make test` runs): it skips with a notice, and is still a failure under
# REQUIRE_DOCKER=1.
#
# What it proves (each negative assertion has a positive control in the same run): a first deploy, a healthy swap, an
# unhealthy swap that restores the old container, a leftover app-<app>-old from an interrupted deploy, a rollback, a double
# rollback ending on the original version, a rollback after a redeploy of the live tag, the cleanup rule (the current and
# previous images are kept, a stray image of the app is removed) and a rollback whose previous image is gone (exit 1,
# naming inspect, the running version untouched).
#
# Isolation: the app name, network and image tags carry the unique prefix dplive-<random>-<pid>; the DEPLOY_NETWORK,
# secrets, job-secrets, state, registry, lock and connection-env hooks point at a per-run network and temp dirs, so the
# real `platform` network and host paths are never touched. Everything is removed on every exit path.
#
# Hints:
#   leftover containers after a killed run  -> docker ps -a --filter name=app-dplive-   (remove by prefix)
#   FAIL: cannot pull <image>               -> image pull failure (network or registry), not a code failure
# shellcheck disable=SC1091,SC2034
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/deploy.sh"
validator="$here/../registry/validate-app-yaml.sh"

# The same pin as the busybox image in platform/ingress/compose.yaml.
base_image="docker.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"

skip() {
  if [ "${REQUIRE_DOCKER:-0}" = 1 ]; then
    echo "FAIL: $(basename "$0"): $1 (REQUIRE_DOCKER=1 turns a skip into a failure)"
    exit 1
  fi
  echo "################################################################"
  echo "## $(basename "$0") SKIPPED: $1"
  echo "## The real-daemon deploy check did NOT run. Run it on a docker host before merge (REQUIRE_DOCKER=1)."
  echo "################################################################"
  exit 0
}

[ "${PDLIVE_SKIP:-0}" != 1 ] || skip "PDLIVE_SKIP=1"
command -v docker >/dev/null 2>&1 || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "the docker daemon is not reachable by this user"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"

if ! docker image inspect "$base_image" >/dev/null 2>&1; then
  pull_err="$(mktemp)"
  if ! timeout 300 docker pull -q "$base_image" >/dev/null 2>"$pull_err"; then
    cat "$pull_err"
    rm -f "$pull_err"
    skip "cannot pull $base_image (image pull failure: offline or rate-limited, not a code failure)"
  fi
  rm -f "$pull_err"
fi

t_init

rid="dplive-$RANDOM-$$"
app="$rid"
net="$rid-net"
repo="ghcr.io/gpropersi/apps/$app"
ctr="app-$app"
W="$T_TMP/w"

cleanup() {
  docker rm -fv "$ctr" "$ctr-old" >/dev/null 2>&1
  docker network rm "$net" >/dev/null 2>&1
  docker image rm -f "$repo:v1" "$repo:v2" "$repo:v3" "$repo:bad" >/dev/null 2>&1
  t_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

docker network create "$net" >/dev/null || { echo "FAIL: cannot create the per-run network"; exit 1; }
mkdir -p "$W/secrets/$app" "$W/jobs/$app" "$W/locks" "$W/dstate" "$W/reg" "$W/tmp" "$W/ctx"
chmod 755 "$W" "$W/secrets" "$W/secrets/$app" "$W/jobs" "$W/jobs/$app"
printf 'x' >"$W/secrets/$app/db-password"
printf 'x' >"$W/secrets/$app/redis-password"
printf 'x' >"$W/jobs/$app/jobs-secret"
chmod 644 "$W/secrets/$app/"* "$W/jobs/$app/"*
printf 'PLATFORM_PG_HOST=postgres\nPLATFORM_PG_PORT=5432\nPLATFORM_REDIS_HOST=redis\nPLATFORM_REDIS_PORT=6379\n' >"$W/conn.env"

# build_image <tag> <healthy 1|0>: a busybox httpd on port 8080 as uid 1000; unhealthy serves no /healthz (a 404).
build_image() {
  local tag="$1" healthy="$2"
  {
    printf 'FROM %s\n' "$base_image"
    printf 'RUN mkdir /www && echo %s > /www/index.html\n' "$tag"
    [ "$healthy" -eq 0 ] || printf 'RUN echo ok > /www/healthz\n'
    printf 'USER 1000\nEXPOSE 8080\nCMD ["httpd", "-f", "-p", "8080", "-h", "/www"]\n'
  } >"$W/ctx/Dockerfile"
  docker build -q -t "$repo:$tag" "$W/ctx" >/dev/null 2>"$T_TMP/build-err" || { cat "$T_TMP/build-err"; echo "FAIL: building $repo:$tag"; exit 1; }
}
build_image v1 1
# v2 and bad are built just before they are deployed: cleanup removes this app's images that are neither current nor previous.

cat >"$W/app.yaml" <<EOF
schema_version: 1
name: $app
owner: tester
purpose: Deploy live test app
template: flask
memory_cap: 64m
port: 8080
health_path: /healthz
EOF
printf 'unused-token-line\n' >"$W/input"
cat "$W/app.yaml" >>"$W/input"

deploy() { # <tag>
  rc=0
  out="$(env TMPDIR="$W/tmp" DEPLOY_NETWORK="$net" DEPLOY_SECRETS_ROOT="$W/secrets" DEPLOY_JOB_SECRETS_ROOT="$W/jobs" \
    DEPLOY_STATE_ROOT="$W/dstate" DEPLOY_REGISTRY_ROOT="$W/reg" DEPLOY_LOCK_DIR="$W/locks" DEPLOY_CONNECTION_ENV="$W/conn.env" \
    DEPLOY_SKIP_REGISTRY=1 DEPLOY_VALIDATOR="$validator" DEPLOY_HEALTH_WAIT=8 "$script" deploy "$app" "$1" 2>&1 <"$W/input")" || rc=$?
}

rollback() { # no stdin and no registry: DEPLOY_SKIP_REGISTRY is not even set
  rc=0
  out="$(env TMPDIR="$W/tmp" DEPLOY_NETWORK="$net" DEPLOY_SECRETS_ROOT="$W/secrets" DEPLOY_JOB_SECRETS_ROOT="$W/jobs" \
    DEPLOY_STATE_ROOT="$W/dstate" DEPLOY_REGISTRY_ROOT="$W/reg" DEPLOY_LOCK_DIR="$W/locks" DEPLOY_CONNECTION_ENV="$W/conn.env" \
    DEPLOY_VALIDATOR="$validator" DEPLOY_HEALTH_WAIT=8 "$script" rollback "$app" 2>&1 </dev/null)" || rc=$?
}

img_id() { docker image inspect --format '{{.Id}}' "$repo:$1" 2>/dev/null; }
ctr_image() { docker inspect --format '{{.Image}}' "$1" 2>/dev/null; }
ctr_state() { docker inspect --format '{{.State.Status}}' "$1" 2>/dev/null; }
ctr_exists() { docker inspect "$1" >/dev/null 2>&1; }
rd() { if [ -f "$1" ]; then cat "$1"; fi; }
fmt() { docker inspect --format "$1" "$ctr" 2>/dev/null; }
probe() { # the container's /healthz over the per-run network, as the health phase does
  local ip
  ip="$(fmt "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}")"
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$ip:8080/healthz"
}

# ---- a first deploy ----

deploy v1
expect_rc "a first deploy succeeds against the real daemon" 0
expect_eq "app container runs" "$(ctr_state "$ctr")" "running"
expect_eq "it runs the v1 image" "$(ctr_image "$ctr")" "$(img_id v1)"
expect_eq "no app-old container exists" "$(ctr_exists "$ctr-old" && echo yes || echo no)" "no"
expect_eq "the health path answers 200 (positive control for the probe)" "$(probe)" "200"
expect_eq "state current/tag" "$(rd "$W/dstate/$app/current/tag")" "v1"
expect_eq "state current/digest is the image ID under DEPLOY_SKIP_REGISTRY" "$(rd "$W/dstate/$app/current/digest")" "$(img_id v1)"
expect_eq "a first deploy creates no previous/" "$([ -e "$W/dstate/$app/previous" ] && echo yes || echo no)" "no"
expect_eq "the registry entry is written" "$(rd "$W/reg/$app/app.yaml")" "$(cat "$W/app.yaml")"

# The run contract as the daemon recorded it.
expect_eq "label platform.app" "$(fmt '{{index .Config.Labels "platform.app"}}')" "$app"
expect_eq "exactly one label" "$(fmt '{{len .Config.Labels}}')" "1"
expect_eq "read-only root filesystem" "$(fmt '{{.HostConfig.ReadonlyRootfs}}')" "true"
expect_eq "all capabilities dropped" "$(fmt '{{.HostConfig.CapDrop}}')" "[ALL]"
expect_eq "no-new-privileges" "$(fmt '{{.HostConfig.SecurityOpt}}')" "[no-new-privileges:true]"
expect_eq "memory cap 64m" "$(fmt '{{.HostConfig.Memory}}')" "67108864"
expect_eq "swap equals the memory cap" "$(fmt '{{.HostConfig.MemorySwap}}')" "67108864"
expect_eq "pids limit" "$(fmt '{{.HostConfig.PidsLimit}}')" "256"
expect_eq "restart policy" "$(fmt '{{.HostConfig.RestartPolicy.Name}}')" "unless-stopped"
expect_eq "supplementary groups" "$(fmt '{{.HostConfig.GroupAdd}}')" "[64323 64324]"
expect_eq "only the app's own secret dirs are mounted, read-only" \
  "$(fmt '{{range .Mounts}}{{.Source}}:{{.Destination}}:{{.RW}}{{println}}{{end}}' | grep -v '^$' | LC_ALL=C sort | paste -sd' ' -)" \
  "$W/jobs/$app:/run/platform/job-secrets:false $W/secrets/$app:/run/platform/secrets:false"
expect_eq "DB_NAME" "$(fmt '{{range .Config.Env}}{{println .}}{{end}}' | grep -x 'DB_NAME=.*')" "DB_NAME=${app//-/_}"
expect_eq "REDIS_KEY_PREFIX" "$(fmt '{{range .Config.Env}}{{println .}}{{end}}' | grep -x 'REDIS_KEY_PREFIX=.*')" "REDIS_KEY_PREFIX=$app:"
expect_eq "the environment names files, never a password" "$(fmt '{{range .Config.Env}}{{println .}}{{end}}' | grep -c '_PASSWORD=')" "0"
expect_eq "the container is on the per-run network with the app alias" "$(fmt "{{index .NetworkSettings.Networks \"$net\" \"Aliases\"}}" | grep -c "$app")" "1"
expect_eq "the temp dir is removed" "$(ls -A "$W/tmp")" ""

# ---- a healthy swap ----

build_image v2 1
build_image bad 0
deploy v2
expect_rc "a healthy swap succeeds" 0
expect_eq "the new image runs" "$(ctr_image "$ctr")" "$(img_id v2)"
expect_eq "it is running" "$(ctr_state "$ctr")" "running"
expect_eq "the old container is removed at commit" "$(ctr_exists "$ctr-old" && echo yes || echo no)" "no"
expect_eq "current/tag is v2" "$(rd "$W/dstate/$app/current/tag")" "v2"
expect_eq "previous/tag is v1" "$(rd "$W/dstate/$app/previous/tag")" "v1"
expect_eq "the v1 image stays local for a rollback" "$(img_id v1 | grep -c sha256)" "1"
expect_eq "cleanup removed the never-deployed bad image" "$(img_id bad | grep -c sha256)" "0"
build_image bad 0

# ---- an unhealthy swap restores the old container ----

before_reg="$(rd "$W/reg/$app/app.yaml")"
deploy bad
expect_rc "an unhealthy swap exits 1" 1
expect_out_has "and names the health phase" "phase 'health' failed"
expect_eq "the old container is restored under its name" "$(ctr_image "$ctr")" "$(img_id v2)"
expect_eq "and is running" "$(ctr_state "$ctr")" "running"
expect_eq "no app-old container is left" "$(ctr_exists "$ctr-old" && echo yes || echo no)" "no"
expect_eq "the restored container still answers" "$(probe)" "200"
expect_eq "current/tag is unchanged" "$(rd "$W/dstate/$app/current/tag")" "v2"
expect_eq "previous/tag is unchanged" "$(rd "$W/dstate/$app/previous/tag")" "v1"
expect_eq "the registry entry is unchanged" "$(rd "$W/reg/$app/app.yaml")" "$before_reg"
expect_eq "a failed deploy removed the image it pulled" "$(img_id bad | grep -c sha256)" "0"
expect_eq "and kept the current and previous images" "$(img_id v2 | grep -c sha256):$(img_id v1 | grep -c sha256)" "1:1"

# ---- a leftover app-old from an interrupted deploy ----

docker stop -t 2 "$ctr" >/dev/null 2>&1
docker rename "$ctr" "$ctr-old" >/dev/null 2>&1
expect_eq "fixture: only the -old container exists" "$(ctr_exists "$ctr" && echo yes || echo no):$(ctr_exists "$ctr-old" && echo yes || echo no)" "no:yes"
deploy v1
expect_rc "a leftover -old is recovered by the next deploy" 0
expect_eq "the new image runs after the recovery" "$(ctr_image "$ctr")" "$(img_id v1)"
expect_eq "no -old remains" "$(ctr_exists "$ctr-old" && echo yes || echo no)" "no"
expect_eq "current/tag is v1" "$(rd "$W/dstate/$app/current/tag")" "v1"
expect_eq "the health path answers after the recovery" "$(probe)" "200"

# ---- rollback (state now: current v1, previous v2) ----

rollback
expect_rc "a rollback succeeds against the real daemon" 0
expect_eq "the previous image runs (v2)" "$(ctr_image "$ctr")" "$(img_id v2)"
expect_eq "it is running and answers" "$(ctr_state "$ctr"):$(probe)" "running:200"
expect_eq "no -old container remains" "$(ctr_exists "$ctr-old" && echo yes || echo no)" "no"
expect_eq "current/tag and previous/tag are exchanged" "$(rd "$W/dstate/$app/current/tag"):$(rd "$W/dstate/$app/previous/tag")" "v2:v1"
expect_eq "the temp dir is removed after a rollback" "$(ls -A "$W/tmp")" ""

rollback
expect_rc "a second rollback succeeds" 0
expect_eq "two rollbacks end on the original image (v1)" "$(ctr_image "$ctr")" "$(img_id v1)"
expect_eq "and the original state" "$(rd "$W/dstate/$app/current/tag"):$(rd "$W/dstate/$app/previous/tag")" "v1:v2"

# A redeploy of the live tag, then a rollback, still returns to the version before it.
deploy v1
expect_rc "the live tag is redeployed" 0
expect_eq "the redeploy leaves previous/ alone" "$(rd "$W/dstate/$app/current/tag"):$(rd "$W/dstate/$app/previous/tag")" "v1:v2"
rollback
expect_rc "a rollback after a redeploy succeeds" 0
expect_eq "it returns to the version before the redeploy (v2)" "$(ctr_image "$ctr")" "$(img_id v2)"

# Cleanup keeps the current (v2) and previous (v1) images and removes a stray image of this app.
build_image v3 1
expect_eq "fixture: the stray v3 image exists" "$(img_id v3 | grep -c sha256)" "1"
rollback
expect_rc "a rollback with a stray image present succeeds" 0
expect_eq "the stray image is removed" "$(img_id v3 | grep -c sha256)" "0"
expect_eq "the current and previous images are kept" "$(img_id v1 | grep -c sha256):$(img_id v2 | grep -c sha256)" "1:1"
expect_eq "state after the third rollback" "$(rd "$W/dstate/$app/current/tag"):$(rd "$W/dstate/$app/previous/tag")" "v1:v2"

# A previous image that is gone from the daemon: exit 1 naming inspect, the running version untouched.
docker image rm "$repo:v2" >/dev/null 2>&1
expect_eq "fixture: the previous v2 image is gone" "$(img_id v2 | grep -c sha256)" "0"
rollback
expect_rc "a rollback with the previous image gone exits 1" 1
expect_out_has "and names inspect" "phase 'inspect' failed"
expect_eq "the running version is untouched" "$(ctr_image "$ctr"):$(ctr_state "$ctr")" "$(img_id v1):running"
expect_eq "the state is untouched" "$(rd "$W/dstate/$app/current/tag"):$(rd "$W/dstate/$app/previous/tag")" "v1:v2"

t_finish
