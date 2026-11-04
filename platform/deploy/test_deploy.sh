#!/usr/bin/env bash
# Stub tests for deploy.sh. The docker stub is stateful: containers are files under $STATE/ctr (status in <name>, image in
# <name>.img), the last `docker run` argv is kept in $STATE/run.argv, and failure switches are files $STATE/fail_<key>
# holding the exit code (keys: login pull digest network run stop rename). curl, sleep, mv and logger are stubs too. The
# secrets, state, registry, lock and connection roots are real temp directories reached through the DEPLOY_* hooks, and
# the validator is the tracked registry validator, so a wrong app.yaml is refused by the real rules.
#
# Every refusal case starts from the same snapshot (a first deploy of alpha at tag v1 already live) and asserts that the
# running app, the registry entry and the deploy state are untouched and that no docker mutation was made.
#
# No real credentials: the token and passwords below are fake fixture strings.
# SC2016: stub bodies are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# SC2154: $out and $rc are set by lib.sh. SC2034: some fixture variables are only read by sub-functions.
# shellcheck disable=SC1091,SC2016,SC2034,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/deploy.sh"
validator="$here/../registry/validate-app-yaml.sh"
REAL_MV="$(command -v mv)"
export REAL_MV

t_init
W="$T_TMP/w"
STATE="$W/stub"
LOGGER_LOG="$T_TMP/logger.log"
INPUT="$T_TMP/input"
YAML="$T_TMP/app.yaml"
IPADDR="$(t_ip4 172 20 0 5)"
TOKEN='tok-Zq7Rm2Xv9Lp4Wk8Nd3Hs6Jt1Bc5Yf0Ga'
DBPW='FAKEDBPASSWORD0123456789abcdefghijklmn'
export STATE LOGGER_LOG IPADDR
XENV=()

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
  } >"$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

# logger and mv are not logged to the call log (the call log is for docker, curl and sleep)
cat >"$STUB_BIN/logger" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$LOGGER_LOG"
exit 0
EOF
cat >"$STUB_BIN/mv" <<'EOF'
#!/usr/bin/env bash
if [ -n "${MV_FAIL:-}" ] && [ ! -e "$STATE/mv_failed" ]; then
  # shellcheck disable=SC2254
  case "${@: -1}" in $MV_FAIL) : >"$STATE/mv_failed"; exit 1 ;; esac
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$STUB_BIN/logger" "$STUB_BIN/mv"

mkstub curl <<'EOF'
if [ -f "$STATE/curl_sleep" ]; then
  : >"$STATE/curl.started"
  /usr/bin/sleep "$(cat "$STATE/curl_sleep")"
fi
[ ! -f "$STATE/curl_rc" ] || exit "$(cat "$STATE/curl_rc")"
if [ -f "$STATE/http_code" ]; then cat "$STATE/http_code"; else printf 200; fi
exit 0
EOF

mkstub docker <<'EOF'
S="$STATE"
sub="$1"
shift
hex() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
failk() { [ -f "$S/fail_$1" ] || return 0; exit "$(cat "$S/fail_$1")"; }
# The token must reach the stub only on stdin: look for it in the environment and in the script's temp tree.
scan_token() {
  [ -f "$S/login.stdin" ] || return 0
  local tok
  tok="$(cat "$S/login.stdin")"
  [ -n "$tok" ] || return 0
  if env | grep -qF -- "$tok"; then echo "env in $sub" >>"$S/leak"; fi
  if grep -rqF -- "$tok" "$TMPDIR" 2>/dev/null; then echo "file in $sub" >>"$S/leak"; fi
}
case "$sub" in
  login)
    printf '%s' "$DOCKER_CONFIG" >"$S/login.cfg"
    [ ! -d "$DOCKER_CONFIG" ] || echo yes >"$S/login.cfg.exists"
    cat >"$S/login.stdin"
    scan_token
    # A real docker login stores the credential in config.json; the later scans (docker run) must find it gone.
    printf '{"auths":{"ghcr.io":{"auth":"%s"}}}' "$(cat "$S/login.stdin")" >"$DOCKER_CONFIG/config.json"
    failk login
    ;;
  pull)
    printf '%s' "$DOCKER_CONFIG" >"$S/pull.cfg"
    : >"$S/pull.started"
    [ ! -f "$DOCKER_CONFIG/config.json" ] || echo yes >"$S/pull.cfg.had"
    [ ! -f "$S/pull_sleep" ] || sleep "$(cat "$S/pull_sleep")"
    if [ -f "$S/fail_pull" ]; then
      printf 'unauthorized: token %s rejected\n' "$(cat "$S/login.stdin" 2>/dev/null)" >&2
      exit "$(cat "$S/fail_pull")"
    fi
    ;;
  version)
    if [ -f "$S/daemon_arch" ]; then cat "$S/daemon_arch"; else echo amd64; fi
    ;;
  network)
    failk network
    ;;
  container)
    if [ -f "$S/probe_error" ]; then
      echo "Cannot connect to the Docker daemon" >&2
      exit 1
    fi
    if [ ! -f "$S/ctr/${*: -1}" ]; then
      echo "Error: No such container: ${*: -1}" >&2
      exit 1
    fi
    ;;
  image)
    if [ "$1" = ls ]; then
      failk imagels
      [ ! -f "$S/images" ] || cat "$S/images"
      exit 0
    fi
    fmt="$3"
    ref="$4"
    printf '%s\n' "$ref" >>"$S/image_refs"
    [ ! -f "${DOCKER_CONFIG:-/nonexistent}/config.json" ] || echo yes >>"$S/cfg_after_pull"
    if [ -f "$S/missing_images" ] && grep -qxF -- "$ref" "$S/missing_images"; then
      echo "Error: No such image: $ref" >&2
      exit 1
    fi
    t="${ref##*:}"
    case "$fmt" in
      *RepoDigests*)
        failk digest
        if [ -f "$S/repodigests" ]; then cat "$S/repodigests"; else echo "${ref%:*}@sha256:$(hex "d$t")"; fi ;;
      *'{{.Id}}'*) echo "sha256:$(hex "i$t")" ;;
      *Architecture*) if [ -f "$S/image_arch" ]; then cat "$S/image_arch"; else echo amd64; fi ;;
      *Config.User*) if [ -f "$S/image_user" ]; then cat "$S/image_user"; else echo 1000; fi ;;
      *Labels*) if [ -f "$S/image_labels" ]; then cat "$S/image_labels"; fi ;;
      *ExposedPorts*) if [ -f "$S/image_ports" ]; then cat "$S/image_ports"; else echo 8080/tcp; fi ;;
      *) echo "unexpected image inspect format: $fmt" >&2; exit 9 ;;
    esac
    ;;
  inspect)
    fmt="$2"
    name="${*: -1}"
    [ -f "$S/ctr/$name" ] || { echo "No such object: $name" >&2; exit 1; }
    case "$fmt" in
      *State.Status*) cat "$S/ctr/$name" ;;
      *IPAddress*) echo "$IPADDR" ;;
      *) echo "unexpected inspect format: $fmt" >&2; exit 9 ;;
    esac
    ;;
  run)
    printf '%s\n' "$@" >"$S/run.argv"
    scan_token
    name=""
    prev=""
    for a in "$@"; do [ "$prev" != --name ] || name="$a"; prev="$a"; done
    failk run
    if [ -f "$S/run_status" ]; then cp "$S/run_status" "$S/ctr/$name"; else echo running >"$S/ctr/$name"; fi
    printf '%s' "${*: -1}" >"$S/ctr/$name.img"
    echo "fakecontainerid"
    ;;
  stop)
    failk stop
    echo exited >"$S/ctr/${*: -1}"
    ;;
  rename)
    failk rename
    mv -f "$S/ctr/$1" "$S/ctr/$2"
    mv -f "$S/ctr/$1.img" "$S/ctr/$2.img"
    ;;
  start)
    failk start
    echo running >"$S/ctr/${*: -1}"
    ;;
  rm)
    failk rm
    rm -f "$S/ctr/${*: -1}" "$S/ctr/${*: -1}.img"
    ;;
  rmi)
    failk rmi
    printf '%s\n' "$1" >>"$S/rmi.log"
    if [ -f "$S/images" ]; then
      awk -v r="$1" '{ ref = $2 ":" $3; if ($3 == "<none>") ref = $2 "@" $4; if (ref != r) print }' "$S/images" >"$S/images.new"
      mv -f "$S/images.new" "$S/images"
    fi
    ;;
  *)
    echo "unexpected docker subcommand: $sub" >&2
    exit 9
    ;;
esac
exit 0
EOF

# ---- fixtures and helpers ----

reset() {
  chmod -R u+w "$W" 2>/dev/null
  rm -rf "$W"
  mkdir -p "$STATE/ctr" "$W/secrets" "$W/jobs" "$W/locks" "$W/dstate" "$W/reg" "$W/tmp"
  printf 'PLATFORM_PG_HOST=postgres\nPLATFORM_PG_PORT=5432\nPLATFORM_REDIS_HOST=redis\nPLATFORM_REDIS_PORT=6379\n' >"$W/conn.env"
  local a
  for a in alpha beta my-app; do
    mkdir -p "$W/secrets/$a" "$W/jobs/$a"
    printf '%s' "$DBPW" >"$W/secrets/$a/db-password"
    printf '%s' "$DBPW" >"$W/jobs/$a/jobs-secret"
  done
  : >"$CALL_LOG"
  : >"$LOGGER_LOG"
  XENV=()
}

snap_save() {
  rm -rf "$T_TMP/snap"
  cp -a "$W" "$T_TMP/snap"
}

snap_load() {
  chmod -R u+w "$W" 2>/dev/null
  rm -rf "$W"
  cp -a "$T_TMP/snap" "$W"
  : >"$CALL_LOG"
  : >"$LOGGER_LOG"
  XENV=()
}

mkyaml() { # <app> [health_path|-] [memory_cap]
  {
    printf 'schema_version: 1\nname: %s\nowner: tester\npurpose: Deploy helper test app\ntemplate: flask\nmemory_cap: %s\nport: 8080\n' "$1" "${3:-64m}"
    [ "${2:-/healthz}" = - ] || printf 'health_path: %s\n' "${2:-/healthz}"
  } >"$YAML"
}

mkinput() { # <token line> <yaml file>
  {
    printf '%s\n' "$1"
    cat "$2"
  } >"$INPUT"
}

run_deploy() { # <args...>: runs deploy.sh with stdin from $INPUT; $out has stdout and stderr
  rc=0
  out="$(env TMPDIR="$W/tmp" DEPLOY_NETWORK=testnet DEPLOY_SECRETS_ROOT="$W/secrets" DEPLOY_JOB_SECRETS_ROOT="$W/jobs" \
    DEPLOY_STATE_ROOT="$W/dstate" DEPLOY_REGISTRY_ROOT="$W/reg" DEPLOY_LOCK_DIR="$W/locks" DEPLOY_CONNECTION_ENV="$W/conn.env" \
    DEPLOY_VALIDATOR="$validator" DEPLOY_HEALTH_WAIT=1 DEPLOY_POLL_INTERVAL=0.2 DEPLOY_LOCK_WAIT=1 DEPLOY_PULL_TIMEOUT=5 \
    "${XENV[@]}" "$script" "$@" 2>&1 <"$INPUT")" || rc=$?
}

deploy_app() { # <app> <tag> [health_path|-]: a deploy with the standard token and a generated app.yaml
  mkyaml "$1" "${3:-/healthz}"
  mkinput "$TOKEN" "$YAML"
  run_deploy deploy "$1" "$2"
}

rd() { if [ -f "$1" ]; then cat "$1"; fi; }
ctr_img() { rd "$STATE/ctr/$1.img"; }
ctr_status() { rd "$STATE/ctr/$1"; }
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
ref_of() { printf 'ghcr.io/gpropersi/apps/%s@sha256:%s' "$1" "$(sha "d$2")"; }
id_of() { printf 'sha256:%s' "$(sha "i$2")"; }

expect_untouched() { # <label>: no docker mutation was made
  local c
  for c in "docker run" "docker stop" "docker rename" "docker rm" "docker start"; do
    expect_calls_lacks "$1: no '$c'" "$c"
  done
}

expect_no_docker() { # <label>
  expect_eq "$1: no docker call at all" "$(grep -c '^docker' "$CALL_LOG")" "0"
}

lsa() { find "$1" -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | paste -sd' ' -; }

expect_clean_tmp() { # <label>: the temp dir (app.yaml, DOCKER_CONFIG) was removed
  expect_eq "$1: the temp dir is removed" "$(lsa "$W/tmp")" ""
}

expect_no_token() { # <label>: the token is in no argv, log, output, state or registry file
  expect_out_lacks "$1: token not in the output" "$TOKEN"
  expect_calls_lacks "$1: token not in any argv" "$TOKEN"
  if grep -qF -- "$TOKEN" "$LOGGER_LOG"; then _fail "$1: token not in the log"; else _pass; fi
  if grep -rqF -- "$TOKEN" "$W/dstate" "$W/reg"; then _fail "$1: token not in state or registry"; else _pass; fi
  if [ -e "$STATE/leak" ]; then _fail "$1: token not in the environment or a temp file" "$(cat "$STATE/leak")"; else _pass; fi
}

# ---- usage ----

reset
mkyaml alpha
mkinput "$TOKEN" "$YAML"
run_deploy
expect_rc "no arguments is a usage error" 2
run_deploy deploy alpha
expect_rc "a missing tag is a usage error" 2
run_deploy rollback alpha v1
expect_rc "an unknown subcommand is a usage error" 2
run_deploy deploy Alpha v1
expect_rc "an invalid app name exits 2" 2
run_deploy rollback
expect_rc "a rollback with no app is a usage error" 2
run_deploy rollback Alpha
expect_rc "a rollback with an invalid app name exits 2" 2
run_deploy deploy alpha 'bad tag'
expect_rc "an invalid tag exits 2" 2
run_deploy deploy alpha -v1
expect_rc "a tag starting with a dash exits 2" 2
expect_no_docker "usage errors"

# The hooks default to the fixed production values.
src="$(cat "$script")"
for d in 'DEPLOY_NETWORK:-platform' 'DEPLOY_SECRETS_ROOT:-/var/lib/platform/secrets' 'DEPLOY_JOB_SECRETS_ROOT:-/var/lib/platform/job-secrets' \
  'DEPLOY_STATE_ROOT:-/var/lib/platform/deploy' 'DEPLOY_REGISTRY_ROOT:-/var/lib/platform/registry' \
  'DEPLOY_LOCK_DIR:-/var/lib/platform/locks' 'DEPLOY_CONNECTION_ENV:-/opt/platform/data/connection.env' \
  'DEPLOY_SKIP_REGISTRY:-0' 'DEPLOY_VALIDATOR:-/opt/platform/deploy/registry/validate-app-yaml.sh'; do
  expect_out_has_text "$src" "\${$d}" "the hook default is the production value: $d"
done

# ---- a first deploy (alpha at v1) ----

reset
deploy_app alpha v1
expect_rc "a first deploy succeeds" 0
expect_out_has "a first deploy reports done" "deploy: done alpha v1"
REF1="$(ref_of alpha v1)"
expect_eq "login received the token on stdin" "$(rd "$STATE/login.stdin")" "$TOKEN"
expect_calls_has "login names the registry and uses stdin" "docker login ghcr.io --username github-actions --password-stdin"
expect_calls_has "the pull is of the tag" "docker pull ghcr.io/gpropersi/apps/alpha:v1"
expect_calls_lacks "a first deploy stops nothing" "docker stop"
expect_calls_lacks "a first deploy renames nothing" "docker rename"
expect_calls_lacks "a first deploy removes nothing" "docker rm"
expect_eq "app-alpha runs" "$(ctr_status app-alpha)" "running"
expect_eq "only app-alpha exists (no -old)" "$(lsa "$STATE/ctr")" "app-alpha app-alpha.img"
expect_eq "state current/tag" "$(rd "$W/dstate/alpha/current/tag")" "v1"
expect_eq "state current/digest is the resolved reference" "$(rd "$W/dstate/alpha/current/digest")" "$REF1"
if [[ "$(rd "$W/dstate/alpha/current/deployed-at")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]; then _pass; else _fail "deployed-at is a UTC timestamp"; fi
expect_eq "state current/app.yaml is the deployed file" "$(rd "$W/dstate/alpha/current/app.yaml")" "$(cat "$YAML")"
expect_eq "the registry entry is the deployed app.yaml" "$(rd "$W/reg/alpha/app.yaml")" "$(cat "$YAML")"
expect_eq "a first deploy creates no previous/" "$([ -e "$W/dstate/alpha/previous" ] && echo yes || echo no)" "no"
expect_eq "no stray state entries" "$(ls -A "$W/dstate/alpha")" "current"

# The run contract: one fixed argv, ending in the inspected immutable reference.
argv="$(paste -sd' ' "$STATE/run.argv")"
want="-d --name app-alpha --label platform.app=alpha --network testnet --network-alias alpha --group-add 64323 --group-add 64324"
want+=" --cap-drop ALL --security-opt no-new-privileges:true --read-only --tmpfs /tmp --memory 64m --memory-swap 64m"
want+=" --pids-limit 256 --restart unless-stopped -v $W/secrets/alpha:/run/platform/secrets:ro"
want+=" -v $W/jobs/alpha:/run/platform/job-secrets:ro -e DB_HOST=postgres -e DB_PORT=5432 -e DB_NAME=alpha -e DB_USER=alpha"
want+=" -e DB_PASSWORD_FILE=/run/platform/secrets/db-password -e REDIS_HOST=redis -e REDIS_PORT=6379 -e REDIS_USER=alpha"
want+=" -e REDIS_PASSWORD_FILE=/run/platform/secrets/redis-password -e REDIS_KEY_PREFIX=alpha:"
want+=" -e JOBS_SECRET_FILE=/run/platform/job-secrets/jobs-secret $REF1"
expect_eq "the docker run argv is exactly the fixed contract" "$argv" "$want"
expect_eq "exactly one --label" "$(grep -cx -- '--label' "$STATE/run.argv")" "1"
expect_eq "the run image argument is the last argv entry" "$(tail -n 1 "$STATE/run.argv")" "$REF1"
expect_eq "inspect used the run image argument (the resolved reference), 5 times (4 inspect checks + the cleanup keep set)" "$(grep -cxF -- "$REF1" "$STATE/image_refs")" "5"
expect_eq "the tag was only used to resolve the digest" "$(grep -cxF -- "ghcr.io/gpropersi/apps/alpha:v1" "$STATE/image_refs")" "1"
expect_calls_lacks "no password value in any argv" "$DBPW"
expect_calls_lacks "the run argv has no --log-driver" "--log-driver"
expect_calls_has "the health probe URL" "curl -s -o /dev/null -w %{http_code} --max-time 5 http://$IPADDR:8080/healthz"
expect_no_token "first deploy"
expect_eq "login used the private DOCKER_CONFIG, which no longer exists" "$([ -e "$(rd "$STATE/login.cfg")" ] && echo yes || echo no)" "no"
expect_eq "the DOCKER_CONFIG existed during login" "$(rd "$STATE/login.cfg.exists")" "yes"
expect_eq "pull used the same DOCKER_CONFIG as login" "$(rd "$STATE/pull.cfg")" "$(rd "$STATE/login.cfg")"
expect_eq "the login credential file existed for the pull" "$(rd "$STATE/pull.cfg.had")" "yes"
expect_eq "the login credential file is deleted right after the pull" "$(rd "$STATE/cfg_after_pull")" ""
expect_clean_tmp "first deploy"
if grep -q 'phase=swap end rc=0' "$LOGGER_LOG" && grep -q 'phase=commit end rc=0 dur=' "$LOGGER_LOG"; then _pass; else _fail "phases are logged with rc and duration"; fi
snap_save
OLD_IMG="$REF1"

# ---- refusals: nothing before swap touches the running app ----

refuse() { # <label> <phase> <setup fn> [text the output must carry]
  local label="$1" phase="$2" setup="$3" text="${4:-}"
  snap_load
  mkyaml alpha
  mkinput "$TOKEN" "$YAML"
  "$setup"
  run_deploy deploy alpha v9
  expect_rc "$label: exits 1" 1
  expect_out_has "$label: names the phase" "phase '$phase' failed"
  [ -z "$text" ] || expect_out_has "$label: says what to do" "$text"
  expect_untouched "$label"
  expect_eq "$label: the running app is untouched" "$(ctr_img app-alpha)" "$OLD_IMG"
  expect_eq "$label: app-alpha keeps running" "$(ctr_status app-alpha)" "running"
  expect_eq "$label: current tag unchanged" "$(rd "$W/dstate/alpha/current/tag")" "v1"
  expect_eq "$label: registry entry unchanged" "$(rd "$W/reg/alpha/app.yaml")" "$(rd "$T_TMP/snap/reg/alpha/app.yaml")"
  expect_no_token "$label"
  expect_clean_tmp "$label"
}

s_notoken() { mkinput "" "$YAML"; }
s_nonewline() { printf '%s' "$TOKEN" >"$INPUT"; }
s_notoken_at_all() { : >"$INPUT"; }
s_bigtoken() { mkinput "$(head -c 1025 </dev/zero | tr '\0' T)" "$YAML"; }
s_emptyyaml() { printf '%s\n' "$TOKEN" >"$INPUT"; }
s_bigyaml() {
  local pad=$((16385 - $(stat -c %s "$YAML")))
  { cat "$YAML"; printf '#%s\n' "$(head -c $((pad - 2)) </dev/zero | tr '\0' x)"; } >"$T_TMP/big.yaml"
  mkinput "$TOKEN" "$T_TMP/big.yaml"
}
s_wrongname() { mkyaml beta; mkinput "$TOKEN" "$YAML"; }
s_unknownkey() { printf 'bogus: 1\n' >>"$YAML"; mkinput "$TOKEN" "$YAML"; }
s_nosecrets() { rm -rf "$W/secrets/alpha"; }
s_nojobsecrets() { rm -rf "$W/jobs/alpha"; }
s_nonet() { echo 1 >"$STATE/fail_network"; }
s_noreg() { XENV=(DEPLOY_REGISTRY_ROOT="$W/no-such-registry"); }
s_regfile() { : >"$W/regfile"; XENV=(DEPLOY_REGISTRY_ROOT="$W/regfile"); }
s_regro() { mkdir "$W/roreg"; chmod 555 "$W/roreg"; XENV=(DEPLOY_REGISTRY_ROOT="$W/roreg"); }
s_nostate() { XENV=(DEPLOY_STATE_ROOT="$W/no-such-state"); }
s_noconn() { rm -f "$W/conn.env"; }
s_loginfail() { echo 1 >"$STATE/fail_login"; }
s_pullfail() { echo 1 >"$STATE/fail_pull"; }
s_nodigest() { : >"$STATE/repodigests"; }
s_foreigndigest() { echo "ghcr.io/gpropersi/apps/beta@sha256:$(sha x)" >"$STATE/repodigests"; }
s_pulltimeout() { echo 2 >"$STATE/pull_sleep"; XENV=(DEPLOY_PULL_TIMEOUT=1); }
s_arch() { echo arm64 >"$STATE/image_arch"; }
s_traefik() { printf 'traefik.enable\n' >"$STATE/image_labels"; }
s_traefik_upper() { printf 'Traefik.http.routers.x.rule\n' >"$STATE/image_labels"; }
s_platformlabel() { printf 'org.example.ok\nplatform.app\n' >"$STATE/image_labels"; }
s_twoports() { printf '8080/tcp\n9090/tcp\n' >"$STATE/image_ports"; }
s_noports() { : >"$STATE/image_ports"; }
s_wrongport() { printf '9090/tcp\n' >"$STATE/image_ports"; }
s_udp() { printf '8080/udp\n' >"$STATE/image_ports"; }
s_user() { printf '%s' "$CASE_VAL" >"$STATE/image_user"; }

refuse "an empty token line" input s_notoken
expect_no_docker "an empty token line"
refuse "a token line with no newline" input s_nonewline
expect_no_docker "a token line with no newline"
refuse "empty stdin" input s_notoken_at_all
expect_no_docker "empty stdin"
refuse "a token over 1 KiB" input s_bigtoken
expect_no_docker "a token over 1 KiB"
refuse "an empty app.yaml" input s_emptyyaml
expect_no_docker "an empty app.yaml"
refuse "an app.yaml over 16 KiB" input s_bigyaml
expect_no_docker "an app.yaml over 16 KiB"
refuse "an app.yaml with another app's name" validate s_wrongname
expect_no_docker "a wrong name"
refuse "an app.yaml with an unknown key" validate s_unknownkey "bogus"
expect_no_docker "an unknown key"
refuse "a missing secrets dir" preflight s_nosecrets "platform new-db alpha"
refuse "a missing job-secrets dir" preflight s_nojobsecrets "platform new-db alpha"
refuse "a missing platform network" preflight s_nonet
refuse "a missing registry root" preflight s_noreg "make host-jobs HOST=<alias> ARGS=install"
refuse "a registry root that is a file" preflight s_regfile "make host-jobs"
if [ "$(id -u)" -ne 0 ]; then
  refuse "an unwritable registry root" preflight s_regro "make host-jobs"
else
  echo "note: skipping the unwritable-registry case (running as root)"
fi
refuse "a missing deploy state root" preflight s_nostate "make host-deploy-user"
refuse "a missing connection file" preflight s_noconn
refuse "a login failure" pull s_loginfail
refuse "a pull auth failure" pull s_pullfail
if grep -qF '***' "$LOGGER_LOG"; then _pass; else _fail "the token in docker's error text is masked, not dropped"; fi
refuse "a digest-less pull" pull s_nodigest "no digest"
refuse "a pull yielding another repository's digest" pull s_foreigndigest "no digest"
refuse "a pull timeout" pull s_pulltimeout "timed out"
refuse "the wrong architecture" inspect s_arch
refuse "a traefik label" inspect s_traefik "traefik.enable"
refuse "a traefik label in another case" inspect s_traefik_upper
refuse "a platform label" inspect s_platformlabel "platform.app"
refuse "two exposed ports" inspect s_twoports
refuse "no exposed port" inspect s_noports "nothing"
refuse "the wrong exposed port" inspect s_wrongport
refuse "a udp port" inspect s_udp
for CASE_VAL in "" root 0 00 0:0 root:root 0:1000 app 1000x; do
  refuse "Config.User '$CASE_VAL'" inspect s_user
done

# Users that pass.
for CASE_VAL in 1000 1000:1000; do
  snap_load
  s_user
  deploy_app alpha v9
  expect_rc "Config.User '$CASE_VAL' passes" 0
done

# ---- a second deploy: swap, commit, previous ----

snap_load
deploy_app alpha v2
expect_rc "a second deploy succeeds" 0
REF2="$(ref_of alpha v2)"
expect_calls_has "the old container is stopped for 30s" "docker stop -t 30 app-alpha"
expect_calls_has "the old container is renamed" "docker rename app-alpha app-alpha-old"
expect_calls_has "the old container is removed at commit" "docker rm -f -v app-alpha-old"
expect_eq "app-alpha runs the new image" "$(ctr_img app-alpha)" "$REF2"
expect_eq "app-alpha-old is gone" "$([ -e "$STATE/ctr/app-alpha-old" ] && echo yes || echo no)" "no"
expect_eq "current/tag is v2" "$(rd "$W/dstate/alpha/current/tag")" "v2"
expect_eq "previous/tag is v1" "$(rd "$W/dstate/alpha/previous/tag")" "v1"
expect_eq "previous/digest is the old reference" "$(rd "$W/dstate/alpha/previous/digest")" "$REF1"
expect_eq "previous/app.yaml is the old file" "$(rd "$W/dstate/alpha/previous/app.yaml")" "$(rd "$T_TMP/snap/reg/alpha/app.yaml")"
expect_eq "no stray state entries after a swap" "$(lsa "$W/dstate/alpha")" "current previous"
expect_no_token "second deploy"
expect_clean_tmp "second deploy"
snap_save
SNAPB_REG="$(rd "$W/reg/alpha/app.yaml")"

# A redeploy of the live tag leaves previous/ untouched and refreshes current/.
snap_load
PREV_AT="$(rd "$W/dstate/alpha/previous/deployed-at")"
printf '%s\n' "2001-01-01T00:00:00Z" >"$W/dstate/alpha/current/deployed-at"
printf '%s\n' "stale-digest" >"$W/dstate/alpha/current/digest"
mkyaml alpha /healthz 96m
mkinput "$TOKEN" "$YAML"
run_deploy deploy alpha v2
expect_rc "a redeploy of the live tag succeeds" 0
expect_eq "previous/tag untouched" "$(rd "$W/dstate/alpha/previous/tag")" "v1"
expect_eq "previous/deployed-at untouched" "$(rd "$W/dstate/alpha/previous/deployed-at")" "$PREV_AT"
expect_eq "previous/app.yaml untouched" "$(rd "$W/dstate/alpha/previous/app.yaml")" "$(rd "$T_TMP/snap/dstate/alpha/previous/app.yaml")"
expect_eq "current/tag is still v2" "$(rd "$W/dstate/alpha/current/tag")" "v2"
expect_eq "current/app.yaml is refreshed" "$(rd "$W/dstate/alpha/current/app.yaml")" "$(cat "$YAML")"
expect_eq "the registry entry is refreshed" "$(rd "$W/reg/alpha/app.yaml")" "$(cat "$YAML")"
expect_eq "current/digest is the resolved reference" "$(rd "$W/dstate/alpha/current/digest")" "$REF2"
if [[ "$(rd "$W/dstate/alpha/current/deployed-at")" =~ ^20(2[5-9]|[3-9][0-9])-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]; then _pass; else _fail "current/deployed-at is a fresh UTC timestamp"; fi
expect_eq "no stray state entries after a redeploy" "$(lsa "$W/dstate/alpha")" "current previous"

# ---- rollback (from the v2-live snapshot: current v2, previous v1) ----

run_rollback() { # <app>: no stdin is supplied at all
  : >"$INPUT"
  run_deploy rollback "$1"
}
refid() { printf 'sha256:%s' "$(sha "i$(sha "d$1")")"; } # the stub's image ID for tag $1
REPO=ghcr.io/gpropersi/apps/alpha

snap_load
run_rollback alpha
expect_rc "a rollback succeeds" 0
expect_out_has "a rollback reports done" "rollback: done alpha v1"
expect_calls_lacks "a rollback makes no login" "docker login"
expect_calls_lacks "a rollback makes no pull" "docker pull"
expect_eq "app-alpha runs the previous image" "$(ctr_img app-alpha):$(ctr_status app-alpha)" "$REF1:running"
expect_eq "the run image is the recorded digest" "$(tail -n 1 "$STATE/run.argv")" "$REF1"
expect_calls_has "the current container is stopped" "docker stop -t 30 app-alpha"
expect_eq "app-alpha-old is gone" "$([ -e "$STATE/ctr/app-alpha-old" ] && echo yes || echo no)" "no"
expect_eq "current/tag is the older tag" "$(rd "$W/dstate/alpha/current/tag")" "v1"
expect_eq "current/digest is the older digest" "$(rd "$W/dstate/alpha/current/digest")" "$REF1"
expect_eq "previous/tag is the replaced version" "$(rd "$W/dstate/alpha/previous/tag")" "v2"
expect_eq "previous/digest is the replaced digest" "$(rd "$W/dstate/alpha/previous/digest")" "$REF2"
expect_eq "the registry holds the previous app.yaml" "$(rd "$W/reg/alpha/app.yaml")" "$(rd "$T_TMP/snap/dstate/alpha/previous/app.yaml")"
expect_eq "no stray state entries after a rollback" "$(lsa "$W/dstate/alpha")" "current previous"
expect_clean_tmp "a rollback"
if grep -q 'phase=commit end rc=0 dur=' "$LOGGER_LOG"; then _pass; else _fail "a rollback logs its commit phase"; fi

# A second rollback returns forward to the original version.
run_rollback alpha
expect_rc "a second rollback succeeds" 0
expect_eq "two rollbacks end on the original version" "$(rd "$W/dstate/alpha/current/tag"):$(ctr_img app-alpha)" "v2:$REF2"
expect_eq "and previous is the older version again" "$(rd "$W/dstate/alpha/previous/tag")" "v1"
expect_eq "and the registry is the original app.yaml" "$(rd "$W/reg/alpha/app.yaml")" "$SNAPB_REG"

# A redeploy of the live tag, then a rollback, still returns to the version before it.
snap_load
mkyaml alpha /healthz 96m
mkinput "$TOKEN" "$YAML"
run_deploy deploy alpha v2
expect_rc "the live tag is redeployed" 0
run_rollback alpha
expect_rc "a rollback after a redeploy succeeds" 0
expect_eq "it returns to the version before the redeploy" "$(rd "$W/dstate/alpha/current/tag"):$(ctr_img app-alpha)" "v1:$REF1"

# No previous deploy: right after a first deploy, and with no state at all. Nothing changes.
reset
deploy_app alpha v1
: >"$CALL_LOG"
run_rollback alpha
expect_rc "a rollback right after a first deploy exits 1" 1
expect_out_has "and says there is no previous deploy" "no previous deploy"
expect_untouched "a rollback with no previous"
expect_eq "the running app is untouched" "$(ctr_img app-alpha)" "$REF1"
expect_eq "the state is untouched" "$(rd "$W/dstate/alpha/current/tag")" "v1"
expect_eq "no previous/ appears" "$(lsa "$W/dstate/alpha")" "current"
reset
run_rollback alpha
expect_rc "a rollback with no deploy state exits 1" 1
expect_out_has "and names the phase" "phase 'previous' failed"
expect_untouched "a rollback with no state"

# An image missing from the local daemon names inspect and changes nothing.
snap_load
printf '%s\n' "$REF1" >"$STATE/missing_images"
run_rollback alpha
expect_rc "a rollback with the previous image gone exits 1" 1
expect_out_has "and names inspect" "phase 'inspect' failed"
expect_untouched "a missing previous image"
expect_eq "the current version keeps running" "$(ctr_img app-alpha):$(ctr_status app-alpha)" "$REF2:running"
expect_eq "state is unchanged" "$(rd "$W/dstate/alpha/current/tag"):$(rd "$W/dstate/alpha/previous/tag")" "v2:v1"
expect_eq "the registry is unchanged" "$(rd "$W/reg/alpha/app.yaml")" "$SNAPB_REG"

# A failed rollback health check leaves the current version running.
snap_load
echo 500 >"$STATE/http_code"
run_rollback alpha
expect_rc "a rollback whose health check fails exits 1" 1
expect_out_has "and names health" "phase 'health' failed"
expect_eq "the current version is back and running" "$(ctr_img app-alpha):$(ctr_status app-alpha)" "$REF2:running"
expect_eq "no app-alpha-old is left" "$([ -e "$STATE/ctr/app-alpha-old" ] && echo yes || echo no)" "no"
expect_eq "state is unchanged after a failed rollback" "$(rd "$W/dstate/alpha/current/tag"):$(rd "$W/dstate/alpha/previous/tag")" "v2:v1"
expect_eq "the registry is unchanged after a failed rollback" "$(rd "$W/reg/alpha/app.yaml")" "$SNAPB_REG"
expect_clean_tmp "a failed rollback"

# A state exchange failing at either move is undone: the new container keeps running, the old one stays, state is intact.
for pat in "*/dstate/alpha/current" "*/dstate/alpha/previous"; do
  snap_load
  XENV=("MV_FAIL=$pat")
  run_rollback alpha
  expect_rc "a rollback state failure ($pat) exits 1" 1
  expect_out_has "a rollback state failure ($pat) names commit" "phase 'commit' failed"
  expect_eq "($pat) state keeps both versions" "$(rd "$W/dstate/alpha/current/tag"):$(rd "$W/dstate/alpha/previous/tag")" "v2:v1"
  expect_eq "($pat) no stray state entries" "$(lsa "$W/dstate/alpha")" "current previous"
  expect_eq "($pat) the old container is not removed" "$(ctr_img app-alpha-old)" "$REF2"
done

# A held lock times out the rollback (it serialises with deploy, new-db, rm-db and restore.sh on the one app lock).
snap_load
flock "$W/locks/alpha.lock" /usr/bin/sleep 6 &
holder=$!
until ! flock -n "$W/locks/alpha.lock" true; do /usr/bin/sleep 0.05; done
run_rollback alpha
expect_rc "a rollback under a held lock times out" 1
expect_out_has "and names the lock phase" "phase 'lock' failed"
expect_untouched "a rollback under a held lock"
pkill -P "$holder" -x sleep 2>/dev/null
wait "$holder" 2>/dev/null
run_rollback alpha
expect_rc "the rollback succeeds once the lock is free" 0

# Stale commit leftovers are cleared; an orphaned .gone/ is recovered as current/.
snap_load
mkdir "$W/dstate/alpha/.new.99" "$W/dstate/alpha/.prev.99" "$W/dstate/alpha/.old.99" "$W/dstate/alpha/.gone.99"
deploy_app alpha v3
expect_rc "a deploy beside stale commit dirs succeeds" 0
expect_eq "a deploy clears stale commit dirs" "$(lsa "$W/dstate/alpha")" "current previous"
snap_load
"$REAL_MV" "$W/dstate/alpha/current" "$W/dstate/alpha/.gone.77"
mkdir "$W/dstate/alpha/.new.99"
run_rollback alpha
expect_rc "a rollback recovers an orphaned .gone/" 0
expect_eq "the orphan became current, then was exchanged" "$(rd "$W/dstate/alpha/current/tag"):$(rd "$W/dstate/alpha/previous/tag")" "v1:v2"
expect_eq "a rollback clears stale commit dirs" "$(lsa "$W/dstate/alpha")" "current previous"

# A rollback that died between its moves (previous/ missing, the newer version orphaned as .gone) is repaired by the next rollback.
snap_load
"$REAL_MV" "$W/dstate/alpha/current" "$W/dstate/alpha/.gone.55"
"$REAL_MV" "$W/dstate/alpha/previous" "$W/dstate/alpha/current"
run_rollback alpha
expect_rc "a rollback repairs an interrupted rollback" 0
expect_eq "it rolls forward to the orphaned newer version" "$(rd "$W/dstate/alpha/current/tag"):$(rd "$W/dstate/alpha/previous/tag")" "v2:v1"

# ---- image cleanup: keep current and previous, never another app's ----

mkimages() { # <tag>...: this app's rows by tag, plus another app's image; the stub keeps them in $STATE/images
  : >"$STATE/images"
  local t
  for t in "$@"; do printf '%s %s %s <none>\n' "$(refid "$t")" "$REPO" "$t" >>"$STATE/images"; done
  printf '%s ghcr.io/gpropersi/apps/beta v1 <none>\n' "$(refid betav1)" >>"$STATE/images"
}
rmis() { rd "$STATE/rmi.log" | paste -sd' ' -; }

snap_load
mkimages v0 v1 v2 v3
deploy_app alpha v3
expect_rc "a deploy with old images present succeeds" 0
expect_eq "cleanup removes only the images outside current and previous" "$(rmis)" "$REPO:v0 $REPO:v1"
expect_calls_has "only this app's repository is listed" "docker image ls --no-trunc --digests --format {{.ID}} {{.Repository}} {{.Tag}} {{.Digest}} $REPO"
expect_eq "another app's image survives" "$(grep -c '/beta ' "$STATE/images")" "1"

snap_load
mkimages v0 v1 v2
run_rollback alpha
expect_rc "a rollback with old images present succeeds" 0
expect_eq "rollback cleanup keeps the new current and previous" "$(rmis)" "$REPO:v0"

# A failed deploy removes only the newly pulled image, and not one that is current or previous.
snap_load
mkimages v0 v1 v2 v3
echo 500 >"$STATE/http_code"
deploy_app alpha v3
expect_rc "a failed deploy exits 1" 1
expect_eq "a failed deploy removes the new image only" "$(rmis)" "$REPO:v3"
snap_load
mkimages v1 v2
echo 500 >"$STATE/http_code"
deploy_app alpha v2
expect_rc "a failed redeploy of the live tag exits 1" 1
expect_eq "a failed redeploy removes nothing (the image is current)" "$(rmis)" ""
snap_load
mkimages v1 v2 v3
XENV=("MV_FAIL=*/dstate/alpha/current")
deploy_app alpha v3
expect_rc "a commit failure exits 1" 1
expect_eq "a commit failure removes no image (the new container runs it)" "$(rmis)" ""

# Digest-only rows (an untagged image left by a re-pushed tag) are removed by digest, once per image ID; a kept one stays.
snap_load
mkimages v1 v2 v3
printf '%s %s <none> sha256:%s\n' "$(refid old)" "$REPO" "$(sha old)" >>"$STATE/images"
printf '%s %s <none> sha256:%s\n' "$(refid v2)" "$REPO" "$(sha v2d)" >>"$STATE/images"
deploy_app alpha v3
expect_rc "a deploy with digest-only rows succeeds" 0
expect_eq "an untagged stray is removed by digest, a kept untagged row is not" "$(rmis)" "$REPO:v1 $REPO@sha256:$(sha old)"

# A cleanup failure is a warning, not a failed deploy.
snap_load
mkimages v0 v1 v2 v3
echo 1 >"$STATE/fail_rmi"
deploy_app alpha v3
expect_rc "a failing docker rmi does not fail the deploy" 0
if grep -q 'warning: could not remove' "$LOGGER_LOG"; then _pass; else _fail "the failed removal is logged as a warning"; fi
snap_load
mkimages v0 v1 v2 v3
echo 1 >"$STATE/fail_imagels"
deploy_app alpha v3
expect_rc "a failing image listing does not fail the deploy" 0
expect_eq "and nothing is removed" "$(rmis)" ""

# ---- health, swap and commit failures (from the v2-live snapshot) ----

health_fail() { # <label> <setup fn>
  snap_load
  "$2"
  deploy_app alpha v3
  expect_rc "$1: exits 1" 1
  expect_out_has "$1: names health" "phase 'health' failed"
  expect_eq "$1: the old container is restored under its name" "$(ctr_img app-alpha)" "$REF2"
  expect_eq "$1: and running" "$(ctr_status app-alpha)" "running"
  expect_eq "$1: no app-alpha-old left" "$([ -e "$STATE/ctr/app-alpha-old" ] && echo yes || echo no)" "no"
  expect_eq "$1: current/tag unchanged" "$(rd "$W/dstate/alpha/current/tag")" "v2"
  expect_eq "$1: previous/tag unchanged" "$(rd "$W/dstate/alpha/previous/tag")" "v1"
  expect_eq "$1: registry unchanged" "$(rd "$W/reg/alpha/app.yaml")" "$SNAPB_REG"
  expect_no_token "$1"
  expect_clean_tmp "$1"
}
h_500() { echo 500 >"$STATE/http_code"; }
h_301() { echo 301 >"$STATE/http_code"; }
h_curlfail() { echo 7 >"$STATE/curl_rc"; }
h_exited() { echo exited >"$STATE/run_status"; }
health_fail "an unhealthy 500" h_500
health_fail "a 301 is not 2xx" h_301
health_fail "an unreachable health path" h_curlfail
health_fail "a container that exits" h_exited

snap_load
printf 204 >"$STATE/http_code"
deploy_app alpha v3
expect_rc "a 204 counts as healthy" 0

# A failing docker run restores the old container too.
snap_load
echo 1 >"$STATE/fail_run"
deploy_app alpha v3
expect_rc "a failing docker run exits 1" 1
expect_out_has "a failing docker run names swap" "phase 'swap' failed"
expect_eq "a failing docker run restores the old container" "$(ctr_img app-alpha)" "$REF2"
expect_eq "and starts it" "$(ctr_status app-alpha)" "running"
expect_eq "state is unchanged after a swap failure" "$(rd "$W/dstate/alpha/current/tag")" "v2"

snap_load
echo 1 >"$STATE/fail_stop"
deploy_app alpha v3
expect_rc "a failing stop exits 1" 1
expect_out_has "a failing stop names swap" "phase 'swap' failed"
expect_eq "the old container is kept" "$(ctr_img app-alpha)" "$REF2"
expect_calls_lacks "nothing is run after a failed stop" "docker run"

# Commit failures keep the new container, the old one and previous/.
commit_fail() { # <label> <MV_FAIL pattern>
  snap_load
  XENV=("MV_FAIL=$2")
  deploy_app alpha v3
  expect_rc "$1: exits 1" 1
  expect_out_has "$1: names commit" "phase 'commit' failed"
  expect_eq "$1: the new container keeps running" "$(ctr_img app-alpha)" "$(ref_of alpha v3)"
  expect_eq "$1: and is running" "$(ctr_status app-alpha)" "running"
  expect_eq "$1: the old container is not removed" "$(ctr_img app-alpha-old)" "$REF2"
  expect_calls_lacks "$1: no rm" "docker rm"
  expect_eq "$1: previous/tag is not advanced" "$(rd "$W/dstate/alpha/previous/tag")" "v1"
  expect_eq "$1: current/tag is not advanced" "$(rd "$W/dstate/alpha/current/tag")" "v2"
  expect_eq "$1: no stray state entries" "$(lsa "$W/dstate/alpha")" "current previous"
  expect_clean_tmp "$1"
}
commit_fail "a registry write failure" "*/reg/alpha/app.yaml"
expect_eq "a registry write failure leaves the state alone" "$(rd "$W/dstate/alpha/current/digest")" "$REF2"
commit_fail "a state write failure (current)" "*/dstate/alpha/current"
commit_fail "a state write failure (previous)" "*/dstate/alpha/previous"

# ---- no health_path: the container must stay running for 10s ----

snap_load
mkstub sleep <<'EOF'
exit 0
EOF
deploy_app alpha v3 -
expect_rc "a deploy with no health_path succeeds" 0
expect_eq "no health_path waits 10 polls" "$(grep -c '^sleep ' "$CALL_LOG")" "10"
expect_calls_lacks "no health_path makes no curl call" "curl"
snap_load
echo exited >"$STATE/run_status"
deploy_app alpha v3 -
expect_rc "a no-health_path container that exits fails" 1
expect_out_has "and names health" "phase 'health' failed"
expect_eq "and the old container is restored" "$(ctr_img app-alpha)" "$REF2"
rm -f "$STUB_BIN/sleep"

# ---- a leftover app-alpha-old from an interrupted deploy ----

snap_load
"$REAL_MV" "$STATE/ctr/app-alpha" "$STATE/ctr/app-alpha-old"
"$REAL_MV" "$STATE/ctr/app-alpha.img" "$STATE/ctr/app-alpha-old.img"
echo exited >"$STATE/ctr/app-alpha-old"
deploy_app alpha v3
expect_rc "a leftover -old with no live container is recovered" 0
expect_calls_has "the leftover is restored under the live name" "docker rename app-alpha-old app-alpha"
expect_eq "the new image runs" "$(ctr_img app-alpha)" "$(ref_of alpha v3)"
expect_eq "no -old remains" "$([ -e "$STATE/ctr/app-alpha-old" ] && echo yes || echo no)" "no"

snap_load
printf 'exited' >"$STATE/ctr/app-alpha-old"
printf 'stale' >"$STATE/ctr/app-alpha-old.img"
deploy_app alpha v3
expect_rc "a leftover -old beside a live container is dropped" 0
expect_calls_has "the stale -old is removed first" "docker rm -f -v app-alpha-old"
expect_eq "the live container was the one swapped out" "$(rd "$W/dstate/alpha/previous/tag")" "v2"
expect_eq "the new image runs after dropping a stale -old" "$(ctr_img app-alpha)" "$(ref_of alpha v3)"

# ---- the shared per-app lock ----

snap_load
flock "$W/locks/alpha.lock" /usr/bin/sleep 6 &
holder=$!
until ! flock -n "$W/locks/alpha.lock" true; do /usr/bin/sleep 0.05; done
deploy_app alpha v3
expect_rc "a held lock times out" 1
expect_out_has "and names the lock phase" "phase 'lock' failed"
expect_untouched "a held lock"
pkill -P "$holder" -x sleep 2>/dev/null
wait "$holder" 2>/dev/null
deploy_app alpha v3
expect_rc "the same deploy succeeds once the lock is free" 0

# A lock path that cannot be opened (a directory, which fails even for root) is refused by name.
snap_load
rm -f "$W/locks/alpha.lock"
mkdir "$W/locks/alpha.lock"
deploy_app alpha v3
expect_rc "an unopenable lock file is refused" 1
expect_out_has "and names the preflight phase and the lock file" "cannot open the lock file"
expect_untouched "an unopenable lock file"
rmdir "$W/locks/alpha.lock"

# ---- DEPLOY_SKIP_REGISTRY uses the local image; the token line is still required ----

snap_load
XENV=(DEPLOY_SKIP_REGISTRY=1)
deploy_app alpha v3
expect_rc "a deploy under DEPLOY_SKIP_REGISTRY succeeds" 0
expect_calls_lacks "no login under DEPLOY_SKIP_REGISTRY" "docker login"
expect_calls_lacks "no pull under DEPLOY_SKIP_REGISTRY" "docker pull"
expect_eq "the image ID is the immutable reference" "$(tail -n 1 "$STATE/run.argv")" "$(id_of alpha v3)"
expect_eq "state records the image ID" "$(rd "$W/dstate/alpha/current/digest")" "$(id_of alpha v3)"
snap_load
XENV=(DEPLOY_SKIP_REGISTRY=1)
mkyaml alpha
mkinput "" "$YAML"
run_deploy deploy alpha v3
expect_rc "the token line is still required under DEPLOY_SKIP_REGISTRY" 1
expect_out_has "and the refusal names input" "phase 'input' failed"

# ---- first deploys that fail ----

reset
echo 500 >"$STATE/http_code"
deploy_app beta v1
expect_rc "a first deploy that fails health exits 1" 1
expect_out_has "and names health" "phase 'health' failed"
expect_eq "no container is left" "$(lsa "$STATE/ctr")" ""
expect_eq "no registry entry is written" "$([ -e "$W/reg/beta" ] && echo yes || echo no)" "no"
expect_eq "no deploy state is written" "$([ -e "$W/dstate/beta" ] && echo yes || echo no)" "no"
expect_calls_lacks "nothing is renamed or removed except the new container" "docker rename"

reset
XENV=("MV_FAIL=*/dstate/beta/current")
deploy_app beta v1
expect_rc "a first deploy with a state write failure exits 1" 1
expect_out_has "and names commit" "phase 'commit' failed"
expect_eq "the new container keeps running" "$(ctr_status app-beta)" "running"
expect_eq "no current/ is written" "$([ -e "$W/dstate/beta/current" ] && echo yes || echo no)" "no"
expect_eq "no previous/ is written" "$([ -e "$W/dstate/beta/previous" ] && echo yes || echo no)" "no"

# ---- a hyphenated name maps to an underscore database name ----

reset
deploy_app my-app v1
expect_rc "a hyphenated app deploys" 0
argv="$(paste -sd' ' "$STATE/run.argv")"
expect_out_has_text "$argv" "-e DB_NAME=my_app -e DB_USER=my_app" "DB_NAME and DB_USER use the underscore rule"
expect_out_has_text "$argv" "-e REDIS_USER=my-app" "the Redis user keeps the hyphen"
expect_out_has_text "$argv" "-e REDIS_KEY_PREFIX=my-app:" "the key prefix is <app>:"
expect_out_has_text "$argv" "--network-alias my-app" "the network alias is the app name"

# ---- the limits are inclusive: a 1024-byte token and a 16384-byte app.yaml pass ----

reset
mkyaml alpha
pad=$((16384 - $(stat -c %s "$YAML")))
{ cat "$YAML"; printf '#%s\n' "$(head -c $((pad - 2)) </dev/zero | tr '\0' x)"; } >"$T_TMP/max.yaml"
expect_eq "the fixture app.yaml is exactly 16384 bytes" "$(stat -c %s "$T_TMP/max.yaml")" "16384"
mkinput "$(head -c 1024 </dev/zero | tr '\0' T)" "$T_TMP/max.yaml"
run_deploy deploy alpha v1
expect_rc "a 1024-byte token and a 16384-byte app.yaml are accepted" 0

# ---- an interrupt removes the temp dir (the trap runs once the pull call returns) ----

reset
mkyaml alpha
mkinput "$TOKEN" "$YAML"
echo 2 >"$STATE/pull_sleep"
env TMPDIR="$W/tmp" DEPLOY_NETWORK=testnet DEPLOY_SECRETS_ROOT="$W/secrets" DEPLOY_JOB_SECRETS_ROOT="$W/jobs" \
  DEPLOY_STATE_ROOT="$W/dstate" DEPLOY_REGISTRY_ROOT="$W/reg" DEPLOY_LOCK_DIR="$W/locks" DEPLOY_CONNECTION_ENV="$W/conn.env" \
  DEPLOY_VALIDATOR="$validator" "$script" deploy alpha v1 <"$INPUT" >"$T_TMP/sig.out" 2>&1 &
sigpid=$!
for _ in $(seq 1 50); do
  [ -e "$STATE/pull.started" ] && break
  sleep 0.1
done
kill -TERM "$sigpid"
rc=0
wait "$sigpid" || rc=$?
expect_rc "a TERM during the pull exits 143" 143
out="$(cat "$T_TMP/sig.out")"
expect_clean_tmp "a TERM during the pull"
expect_eq "the DOCKER_CONFIG is gone after a TERM" "$([ -e "$(rd "$STATE/pull.cfg")" ] && echo yes || echo no)" "no"
expect_calls_lacks "nothing is run after a TERM" "docker run"
expect_eq "no state is written after a TERM" "$(lsa "$W/dstate")" ""

# ---- a signal during the health phase restores the old container and removes the temp dir ----

# (INT is not tested: a background job of a non-interactive shell starts with SIGINT ignored, so it cannot be delivered here.)
for sig in TERM HUP; do
  case "$sig" in TERM) want=143 ;; *) want=129 ;; esac
  snap_load
  mkyaml alpha
  mkinput "$TOKEN" "$YAML"
  rm -f "$STATE/curl.started"
  echo 5 >"$STATE/curl_sleep"
  env TMPDIR="$W/tmp" DEPLOY_NETWORK=testnet DEPLOY_SECRETS_ROOT="$W/secrets" DEPLOY_JOB_SECRETS_ROOT="$W/jobs" \
    DEPLOY_STATE_ROOT="$W/dstate" DEPLOY_REGISTRY_ROOT="$W/reg" DEPLOY_LOCK_DIR="$W/locks" DEPLOY_CONNECTION_ENV="$W/conn.env" \
    DEPLOY_VALIDATOR="$validator" "$script" deploy alpha v3 <"$INPUT" >"$T_TMP/sig.out" 2>&1 &
  sigpid=$!
  for _ in $(seq 1 100); do
    [ -e "$STATE/curl.started" ] && break
    sleep 0.1
  done
  kill -"$sig" "$sigpid"
  rc=0
  wait "$sigpid" || rc=$?
  out="$(cat "$T_TMP/sig.out")"
  expect_rc "a $sig during health exits $want" "$want"
  expect_eq "$sig during health: the old container is restored and running" "$(ctr_status app-alpha):$(ctr_img app-alpha)" "running:$REF2"
  expect_eq "$sig during health: no app-alpha-old is left" "$([ -e "$STATE/ctr/app-alpha-old" ] && echo yes || echo no)" "no"
  expect_eq "$sig during health: state is unchanged" "$(rd "$W/dstate/alpha/current/tag")" "v2"
  expect_clean_tmp "$sig during health"
done
rm -f "$STATE/curl_sleep"

# ---- a failed existence probe is never read as "absent" ----

snap_load
: >"$STATE/probe_error"
deploy_app alpha v3
expect_rc "a daemon error on the existence probe exits 1" 1
expect_out_has "and names the swap phase" "phase 'swap' failed"
expect_calls_lacks "the live container is not removed" "docker rm"
expect_calls_lacks "no new container is run" "docker run"
expect_calls_lacks "nothing is stopped" "docker stop"
rm -f "$STATE/probe_error"
expect_eq "the live container is still running" "$(ctr_status app-alpha):$(ctr_img app-alpha)" "running:$REF2"

# ---- a docker call timeout of 0 would disable the limit, so it is refused ----

snap_load
XENV=(DEPLOY_EXEC_TIMEOUT=0)
deploy_app alpha v3
expect_rc "DEPLOY_EXEC_TIMEOUT=0 is refused" 2
XENV=(DEPLOY_PULL_TIMEOUT=0)
deploy_app alpha v3
expect_rc "DEPLOY_PULL_TIMEOUT=0 is refused" 2
XENV=()

# ---- a dir left by a SIGKILLed run is swept; a young one (a live run) is not ----

reset
mkdir -p "$W/tmp/platform-deploy.stale1/dockercfg" "$W/tmp/platform-deploy.young1"
printf '{"auths":{"x":{"auth":"leftover"}}}' >"$W/tmp/platform-deploy.stale1/dockercfg/config.json"
touch -d '3 hours ago' "$W/tmp/platform-deploy.stale1"
deploy_app alpha v1
expect_rc "a deploy beside a stale temp dir succeeds" 0
expect_eq "the stale dir of a dead run is removed" "$(lsa "$W/tmp")" "platform-deploy.young1"
rmdir "$W/tmp/platform-deploy.young1"
expect_clean_tmp "after the sweep"

# ---- a dropped ssh session (stderr is a closed pipe) does not kill the deploy mid-run ----

reset
mkyaml alpha
mkinput "$TOKEN" "$YAML"
rc=0
env TMPDIR="$W/tmp" DEPLOY_NETWORK=testnet DEPLOY_SECRETS_ROOT="$W/secrets" DEPLOY_JOB_SECRETS_ROOT="$W/jobs" \
  DEPLOY_STATE_ROOT="$W/dstate" DEPLOY_REGISTRY_ROOT="$W/reg" DEPLOY_LOCK_DIR="$W/locks" DEPLOY_CONNECTION_ENV="$W/conn.env" \
  DEPLOY_VALIDATOR="$validator" DEPLOY_HEALTH_WAIT=1 DEPLOY_POLL_INTERVAL=0.2 DEPLOY_LOCK_WAIT=1 DEPLOY_PULL_TIMEOUT=5 \
  "$script" deploy alpha v1 <"$INPUT" >/dev/null 2> >(head -c 1 >/dev/null) || rc=$?
expect_rc "a deploy whose stderr reader vanished still completes" 0
expect_eq "and it committed the state" "$(rd "$W/dstate/alpha/current/tag")" "v1"
expect_clean_tmp "a deploy with a closed stderr"

t_finish
