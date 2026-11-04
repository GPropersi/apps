#!/bin/bash -p
# deploy.sh: turn (app, tag) into a running, health-checked container, with no caller-controlled flags. To be installed
# by install-deploy-user.sh to /opt/platform/deploy/deploy.sh (root:root 0755) and run by the `platform deploy <app> <tag>`
# dispatcher as the deploy user (Docker access, no sudo).
#
# Usage: deploy.sh deploy <app> <tag>      (stdin: line 1 = registry pull token, the rest = the app's app.yaml)
#        deploy.sh rollback <app>          (no stdin, no registry call: reruns the recorded previous/ deploy from the local image)
# Exit: 0 done | 1 refused or failed (the phase is named) | 2 usage error
#
# Rollback takes the shared app lock first, then reads <state root>/<app>/previous/{tag,digest,app.yaml} (none: exit 1,
# "no previous deploy") and runs validate, preflight, inspect, swap, health and commit against the local image by its recorded
# digest. An image missing from the local daemon fails the inspect phase. Its commit exchanges current/ and previous/, so a
# second rollback returns forward. After a successful deploy or rollback this app's images other than the current and
# previous ones are removed (a failure is only a warning); after a failed deploy the newly pulled image goes too unless it
# is the current or previous one. Image identity is compared by image ID, never by tag.
#
# Everything about how the app runs is fixed here; the caller supplies only the validated name, the tag and app.yaml.
# Phases, none touching the running app until `swap`:
#   input      stdin framing: token line (at most 1 KiB, held in a shell variable, never a file, never exported), then
#              app.yaml (at most 16 KiB) into a private temp dir that is removed on every exit path
#   validate   the installed validate-app-yaml.sh on <tmp>/<app>/app.yaml
#   preflight  the shared per-app lock (flock, bounded wait), secrets dirs, network, curl, state root, registry root,
#              connection.env
#   pull       docker login (token on stdin, private DOCKER_CONFIG) and docker pull; resolves the immutable reference
#              (repo digest, or the image ID under DEPLOY_SKIP_REGISTRY) used by every later phase instead of the tag
#   inspect    architecture, numeric non-zero USER, no traefik.* / platform.* label, exactly one exposed <port>/tcp
#   swap       recover a leftover app-<app>-old, stop and rename the running container, run the new one
#   health     curl on the health path (2xx within the wait) or, with no health_path, the container staying up
#   commit     registry/<app>/app.yaml and deploy state (temp + rename), then the old container is removed
# A swap or health failure removes the new container and restores the old one. A commit failure leaves the new container
# running and the old one in place; the next deploy reconciles registry and state.
#
# Deploy state: <state root>/<app>/{current,previous}/{tag,digest,deployed-at,app.yaml}.
#
# Logging: a timestamped line per phase start and end (rc and duration) on stderr and through `logger -t platform`; error
# text from external commands is logged with the pull token masked. Every external call runs under `timeout`.
#
# Needs bash >= 5.1 (a here-string then travels through a pipe, not a temp file holding the token).
#
# Env overrides (tests only; the dispatcher runs this script with a scrubbed environment, so none is reachable through the
# restricted login; each defaults to the fixed production value): DEPLOY_NETWORK (platform), DEPLOY_SECRETS_ROOT
# (/var/lib/platform/secrets), DEPLOY_JOB_SECRETS_ROOT (/var/lib/platform/job-secrets), DEPLOY_STATE_ROOT
# (/var/lib/platform/deploy), DEPLOY_REGISTRY_ROOT (/var/lib/platform/registry), DEPLOY_LOCK_DIR
# (/var/lib/platform/locks), DEPLOY_CONNECTION_ENV (/opt/platform/data/connection.env), DEPLOY_SKIP_REGISTRY (1 skips
# login and pull and uses the image already in the local daemon), DEPLOY_VALIDATOR
# (/opt/platform/deploy/registry/validate-app-yaml.sh; its yaml reader is ../lib/yaml-subset.sh beside it),
# DEPLOY_LOCK_WAIT (30), DEPLOY_EXEC_TIMEOUT (30, per docker call), DEPLOY_PULL_TIMEOUT (300, login and pull each),
# DEPLOY_STOP_TIMEOUT (30), DEPLOY_STALE_TMP_MIN (60), DEPLOY_HEALTH_WAIT (60), DEPLOY_NOPATH_WAIT (10), DEPLOY_POLL_INTERVAL (1).
set -euo pipefail

if [ "${BASH_VERSINFO[0]}" -lt 5 ] || { [ "${BASH_VERSINFO[0]}" -eq 5 ] && [ "${BASH_VERSINFO[1]}" -lt 1 ]; }; then
  echo "deploy: needs bash >= 5.1" >&2
  exit 1
fi

export LC_ALL=C

readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
readonly TAG_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
readonly NET_RE='^[A-Za-z0-9][A-Za-z0-9_.-]{0,62}$'
readonly NUM_RE='^[0-9]+$'
readonly HOST_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$'
readonly TOKEN_MAX=1024
readonly YAML_MAX=16384
readonly REGISTRY_HOST="ghcr.io"
readonly REGISTRY_USER="github-actions"
readonly IMAGE_NS="ghcr.io/gpropersi/apps"

NETWORK="${DEPLOY_NETWORK:-platform}"
SECRETS_ROOT="${DEPLOY_SECRETS_ROOT:-/var/lib/platform/secrets}"
JOB_SECRETS_ROOT="${DEPLOY_JOB_SECRETS_ROOT:-/var/lib/platform/job-secrets}"
STATE_ROOT="${DEPLOY_STATE_ROOT:-/var/lib/platform/deploy}"
REGISTRY_ROOT="${DEPLOY_REGISTRY_ROOT:-/var/lib/platform/registry}"
LOCK_DIR="${DEPLOY_LOCK_DIR:-/var/lib/platform/locks}"
CONNECTION_ENV="${DEPLOY_CONNECTION_ENV:-/opt/platform/data/connection.env}"
SKIP_REGISTRY="${DEPLOY_SKIP_REGISTRY:-0}"
VALIDATOR="${DEPLOY_VALIDATOR:-/opt/platform/deploy/registry/validate-app-yaml.sh}"
LOCK_WAIT="${DEPLOY_LOCK_WAIT:-30}"
EXEC_TIMEOUT="${DEPLOY_EXEC_TIMEOUT:-30}"
PULL_TIMEOUT="${DEPLOY_PULL_TIMEOUT:-300}"
STOP_TIMEOUT="${DEPLOY_STOP_TIMEOUT:-30}"
STALE_TMP_MIN="${DEPLOY_STALE_TMP_MIN:-60}"
HEALTH_WAIT="${DEPLOY_HEALTH_WAIT:-60}"
NOPATH_WAIT="${DEPLOY_NOPATH_WAIT:-10}"
POLL="${DEPLOY_POLL_INTERVAL:-1}"

APP=""
TAG=""
TOKEN=""
TMPD=""
ERRF=""
LOCKFD=""
YAML=""
FLAT=""
MEMCAP=""
PORT=""
HEALTH_PATH=""
PG_HOST=""
PG_PORT=""
RD_HOST=""
RD_PORT=""
IMAGE_REPO=""
REF=""
C_NEW=""
C_OLD=""
PHASE_OUT=""
PHASE_RC=0
CUR_PHASE="start"
CUR_START=0
ORIG_PRESENT=0
RENAMED=0
NEW_RUN=0
SWAP_OPEN=0
MODE="deploy"
PULLED=0

err() { printf '%s\n' "$1" >&2 || true; }

# mask <text>: the text with the pull token (when known) replaced.
mask() {
  local s="$1"
  [ -z "$TOKEN" ] || s="${s//"$TOKEN"/***}"
  printf '%s' "$s"
}

log() {
  local msg
  msg="$(mask "$*")"
  printf '%s deploy app=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${APP:-?}" "$msg" >&2 || true
  logger -t platform -- "deploy app=${APP:-?} $msg" 2>/dev/null || true
}

# fail <phase> <message>: a refusal or failure naming the phase; exit 1.
fail() {
  log "phase=$1 end rc=1 FAILED $2"
  err "deploy: phase '$1' failed: $(mask "$2")"
  exit 1
}

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
cleanup() {
  local rc=$?
  # An interrupted swap or health phase puts the old container back before the temp dir (ERRF) goes.
  if [ "$SWAP_OPEN" -eq 1 ] && [ -n "$TMPD" ]; then
    restore_old
  fi
  # A failed deploy drops the image it pulled unless it is the current or previous one. A commit failure leaves the new
  # container running, so its image is left alone.
  if [ "$rc" -ne 0 ] && [ "$PULLED" -eq 1 ] && [ "$CUR_PHASE" != commit ] && [ -n "$TMPD" ]; then
    PULLED=0
    prune_images new
  fi
  [ -z "$TMPD" ] || rm -rf -- "$TMPD"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
trap 'exit 131' QUIT
# A dropped ssh session must not kill a deploy mid-swap (bash dies on SIGPIPE without running the EXIT trap): ignore it, and
# let log/err tolerate the failed write.
trap '' PIPE

step_begin() {
  CUR_PHASE="$1"
  CUR_START=$SECONDS
  log "phase=$1 start"
}
step_end() { log "phase=$CUR_PHASE end rc=0 dur=$((SECONDS - CUR_START))s"; }

# try_phase <timeout> <name> <stdin text> <cmd...>: runs the command under timeout with the text on stdin; sets PHASE_OUT
# (stdout) and PHASE_RC. Never exits; a failure is logged with the masked error text.
try_phase() {
  local tmo="$1" name="$2" input="$3" start errtext lab
  shift 3
  case "${2:-}" in
    image | container | network) lab="${1##*/} $2 ${3:-}" ;;
    *) lab="${1##*/} ${2:-}" ;;
  esac
  lab="${lab%% -*}"
  PHASE_RC=0
  log "phase=$name cmd=$lab start"
  start=$SECONDS
  : >"$ERRF"
  PHASE_OUT="$(timeout "$tmo" "$@" 2>"$ERRF" <<<"$input")" || PHASE_RC=$?
  if [ "$PHASE_RC" -ne 0 ]; then
    errtext="$(mask "$(head -c 1000000 "$ERRF" | tr '\n' ' ') $(printf '%s' "$PHASE_OUT" | head -c 100000 | tr '\n' ' ')")"
    errtext="${errtext:0:2000}"
    if [ "$PHASE_RC" -eq 124 ]; then
      log "phase=$name cmd=$lab end rc=124 dur=$((SECONDS - start))s FAILED timed out after ${tmo}s"
    else
      log "phase=$name cmd=$lab end rc=$PHASE_RC dur=$((SECONDS - start))s FAILED err=${errtext:-none}"
    fi
    return 0
  fi
  log "phase=$name cmd=$lab end rc=0 dur=$((SECONDS - start))s"
}

# phase_t <timeout> <name> <stdin text> <cmd...>: try_phase that exits 1 naming the phase on a failure.
phase_t() {
  local name="$2"
  try_phase "$@"
  if [ "$PHASE_RC" -ne 0 ]; then
    if [ "$PHASE_RC" -eq 124 ]; then
      err "deploy: phase '$name' failed: timed out after ${1}s"
    else
      err "deploy: phase '$name' failed (rc $PHASE_RC); see the log lines above"
    fi
    exit 1
  fi
}

phase() { # <name> <stdin text> <cmd...>
  local name="$1" input="$2"
  shift 2
  phase_t "$EXEC_TIMEOUT" "$name" "$input" "$@"
}

# quiet <cmd...>: rc of the command under the docker timeout, no output and no log line (an existence probe).
quiet() { timeout "$EXEC_TIMEOUT" "$@" >/dev/null 2>&1 </dev/null; }

# ctr_exists <name>: 0 when the container exists, 1 only when the daemon says "No such"; any other probe failure (daemon
# error, timeout) fails the deploy before it touches anything, so a failed probe is never read as "absent".
ctr_exists() {
  local rc=0 errtext
  errtext="$(timeout "$EXEC_TIMEOUT" docker container inspect "$1" 2>&1 >/dev/null </dev/null)" || rc=$?
  [ "$rc" -ne 0 ] || return 0
  case "$errtext" in
    *[Nn]o\ such*) return 1 ;;
  esac
  log "phase=swap probe of $1 failed rc=$rc err=$(printf '%s' "$errtext" | head -c 500 | tr '\n' ' ')"
  fail swap "cannot tell whether container $1 exists (probe rc $rc); nothing was changed"
}

# ---- 1. input ----

# init_tmp: the private temp dir (removed on every exit path), the error file and a private DOCKER_CONFIG.
init_tmp() {
  # A run killed by SIGKILL (OOM, power loss) never ran its EXIT trap and leaves its dir, and the pull token with it while
  # login+pull ran: remove this user's own dirs from dead runs (a live run is minutes old, the limit is an hour).
  find "${TMPDIR:-/tmp}" -maxdepth 1 -type d -name 'platform-deploy.*' -user "$(id -u)" -mmin +"$STALE_TMP_MIN" \
    -exec rm -rf -- {} + 2>/dev/null || true
  TMPD="$(mktemp -d -t platform-deploy.XXXXXX)"
  ERRF="$TMPD/err"
  : >"$ERRF"
  mkdir -m 0700 -- "$TMPD/$APP" "$TMPD/dockercfg"
  YAML="$TMPD/$APP/app.yaml"
  export DOCKER_CONFIG="$TMPD/dockercfg"
}

read_input() {
  local line_rc=0 size
  step_begin input
  init_tmp
  # Line 1 is the token. read -n stops at the newline or after one more byte than allowed.
  IFS= read -r -n $((TOKEN_MAX + 1)) TOKEN || line_rc=$?
  if [ "$line_rc" -ne 0 ]; then
    TOKEN=""
    fail input "stdin has no token line (a token line ending in a newline, then app.yaml, is required)"
  fi
  if [ "${#TOKEN}" -gt "$TOKEN_MAX" ]; then
    TOKEN=""
    fail input "the token line is over $TOKEN_MAX bytes"
  fi
  [ -n "$TOKEN" ] || fail input "the token line is empty"
  head -c $((YAML_MAX + 1)) >"$YAML" || fail input "cannot read app.yaml from stdin"
  size="$(stat -c %s -- "$YAML")"
  [ "$size" -gt 0 ] || fail input "app.yaml is empty or missing"
  [ "$size" -le "$YAML_MAX" ] || fail input "app.yaml is over $YAML_MAX bytes"
  step_end
}

# ---- 2. validate ----

validate() {
  local lib out
  step_begin validate
  [ -f "$VALIDATOR" ] && [ -r "$VALIDATOR" ] || fail validate "the validator $VALIDATOR is missing: run \`make host-deploy-user HOST=<alias> ARGS=install\`"
  lib="$(dirname "$VALIDATOR")/../lib/yaml-subset.sh"
  [ -r "$lib" ] || fail validate "the yaml reader $lib is missing: run \`make host-deploy-user HOST=<alias> ARGS=install\`"
  try_phase "$EXEC_TIMEOUT" validate "" "$VALIDATOR" "$YAML"
  if [ "$PHASE_RC" -ne 0 ]; then
    out="$(printf '%s' "$PHASE_OUT" | head -c 2000 | tr '\n' ' ')"
    fail validate "app.yaml refused: ${out:-validator rc $PHASE_RC}"
  fi
  FLAT="$TMPD/flat.tsv"
  # shellcheck disable=SC1090
  . "$lib"
  ys_flatten <"$YAML" >"$FLAT" 2>"$ERRF" || fail validate "app.yaml is outside the supported YAML subset"
  MEMCAP="$(ys_get "$FLAT" memory_cap)"
  PORT="$(ys_get "$FLAT" port)"
  HEALTH_PATH="$(ys_get "$FLAT" health_path)"
  [[ "$MEMCAP" =~ ^[1-9][0-9]{0,2}m$ ]] || fail validate "memory_cap '$MEMCAP' is not usable"
  [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || fail validate "port '$PORT' is not usable"
  [ "$(ys_get "$FLAT" name)" = "$APP" ] || fail validate "app.yaml name does not match the app '$APP'"
  step_end
}

# ---- 3. preflight ----

take_lock() {
  local lock old
  [ -z "$LOCKFD" ] || return 0 # already held (rollback takes it before reading previous/)
  [ -d "$LOCK_DIR" ] && [ ! -L "$LOCK_DIR" ] || fail preflight "the lock directory $LOCK_DIR is missing or not a directory: run \`make host-data HOST=<alias> ARGS=install\`"
  lock="$LOCK_DIR/$APP.lock"
  [ ! -L "$lock" ] || fail preflight "the lock path $lock is a symlink"
  # Created under umask 077 and opened for append: the owner can always reopen it for the next run.
  old="$(umask)"
  umask 077
  exec {LOCKFD}>>"$lock" || { umask "$old"; fail preflight "cannot open the lock file $lock"; }
  umask "$old"
  log "phase=lock start wait=${LOCK_WAIT}s"
  if ! flock -w "$LOCK_WAIT" "$LOCKFD"; then
    log "phase=lock end rc=1 FAILED another run for this app holds $lock"
    err "deploy: phase 'lock' failed: another deploy or rollback for '$APP' holds the lock after ${LOCK_WAIT}s. Nothing was changed."
    exit 1
  fi
  log "phase=lock end rc=0"
}

# env_value <key>: the value of KEY=VALUE from connection.env (last one wins), parsed, never sourced.
env_value() {
  local line v=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$1="*) v="${line#"$1="}" ;; *) ;; esac
  done <"$CONNECTION_ENV"
  printf '%s' "$v"
}

preflight() {
  step_begin preflight
  take_lock
  [ -d "$SECRETS_ROOT/$APP" ] && [ ! -L "$SECRETS_ROOT/$APP" ] || fail preflight "no secrets dir $SECRETS_ROOT/$APP: run \`platform new-db $APP\` first"
  [ -d "$JOB_SECRETS_ROOT/$APP" ] && [ ! -L "$JOB_SECRETS_ROOT/$APP" ] || fail preflight "no job-secrets dir $JOB_SECRETS_ROOT/$APP: run \`platform new-db $APP\` first"
  quiet docker network inspect "$NETWORK" || fail preflight "the docker network '$NETWORK' does not exist"
  command -v curl >/dev/null 2>&1 || fail preflight "curl is not installed"
  [ -d "$STATE_ROOT" ] && [ ! -L "$STATE_ROOT" ] && [ -w "$STATE_ROOT" ] || fail preflight "the deploy state root $STATE_ROOT is missing or not writable by this user: run \`make host-deploy-user HOST=<alias> ARGS=install\`"
  [ -d "$REGISTRY_ROOT" ] && [ ! -L "$REGISTRY_ROOT" ] && [ -w "$REGISTRY_ROOT" ] || fail preflight "the registry root $REGISTRY_ROOT is missing or not writable by this user: run \`make host-jobs HOST=<alias> ARGS=install\`"
  [ -f "$CONNECTION_ENV" ] && [ -r "$CONNECTION_ENV" ] || fail preflight "the connection file $CONNECTION_ENV is missing: run \`make host-data HOST=<alias> ARGS=install\`"
  PG_HOST="$(env_value PLATFORM_PG_HOST)"
  PG_PORT="$(env_value PLATFORM_PG_PORT)"
  RD_HOST="$(env_value PLATFORM_REDIS_HOST)"
  RD_PORT="$(env_value PLATFORM_REDIS_PORT)"
  [[ "$PG_HOST" =~ $HOST_RE ]] && [[ "$RD_HOST" =~ $HOST_RE ]] || fail preflight "$CONNECTION_ENV has no valid PLATFORM_PG_HOST / PLATFORM_REDIS_HOST"
  [[ "$PG_PORT" =~ ^[1-9][0-9]{0,4}$ ]] && [[ "$RD_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || fail preflight "$CONNECTION_ENV has no valid PLATFORM_PG_PORT / PLATFORM_REDIS_PORT"
  step_end
}

# ---- 4. pull ----

pull() {
  local line ref="" tagged
  step_begin pull
  tagged="$IMAGE_REPO:$TAG"
  if [ "$SKIP_REGISTRY" = 1 ]; then
    log "phase=pull registry skipped (DEPLOY_SKIP_REGISTRY=1): using the local image"
    try_phase "$EXEC_TIMEOUT" pull "" docker image inspect --format '{{.Id}}' "$tagged"
    [ "$PHASE_RC" -eq 0 ] || fail pull "the local image $tagged is not present"
    ref="$PHASE_OUT"
    [[ "$ref" =~ ^sha256:[0-9a-f]{64}$ ]] || fail pull "the local image $tagged has no usable image ID"
  else
    phase_t "$PULL_TIMEOUT" pull "$TOKEN" docker login "$REGISTRY_HOST" --username "$REGISTRY_USER" --password-stdin
    phase_t "$PULL_TIMEOUT" pull "" docker pull "$tagged"
    # The token sits on disk (config.json) only for login+pull: nothing later needs the registry, and a SIGKILL after
    # this point must not leave it behind.
    rm -f -- "$DOCKER_CONFIG/config.json"
    try_phase "$EXEC_TIMEOUT" pull "" docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$tagged"
    [ "$PHASE_RC" -eq 0 ] || fail pull "cannot read the digest of $tagged"
    while IFS= read -r line; do
      if [[ "$line" =~ ^${IMAGE_REPO//./\\.}@sha256:[0-9a-f]{64}$ ]]; then
        ref="$line"
        break
      fi
    done <<<"$PHASE_OUT"
    [ -n "$ref" ] || fail pull "the pull of $tagged yielded no digest"
  fi
  REF="$ref"
  PULLED=1
  log "phase=pull resolved reference $REF"
  step_end
}

# ---- 5. inspect ----

inspect_image() {
  local want_arch got_arch user uid labels k want_ports
  step_begin inspect
  try_phase "$EXEC_TIMEOUT" inspect "" docker version --format '{{.Server.Arch}}'
  [ "$PHASE_RC" -eq 0 ] || fail inspect "cannot read the docker daemon architecture"
  want_arch="$PHASE_OUT"
  try_phase "$EXEC_TIMEOUT" inspect "" docker image inspect --format '{{.Architecture}}' "$REF"
  [ "$PHASE_RC" -eq 0 ] || fail inspect "cannot inspect the image $REF"
  got_arch="$PHASE_OUT"
  { [ -n "$want_arch" ] && [ "$got_arch" = "$want_arch" ]; } || fail inspect "the image architecture '$got_arch' is not the daemon's '$want_arch'"

  try_phase "$EXEC_TIMEOUT" inspect "" docker image inspect --format '{{.Config.User}}' "$REF"
  [ "$PHASE_RC" -eq 0 ] || fail inspect "cannot read the image user"
  user="$PHASE_OUT"
  uid="${user%%:*}"
  [[ "$uid" =~ ^[0-9]{1,9}$ ]] || fail inspect "the image USER '$user' is not a numeric uid"
  [ "$((10#$uid))" -ne 0 ] || fail inspect "the image USER '$user' is root"

  # shellcheck disable=SC2016 # a Go template, not a shell expansion
  try_phase "$EXEC_TIMEOUT" inspect "" docker image inspect --format '{{range $k, $v := .Config.Labels}}{{println $k}}{{end}}' "$REF"
  [ "$PHASE_RC" -eq 0 ] || fail inspect "cannot read the image labels"
  labels="$PHASE_OUT"
  while IFS= read -r k; do
    k="${k,,}"
    case "$k" in
      traefik.* | platform.*) fail inspect "the image carries a reserved label ($k)" ;;
      *) ;;
    esac
  done <<<"$labels"

  # shellcheck disable=SC2016 # a Go template, not a shell expansion
  try_phase "$EXEC_TIMEOUT" inspect "" docker image inspect --format '{{range $p, $v := .Config.ExposedPorts}}{{println $p}}{{end}}' "$REF"
  [ "$PHASE_RC" -eq 0 ] || fail inspect "cannot read the image exposed ports"
  want_ports="$PORT/tcp"
  [ "$PHASE_OUT" = "$want_ports" ] || fail inspect "the image must expose exactly $want_ports (it exposes: ${PHASE_OUT:-nothing})"
  step_end
}

# ---- 6. swap ----

# restore_old: undo a failed swap or health phase. Best effort; each step is logged.
restore_old() {
  local bad=0
  SWAP_OPEN=0
  log "restoring the previous container"
  # The new container is removed only when the name is known to be ours: no original existed, or it was renamed away.
  if [ "$NEW_RUN" -eq 1 ] && { [ "$ORIG_PRESENT" -eq 0 ] || [ "$RENAMED" -eq 1 ]; }; then
    try_phase "$EXEC_TIMEOUT" swap "" docker rm -f -v "$C_NEW"
    [ "$PHASE_RC" -eq 0 ] || bad=1
  fi
  if [ "$RENAMED" -eq 1 ]; then
    try_phase "$EXEC_TIMEOUT" swap "" docker rename "$C_OLD" "$C_NEW"
    [ "$PHASE_RC" -eq 0 ] || bad=1
  fi
  if [ "$ORIG_PRESENT" -eq 1 ]; then
    try_phase "$EXEC_TIMEOUT" swap "" docker start "$C_NEW"
    [ "$PHASE_RC" -eq 0 ] || bad=1
  fi
  if [ "$bad" -eq 1 ]; then
    err "deploy: THE PREVIOUS CONTAINER MAY NOT BE RESTORED: check app-$APP and app-$APP-old by hand; the next deploy reconciles"
  fi
}

# fail_restore <phase> <message>: restore the old container, then fail.
fail_restore() {
  restore_old
  fail "$1" "$2"
}

# swap_step <cmd...>: a swap-phase docker call; on failure restore and fail.
swap_step() {
  try_phase "$EXEC_TIMEOUT" swap "" "$@"
  [ "$PHASE_RC" -eq 0 ] || fail_restore swap "$2 failed (rc $PHASE_RC)"
}

swap() {
  step_begin swap
  C_NEW="app-$APP"
  C_OLD="app-$APP-old"
  ORIG_PRESENT=0
  RENAMED=0
  NEW_RUN=0
  SWAP_OPEN=1
  # A leftover -old from an interrupted deploy: restore it when the live name is free, else drop it.
  if ctr_exists "$C_OLD"; then
    if ctr_exists "$C_NEW"; then
      swap_step docker rm -f -v "$C_OLD"
    else
      swap_step docker rename "$C_OLD" "$C_NEW"
    fi
  fi
  if ctr_exists "$C_NEW"; then
    ORIG_PRESENT=1
    try_phase $((STOP_TIMEOUT + 10)) swap "" docker stop -t "$STOP_TIMEOUT" "$C_NEW"
    [ "$PHASE_RC" -eq 0 ] || fail_restore swap "stopping $C_NEW failed (rc $PHASE_RC)"
    swap_step docker rename "$C_NEW" "$C_OLD"
    RENAMED=1
  fi
  local -a run=(docker run -d --name "$C_NEW" --label "platform.app=$APP" --network "$NETWORK" --network-alias "$APP"
    --group-add 64323 --group-add 64324 --cap-drop ALL --security-opt no-new-privileges:true --read-only --tmpfs /tmp
    --memory "$MEMCAP" --memory-swap "$MEMCAP" --pids-limit 256 --restart unless-stopped
    -v "$SECRETS_ROOT/$APP:/run/platform/secrets:ro" -v "$JOB_SECRETS_ROOT/$APP:/run/platform/job-secrets:ro"
    -e "DB_HOST=$PG_HOST" -e "DB_PORT=$PG_PORT" -e "DB_NAME=${APP//-/_}" -e "DB_USER=${APP//-/_}"
    -e "DB_PASSWORD_FILE=/run/platform/secrets/db-password"
    -e "REDIS_HOST=$RD_HOST" -e "REDIS_PORT=$RD_PORT" -e "REDIS_USER=$APP"
    -e "REDIS_PASSWORD_FILE=/run/platform/secrets/redis-password" -e "REDIS_KEY_PREFIX=$APP:"
    -e "JOBS_SECRET_FILE=/run/platform/job-secrets/jobs-secret"
    "$REF")
  NEW_RUN=1
  swap_step "${run[@]}"
  step_end
}

# ---- 7. health ----

container_status() {
  try_phase "$EXEC_TIMEOUT" health "" docker inspect --format '{{.State.Status}}' "$C_NEW"
  [ "$PHASE_RC" -eq 0 ] || return 1
  [ "$PHASE_OUT" = running ]
}

health() {
  local ip="" code i deadline url
  step_begin health
  if [ -z "$HEALTH_PATH" ]; then
    log "phase=health no health_path: the container must stay running for ${NOPATH_WAIT}s"
    for ((i = 0; i < NOPATH_WAIT; i++)); do
      container_status || fail_restore health "the container is not running"
      sleep "$POLL"
    done
    container_status || fail_restore health "the container is not running after ${NOPATH_WAIT}s"
    step_end
    return 0
  fi
  deadline=$((SECONDS + HEALTH_WAIT))
  while true; do
    container_status || fail_restore health "the container is not running"
    try_phase "$EXEC_TIMEOUT" health "" docker inspect --format "{{(index .NetworkSettings.Networks \"$NETWORK\").IPAddress}}" "$C_NEW"
    ip=""
    [ "$PHASE_RC" -ne 0 ] || ip="$PHASE_OUT"
    if [[ "$ip" =~ ^[0-9.]+$ ]]; then
      url="http://$ip:$PORT$HEALTH_PATH"
      try_phase 10 health "" curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$url"
      code="$PHASE_OUT"
      if [ "$PHASE_RC" -eq 0 ] && [[ "$code" =~ ^2[0-9][0-9]$ ]]; then
        step_end
        return 0
      fi
      log "phase=health probe ${HEALTH_PATH} -> ${code:-no reply}"
    fi
    [ "$SECONDS" -lt "$deadline" ] || fail_restore health "no 2xx from ${HEALTH_PATH} within ${HEALTH_WAIT}s"
    sleep "$POLL"
  done
}

# ---- 8. commit ----

# put_file <dest> <src>: copy next to the destination, then an atomic rename.
put_file() {
  local dest="$1" src="$2" tmp
  tmp="${dest%/*}/.tmp.${dest##*/}.$$"
  cp -- "$src" "$tmp" || return 1
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; return 1; }
}

# Known crash window (accepted): a SIGKILL or power loss between "mv prev previous" / "mv current gone" and "mv new current"
# in commit_state can leave previous/ equal to current/ after the recovery below (the older real previous is lost). The
# next successful deploy restores a good previous/.
# clear_stale <base>: leftovers of an interrupted commit (other pids' .new/.prev/.old/.gone dirs), removed under the lock. A
# missing current/ or previous/ is first put back from a leftover .gone / .old, which is the directory a crash orphaned.
clear_stale() {
  local base="$1" d
  if [ ! -d "$base/current" ]; then
    for d in "$base"/.gone.*; do
      [ -d "$d" ] || continue
      mv -- "$d" "$base/current" && break
    done
  fi
  # previous/ is orphaned by a deploy commit (.old) or by a rollback exchange (.gone) that died between its moves.
  if [ ! -d "$base/previous" ] && [ -d "$base/current" ]; then
    for d in "$base"/.old.* "$base"/.gone.*; do
      [ -d "$d" ] || continue
      mv -- "$d" "$base/previous" && break
    done
  fi
  rm -rf -- "$base"/.new.* "$base"/.prev.* "$base"/.old.* "$base"/.gone.*
}

# rollback_state: exchange current/ and previous/ (three moves, each undone on a later failure). Returns 1 with the state
# as it was, so a failed rollback never loses either version.
rollback_state() {
  local base="$STATE_ROOT/$APP" gone="$STATE_ROOT/$APP/.gone.$$"
  clear_stale "$base"
  [ -d "$base/current" ] && [ -d "$base/previous" ] || return 1
  mv -- "$base/current" "$gone" || return 1
  if ! mv -- "$base/previous" "$base/current"; then
    mv -- "$gone" "$base/current" || true
    return 1
  fi
  if ! mv -- "$gone" "$base/previous"; then
    mv -- "$base/current" "$base/previous" || true
    mv -- "$gone" "$base/current" || true
    return 1
  fi
  return 0
}

# commit_state: <state>/<app>/current becomes the new deploy, previous the old current when the tag differs. Returns 1
# with every move undone, so previous is never advanced by a failed commit.
commit_state() {
  local base="$STATE_ROOT/$APP" new prev old gone cur_tag="" advance=0 s1=0 s2=0 s3=0
  new="$base/.new.$$"
  prev="$base/.prev.$$"
  old="$base/.old.$$"
  gone="$base/.gone.$$"
  mkdir -p -- "$base" || return 1
  clear_stale "$base"
  rm -rf -- "$new" "$prev" "$old" "$gone"
  mkdir -- "$new" || return 1
  { printf '%s\n' "$TAG" >"$new/tag" &&
      printf '%s\n' "$REF" >"$new/digest" &&
      date -u +%Y-%m-%dT%H:%M:%SZ >"$new/deployed-at" &&
      cp -- "$YAML" "$new/app.yaml"; } || { rm -rf -- "$new"; return 1; }
  if [ -d "$base/current" ]; then
    [ ! -f "$base/current/tag" ] || cur_tag="$(<"$base/current/tag")"
    if [ "$cur_tag" != "$TAG" ]; then
      advance=1
      cp -a -- "$base/current" "$prev" || { rm -rf -- "$new" "$prev"; return 1; }
    fi
  fi
  if [ "$advance" -eq 1 ]; then
    if [ -d "$base/previous" ]; then
      mv -- "$base/previous" "$old" || { rm -rf -- "$new" "$prev"; return 1; }
      s1=1
    fi
    if mv -- "$prev" "$base/previous"; then s2=1; else
      [ "$s1" -eq 0 ] || mv -- "$old" "$base/previous" || true
      rm -rf -- "$new" "$prev"
      return 1
    fi
  fi
  if [ -d "$base/current" ]; then
    if mv -- "$base/current" "$gone"; then s3=1; else
      state_undo "$base" "$old" "$s1" "$s2" "$s3" "$gone"
      rm -rf -- "$new" "$prev"
      return 1
    fi
  fi
  if ! mv -- "$new" "$base/current"; then
    state_undo "$base" "$old" "$s1" "$s2" "$s3" "$gone"
    rm -rf -- "$new" "$prev"
    return 1
  fi
  rm -rf -- "$old" "$gone"
  return 0
}

# state_undo <base> <old> <s1> <s2> <s3> <gone>: reverse the moves already done by commit_state.
state_undo() {
  local base="$1" old="$2" s1="$3" s2="$4" s3="$5" gone="$6"
  [ "$s3" -eq 0 ] || mv -- "$gone" "$base/current" || true
  [ "$s2" -eq 0 ] || rm -rf -- "$base/previous"
  [ "$s1" -eq 0 ] || mv -- "$old" "$base/previous" || true
}

commit() {
  local regdir="$REGISTRY_ROOT/$APP" rc
  step_begin commit
  SWAP_OPEN=0
  if ! { (umask 022 && mkdir -p -- "$regdir") && (umask 022 && put_file "$regdir/app.yaml" "$YAML"); }; then
    log "phase=commit the registry write failed; the new container keeps running, the old one is not removed"
    fail commit "cannot write $regdir/app.yaml; the next deploy reconciles"
  fi
  # Ordering (accepted): the registry app.yaml is written before rollback_state, so a failed state exchange leaves
  # "platform current" recording the newer failed tag while the older version runs; the next deploy reconciles.
  rc=0
  if [ "$MODE" = rollback ]; then
    (umask 022 && rollback_state) || rc=$?
  else
    (umask 022 && commit_state) || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    log "phase=commit the deploy-state write failed; the new container keeps running, the old one is not removed"
    fail commit "cannot write the deploy state under $STATE_ROOT/$APP; the next deploy reconciles"
  fi
  if [ "$RENAMED" -eq 1 ]; then
    try_phase "$EXEC_TIMEOUT" commit "" docker rm -f -v "$C_OLD"
    [ "$PHASE_RC" -eq 0 ] || log "phase=commit warning: could not remove $C_OLD; the next deploy removes it"
  fi
  step_end
}

# ---- rollback: load the previous deploy ----

load_previous() {
  local p="$STATE_ROOT/$APP/previous" size
  step_begin previous
  { [ -d "$p" ] && [ ! -L "$p" ] && [ -f "$p/tag" ] && [ -f "$p/digest" ] && [ -f "$p/app.yaml" ]; } || fail previous "no previous deploy"
  TAG="$(<"$p/tag")"
  REF="$(<"$p/digest")"
  [[ "$TAG" =~ $TAG_RE ]] || fail previous "the recorded previous tag is not usable"
  [[ "$REF" =~ ^sha256:[0-9a-f]{64}$ || "$REF" =~ ^${IMAGE_REPO//./\\.}@sha256:[0-9a-f]{64}$ ]] || fail previous "the recorded previous image reference is not usable"
  cp -- "$p/app.yaml" "$YAML" || fail previous "cannot read the recorded previous app.yaml"
  size="$(stat -c %s -- "$YAML")"
  { [ "$size" -gt 0 ] && [ "$size" -le "$YAML_MAX" ]; } || fail previous "the recorded previous app.yaml is empty or over $YAML_MAX bytes"
  log "phase=previous rolling back to tag=$TAG ref=$REF"
  step_end
}

# ---- cleanup ----

# prune_images <all|new>: remove this app's local images other than the current and previous deploys' (compared by image
# ID, resolved from the recorded references). `new` removes only the image REF resolves to, when it is neither. Only this
# app's repository is listed, and a plain `docker rmi` (no -f) refuses an image a container uses. A failure is a warning.
prune_images() {
  local mode="$1" keep=" " only="" f d id repo tag dig ref gone=" " listing
  for f in current previous; do
    [ -d "$STATE_ROOT/$APP/$f" ] || continue
    d="$(<"$STATE_ROOT/$APP/$f/digest")" || d=""
    if ! { [[ "$d" =~ ^sha256:[0-9a-f]{64}$ ]] || [[ "$d" =~ ^${IMAGE_REPO//./\\.}@sha256:[0-9a-f]{64}$ ]]; }; then
      log "phase=cleanup warning: $f/digest is not a usable reference; no image was removed"
      return 0
    fi
    try_phase "$EXEC_TIMEOUT" cleanup "" docker image inspect --format '{{.Id}}' "$d"
    if [ "$PHASE_RC" -eq 0 ]; then
      keep+="$PHASE_OUT "
    else
      case "$(head -c 2000 "$ERRF")" in
        *[Nn]o\ such*) ;; # the recorded image is simply not local
        *)
          log "phase=cleanup warning: cannot resolve the $f image; no image was removed"
          return 0
          ;;
      esac
    fi
  done
  if [ "$mode" = new ]; then
    try_phase "$EXEC_TIMEOUT" cleanup "" docker image inspect --format '{{.Id}}' "$REF"
    if [ "$PHASE_RC" -ne 0 ]; then
      log "phase=cleanup warning: cannot resolve the pulled image; it was not removed"
      return 0
    fi
    only="$PHASE_OUT"
    case "$keep" in *" $only "*) return 0 ;; *) ;; esac
  fi
  try_phase "$EXEC_TIMEOUT" cleanup "" docker image ls --no-trunc --digests --format '{{.ID}} {{.Repository}} {{.Tag}} {{.Digest}}' "$IMAGE_REPO"
  if [ "$PHASE_RC" -ne 0 ]; then
    log "phase=cleanup warning: cannot list the images of $IMAGE_REPO; none was removed"
    return 0
  fi
  listing="$PHASE_OUT"
  while read -r id repo tag dig; do
    [ -n "$id" ] && [ "$repo" = "$IMAGE_REPO" ] || continue
    case "$keep" in *" $id "*) continue ;; *) ;; esac
    [ -z "$only" ] || [ "$id" = "$only" ] || continue
    if [ "$tag" != "<none>" ]; then
      ref="$repo:$tag"
    elif [ "$dig" != "<none>" ]; then
      case "$gone" in *" $id "*) continue ;; *) ;; esac
      ref="$repo@$dig"
    else
      continue
    fi
    try_phase "$EXEC_TIMEOUT" cleanup "" docker rmi "$ref"
    if [ "$PHASE_RC" -eq 0 ]; then
      gone+="$id "
    else
      log "phase=cleanup warning: could not remove $ref"
    fi
  done <<<"$listing"
  log "phase=cleanup done (mode $mode)"
}

main() {
  case "${1:-}" in
    deploy) [ "$#" -eq 3 ] || { err "usage: deploy.sh deploy <app> <tag> | deploy.sh rollback <app>"; exit 2; } ;;
    rollback) [ "$#" -eq 2 ] || { err "usage: deploy.sh deploy <app> <tag> | deploy.sh rollback <app>"; exit 2; } ;;
    *) err "usage: deploy.sh deploy <app> <tag> | deploy.sh rollback <app>"; exit 2 ;;
  esac
  MODE="$1"
  APP="$2"
  TAG="${3:-}"
  [[ "$APP" =~ $APP_RE ]] || { err "deploy: invalid app name (want $APP_RE)"; exit 2; }
  [ "$MODE" = rollback ] || [[ "$TAG" =~ $TAG_RE ]] || { err "deploy: invalid tag (want $TAG_RE)"; exit 2; }
  IMAGE_REPO="$IMAGE_NS/$APP"
  [[ "$NETWORK" =~ $NET_RE ]] || { err "deploy: DEPLOY_NETWORK is not a valid network name"; exit 2; }
  local v
  for v in "$LOCK_WAIT" "$EXEC_TIMEOUT" "$PULL_TIMEOUT" "$STOP_TIMEOUT" "$STALE_TMP_MIN" "$HEALTH_WAIT" "$NOPATH_WAIT"; do
    [[ "$v" =~ $NUM_RE ]] || { err "deploy: a DEPLOY_* wait or timeout is not a whole number of seconds"; exit 2; }
  done
  # timeout 0 would disable the limit, so the two docker call limits need at least 1.
  [[ "$EXEC_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ && "$PULL_TIMEOUT" =~ ^[1-9][0-9]{0,4}$ ]] || { err "deploy: DEPLOY_EXEC_TIMEOUT and DEPLOY_PULL_TIMEOUT must be 1 to 99999 seconds"; exit 2; }
  if [ "$MODE" = rollback ]; then
    log "start rollback"
    init_tmp
    take_lock
    clear_stale "$STATE_ROOT/$APP"
    load_previous
    validate
    preflight
  else
    log "start tag=$TAG"
    read_input
    validate
    preflight
    pull
  fi
  inspect_image
  swap
  health
  commit
  prune_images all
  log "end rc=0"
  if [ "$MODE" = rollback ]; then
    printf 'rollback: done %s %s\n' "$APP" "$TAG"
  else
    printf 'deploy: done %s %s\n' "$APP" "$TAG"
  fi
}

main "$@"
