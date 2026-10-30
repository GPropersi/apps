#!/usr/bin/env bash
# Stub tests for install-jobs.sh. Every default host path lands under INSTALL_JOBS_ROOT, the privilege prefix is a
# logging fakesudo, and docker/stat/getent/chown/install/df/ssh are stateful stubs on PATH (owners are recorded by the
# chown and install stubs and reported by the stat stub; modes are real). No docker, network or real Redis is touched;
# the real image build is covered by test_jobs_image.sh (Docker-gated), the real Redis rule by test_jobs_live.sh.
#
# No routable address literals and no real password: the fixture values below are fake strings.
# SC2016: stub bodies are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# SC2154: $out and $rc are set by run_cmd in lib.sh.
# shellcheck disable=SC1091,SC2016,SC2034,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/install-jobs.sh"
data_script="$here/install-data.sh"
repo_jobs="$here/../jobs"

t_init
STATE="$T_TMP/state"
export STATE

# ---- stubs ----

# mkstub <name>: reads the stub body from stdin; the stub first logs "<name> <argv...>" to the call log.
mkstub() {
  local name="$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s" %q >> "$CALL_LOG"\n' "$name"
    printf 'for a in "$@"; do printf " %%s" "$a" >> "$CALL_LOG"; done\n'
    printf 'printf "\\n" >> "$CALL_LOG"\n'
    cat
  } > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

mkstub fakesudo <<'EOF'
exec "$@"
EOF

mkstub nosudo <<'EOF'
exit 1
EOF

mkstub chown <<'EOF'
spec="$1"
path="$2"
u="${spec%%:*}"
g="${spec#*:}"
[ "$u" != root ] || u=0
[ "$g" != root ] || g=0
mkdir -p "$STATE/owner"
echo "$u:$g" > "$STATE/owner/${path//\//_}"
exit 0
EOF

mkstub install <<'EOF'
mode=""
own=""
grp=""
isdir=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -d) isdir=1; shift ;;
    -m) mode="$2"; shift 2 ;;
    -o) own="$2"; shift 2 ;;
    -g) grp="$2"; shift 2 ;;
    --) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ "$isdir" -eq 1 ]; then
  dir="${args[0]}"
  mkdir -p "$dir"
else
  dir="${args[1]}"
  rm -f -- "$dir"
  cp -- "${args[0]}" "$dir"
fi
chmod "$mode" "$dir"
[ "$own" != root ] || own=0
[ "$grp" != root ] || grp=0
mkdir -p "$STATE/owner"
echo "$own:$grp" > "$STATE/owner/${dir//\//_}"
exit 0
EOF

mkstub stat <<'EOF'
fmt="$2"
path="${@: -1}"
if [ ! -e "$path" ] && [ ! -L "$path" ]; then exit 1; fi
ug="$(cat "$STATE/owner/${path//\//_}" 2>/dev/null || echo 0:0)"
case "$fmt" in
  '%u:%g %a') echo "$ug $(/usr/bin/stat -c '%a' -- "$path")" ;;
  *) /usr/bin/stat -c "$fmt" -- "$path" ;;
esac
EOF

mkstub getent <<'EOF'
case "$1" in
  passwd)
    if [ -n "${2:-}" ]; then grep "^$2:" "$STATE/passwd" || exit 2; exit 0; fi
    cat "$STATE/passwd" 2>/dev/null; exit 0 ;;
esac
exit 2
EOF

mkstub ssh <<'EOF'
cat > "$STATE/ssh_stdin"
exit 0
EOF

mkstub df <<'EOF'
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\nstub 1 1 %s 1%% /\n' "$(cat "$STATE/df_avail" 2>/dev/null || echo 99999999)"
EOF

# docker: stateful. Switch files live in $STATE (see the cases). Images are one ref per line in $STATE/images; a
# container exists when $STATE/cimg_<name> holds its image (the data stack containers exist unless absent_<name>).
mkstub docker <<'EOF'
S="$STATE"
sub="$1"
shift
exists() {
  [ -f "$S/cimg_$1" ] && return 0
  case "$1" in "$PGC" | "$RDC") [ ! -f "$S/absent_$1" ] ;; *) return 1 ;; esac
}
mkctr() { # name image
  printf '%s\n' "$2" > "$S/cimg_$1"
  printf 'running|healthy\n' > "$S/state_$1"
  : > "$S/labels_$1"
  printf 'platform\n' > "$S/networks_$1"
  echo "$1" >> "$S/created_log"
}
case "$sub" in
  network)
    case "$1" in
      inspect) [ -f "$S/network_exists" ] || exit 1; cat "$S/network_desc" 2>/dev/null || echo "bridge false"; exit 0 ;;
    esac
    exit 0 ;;
  image)
    [ "$1" = inspect ] || exit 0
    grep -qxF -- "$2" "$S/images" 2>/dev/null || exit 1
    exit 0 ;;
  pull) [ ! -f "$S/pull_fail" ] || { echo "pull error: stub registry down" >&2; exit 1; }; exit 0 ;;
  run)
    if [ "$1" = "--rm" ]; then [ ! -f "$S/moddl_fail" ] || { echo "go: module proxy error: stub" >&2; exit 1; }; exit 0; fi
    printf '%s\n' "$@" > "$S/run_args"
    name=""
    lbl=""
    envs=""
    image="${@: -1}"
    while [ $# -gt 0 ]; do
      case "$1" in
        --name) name="$2"; shift 2 ;;
        --label) lbl="${2%%=*}"; shift 2 ;;
        -e) envs+="$2"$'\n'; shift 2 ;;
        *) shift ;;
      esac
    done
    mkctr "$name" "$image"
    [ -z "$lbl" ] || echo "$lbl" > "$S/labels_$name"
    printf '%s' "$envs" > "$S/env_$name"
    exit 0 ;;
  build)
    ref=""
    while [ $# -gt 0 ]; do
      case "$1" in -t) ref="$2"; shift 2 ;; *) shift ;; esac
    done
    [ ! -f "$S/build_hang" ] || sleep 5
    [ ! -f "$S/build_fail" ] || { echo "build error: stub" >&2; exit 1; }
    echo "$ref" >> "$S/images"
    echo "$ref" >> "$S/build_log"
    exit 0 ;;
  compose)
    up=0
    force=0
    for a in "$@"; do
      case "$a" in up) up=1 ;; --force-recreate) force=1 ;; esac
    done
    [ "$up" -eq 1 ] || exit 0
    echo "$RUNNER_TAG" > "$S/compose_tag"
    [ ! -f "$S/up_fail" ] || exit 1
    want="platform-jobs-runner:$RUNNER_TAG"
    if [ "$force" -eq 1 ] || [ ! -f "$S/cimg_$RUNC" ] || [ "$(cat "$S/cimg_$RUNC")" != "$want" ]; then
      mkctr "$RUNC" "$want"
      printf '%s|/opt/platform/backup|false\n%s|/etc/platform/jobs.env|false\n' "$BACKUP_PATH" "$ENV_PATH" > "$S/mounts_$RUNC"
      [ ! -f "$S/unhealthy_after_up" ] || printf 'running|unhealthy\n' > "$S/state_$RUNC"
    elif [[ "$(cat "$S/state_$RUNC" 2>/dev/null)" == exited* ]]; then
      # a plain `up` starts an exited container again
      printf 'running|healthy\n' > "$S/state_$RUNC"
      echo x >> "$S/restart_log"
    fi
    exit 0 ;;
  port) cat "$S/port_$1" 2>/dev/null; exit 0 ;;
  rm)
    [ "$1" != "-f" ] || shift
    echo "$1" >> "$S/rm_log"
    rm -f "$S/cimg_$1" "$S/state_$1" "$S/labels_$1" "$S/networks_$1" "$S/mounts_$1" "$S/env_$1"
    exit 0 ;;
  rmi)
    echo "$1" >> "$S/rmi_log"
    grep -vxF -- "$1" "$S/images" > "$S/images.n" || true
    mv "$S/images.n" "$S/images"
    exit 0 ;;
  images)
    repo="${@: -1}"
    grep "^$repo:" "$S/images" 2>/dev/null || true
    exit 0 ;;
  inspect)
    fmt="$2"
    name="$3"
    exists "$name" || exit 1
    [ ! -f "$S/inspect_fail_$name" ] || exit 1
    case "$fmt" in
      *State.Status*)
        st="$(cat "$S/state_$name" 2>/dev/null || echo "running|healthy")"
        if [[ "$fmt" == *Health* ]]; then echo "$st"; else echo "${st%%|*}"; fi ;;
      *Config.Image*) cat "$S/cimg_$name" 2>/dev/null ;;
      *'index .Config.Labels'*) if grep -qx 'platform.app' "$S/labels_$name" 2>/dev/null; then echo jobstest; fi ;;
      *Labels*) cat "$S/labels_$name" 2>/dev/null ;;
      *Networks*) cat "$S/networks_$name" 2>/dev/null ;;
      *Mounts*) cat "$S/mounts_$name" 2>/dev/null ;;
      *Config.Env*) cat "$S/env_$name" 2>/dev/null ;;
    esac
    exit 0 ;;
  exec)
    [ "$1" != "-i" ] || shift
    shift # container name
    cmd="${*:6}"
    if [ -z "$cmd" ]; then
      # stdin mode: one command per line
      while IFS= read -r line; do
        case "$line" in
          "ACL SETUSER runner "*)
            [ ! -f "$S/setuser_fail" ] || { echo "ERR stub"; continue; }
            echo x >> "$S/setuser_count"
            pw="${line#*>}"
            pw="${pw%% *}"
            printf '%s' "$pw" > "$S/setuser_pw"
            h="$(printf '%s' "$pw" | sha256sum | cut -d ' ' -f 1)"
            rest="${line#*resetkeys }"
            grep -v '^user runner ' "$S/acl_list" > "$S/acl_list.n" || true
            printf 'user runner on sanitize-payload #%s %s\n' "$h" "$rest" >> "$S/acl_list.n"
            mv "$S/acl_list.n" "$S/acl_list"
            echo OK ;;
          "ACL SAVE") echo x >> "$S/acl_save_count"; echo OK ;;
          *) echo "ERR unknown" ;;
        esac
      done
      exit 0
    fi
    case "$cmd" in
      "acl list") [ ! -f "$S/redis_acl_fail" ] || exit 1; cat "$S/acl_list" ;;
      *) exit 1 ;;
    esac
    exit 0 ;;
esac
exit 0
EOF

# ---- fixtures ----

RUNNER_PW='fixture-runner-redis-pw-0003'
RUNNER_HASH="$(printf '%s' "$RUNNER_PW" | sha256sum | cut -d ' ' -f 1)"
HOOK='https://example.test/hook/fixture'
RUNC=platform-jobs-runner
TESTC=platform-jobs-testapp
PGC=platform-data-postgres
RDC=platform-data-redis
export RUNC TESTC PGC RDC
ACL_BASE=$'user admin on sanitize-payload #fixturehash ~* &* +@all\nuser default off sanitize-payload resetchannels -@all\nuser health on nopass sanitize-payload resetchannels -@all +ping'
RUNNER_REST='~*:jobs:* resetchannels -@all +@list +@sortedset +@string +@keyspace +@transaction +@connection -@dangerous -@scripting -@pubsub -scan -randomkey -dbsize'
NOW=1800000000

# fresh: a clean root and state for the next scenario, all inputs valid, nothing installed yet.
fresh() {
  rm -rf "$T_TMP/root" "$STATE"
  mkdir -p "$T_TMP/root/etc/platform" "$T_TMP/root/opt/platform/backup" "$T_TMP/root/var/lib/platform/job-secrets" "$STATE/owner"
  t_reset_calls
  R="$T_TMP/root"
  printf '%s\n' "DISCORD_WEBHOOK=$HOOK" > "$R/etc/platform/jobs.env"
  printf '%s\n' "$RUNNER_PW" > "$R/etc/platform/jobs-redis.password"
  chmod 640 "$R/etc/platform/jobs.env" "$R/etc/platform/jobs-redis.password"
  setowner "$R/etc/platform/jobs.env" "0:64324"
  setowner "$R/etc/platform/jobs-redis.password" "0:64324"
  printf 'BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=America/Los_Angeles\n' > "$R/opt/platform/backup/window.env"
  chmod 755 "$R/var/lib/platform" "$R/var/lib/platform/job-secrets"
  chmod 2710 "$R/var/lib/platform/job-secrets"
  setowner "$R/var/lib/platform/job-secrets" "1001:64324"
  touch "$STATE/network_exists"
  printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'deploy:x:1001:1001::/home/deploy:/usr/local/bin/platform-login' > "$STATE/passwd"
  printf '%s\n' "$ACL_BASE" > "$STATE/acl_list"
  : > "$STATE/images"
  BACKUP_PATH="$R/opt/platform/backup"
  ENV_PATH="$R/etc/platform/jobs.env"
  export BACKUP_PATH ENV_PATH
  export INSTALL_JOBS_ROOT="$R"
  export INSTALL_JOBS_SUDO=fakesudo
  export INSTALL_JOBS_HEALTH_TIMEOUT=2
  export INSTALL_JOBS_POLL=0.1
  export INSTALL_JOBS_NOW="$NOW"
  export INSTALL_JOBS_NET_TIMEOUT=30
  unset INSTALL_JOBS_BUILD_TIMEOUT INSTALL_JOBS_NETWORK INSTALL_JOBS_DISK_PATH
}

setowner() { mkdir -p "$STATE/owner"; echo "$2" > "$STATE/owner/${1//\//_}"; }
ins() { run_cmd "$script" "$@"; }
J() { printf '%s' "$R/opt/platform/jobs"; }
STATUS() { printf '%s' "$R/var/lib/platform/jobs-status"; }
REG() { printf '%s' "$R/var/lib/platform/registry"; }

# only_already: every non-empty output line starts with "already:" and there is at least one.
only_already() { # label
  local extra
  extra="$(grep -v '^already:' <<<"$out" | grep -v '^$' || true)"
  if [ -n "$out" ] && [ -z "$extra" ]; then _pass; else _fail "$1" "non-already lines: $extra"; fi
}

# tags <script>: "<runner tag> <testapp tag>" computed from that script's embedded payloads.
tags() {
  INSTALL_JOBS_SOURCE_ONLY=1 bash -c '
    . "$1"
    d="$(mktemp -d)"
    mkdir "$d/b"
    write_inputs "$d/b" runner_inputs
    printf "%s %s\n" "$(source_hash "$d/b")" "$(testapp_hash "$d")"
    rm -rf "$d"
  ' bash "$1"
}
runner_tag_of() { local t; t="$(tags "$1")"; printf '%s' "${t%% *}"; }
testapp_tag_of() { local t; t="$(tags "$1")"; printf '%s' "${t##* }"; }

# mutate <script> <payload path under platform/jobs> <out>: the script with one extra line in that payload.
mutate() {
  awk -v p="# BEGIN-PAYLOAD platform/jobs/$2" '
    $0 == p { hit = 1 }
    hit && /cat <<.PLATFORM_PAYLOAD_EOF.$/ { print; print "MUTATED"; hit = 0; next }
    { print }' "$1" > "$3"
}

mutating_docker_calls() {
  grep -E '^docker ' "$CALL_LOG" | grep -vE '^docker (network inspect|inspect|port|image inspect|pull|run --rm|images) ' | grep -vE '^docker exec [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ [^ ]+ acl list$' || true
}

tsv() { # hb_age_seconds window config redis [extra-fields-line]
  local hb
  hb="$(date -u -d "@$((NOW - $1))" +%Y-%m-%dT%H:%M:%SZ)"
  printf '2026-01-01T00:00:00Z\t%s\t%s\t%s\t%s\tdev\n' "$hb" "$2" "$3" "$4" > "$(STATUS)/runner.tsv"
}

# ---- 1. usage, help, the privilege gate, ssh ----

fresh
ins --bogus
expect_rc "unknown argument" 2
ins --host
expect_rc "--host without a value" 2
ins --host -oProxyCommand=x
expect_rc "option-looking --host" 2
INSTALL_JOBS_HEALTH_TIMEOUT=abc ins verify
expect_rc "non-numeric health timeout" 2
INSTALL_JOBS_NETWORK='bad name;x' ins verify
expect_rc "malformed INSTALL_JOBS_NETWORK" 2
ins --help
expect_rc "--help succeeds" 0
expect_out_has "--help shows the usage line" "Usage: install-jobs.sh"
expect_out_has "--help lists testapp-up" "testapp-up"
expect_out_lacks "--help stops before the code" "set -euo"
INSTALL_JOBS_SUDO=nosudo ins install
expect_rc "no usable privilege" 1
expect_out_has "privilege failure is explained" "no usable privilege"
for m in testapp-up testapp-down; do
  t_reset_calls
  INSTALL_JOBS_SUDO=nosudo ins "$m"
  expect_rc "$m without privilege fails" 1
done
t_reset_calls
ins --host alias testapp-up
expect_rc "--host streams over ssh" 0
expect_calls_has "ssh runs bash -s with the mode" "ssh -o BatchMode=yes -- alias bash -s -- testapp-up"
if cmp -s "$STATE/ssh_stdin" "$script"; then _pass; else _fail "the script itself is streamed to ssh"; fi
if grep -q 'BUILD_TIMEOUT:-1200' "$script"; then _pass; else _fail "the image build is bounded at 20 minutes"; fi
if grep -q 'HEALTH_TIMEOUT:-90' "$script"; then _pass; else _fail "the health wait is 90s"; fi

# ---- 2. RUNNER_ACL_RULE equals install-data.sh's, and every Go source is embedded ----

a="$(grep '^readonly RUNNER_ACL_RULE=' "$script")"
b="$(grep '^readonly RUNNER_ACL_RULE=' "$data_script")"
if [ -n "$a" ] && [ "$a" = "$b" ]; then _pass; else _fail "RUNNER_ACL_RULE is identical in install-jobs.sh and install-data.sh" "jobs: $a / data: $b"; fi
# mutation: a changed rule in a copy must be seen as different
sed 's/-dbsize/-dbsize +flushall/' "$script" > "$T_TMP/mut-rule.sh"
c="$(grep '^readonly RUNNER_ACL_RULE=' "$T_TMP/mut-rule.sh")"
if [ "$c" != "$b" ]; then _pass; else _fail "a changed RUNNER_ACL_RULE would be caught by the comparison"; fi

listed="$(INSTALL_JOBS_SOURCE_ONLY=1 bash -c '. "$1"; { runner_inputs; testapp_inputs; } | sed "s|^|platform/jobs/|; s| .*||"' bash "$script" | sort)"
embedded="$(grep '^# BEGIN-PAYLOAD platform/jobs/' "$script" | sed 's/^# BEGIN-PAYLOAD //' | grep -vx 'platform/jobs/compose.yaml' | sort)"
expect_eq "every embedded jobs payload (except compose.yaml) is a listed build input" "$listed" "$embedded"
srcs="$( (cd "$repo_jobs/../.." && find platform/jobs -type f \( -name '*.go' ! -name '*_test.go' -o -name go.mod -o -name go.sum -o -name Dockerfile -o -name Dockerfile.testapp -o -name reserved-names.txt \) | sort) )"
expect_eq "every non-test Go source, go.mod, go.sum, Dockerfile and reserved-names.txt is embedded" "$srcs" "$embedded"
embed_has_compose="$(grep -c '^# BEGIN-PAYLOAD platform/jobs/compose.yaml$' "$script")"
expect_eq "compose.yaml is embedded" "$embed_has_compose" "1"
if grep -E '^# BEGIN-PAYLOAD platform/jobs/.*_test\.go' "$script" >/dev/null; then _fail "no test file is embedded"; else _pass; fi
base_dups="$(while read -r e; do printf '%s\n' "${e##*/}"; done <<<"$embedded" | grep '\.go$' | sort | uniq -d)"
expect_eq "Go file basenames are unique across both groups" "$base_dups" ""

# ---- 3. preconditions: every problem is reported together, nothing installed ----

fresh
rm -f "$STATE/network_exists" "$R/etc/platform/jobs.env" "$R/etc/platform/jobs-redis.password" "$R/opt/platform/backup/window.env"
touch "$STATE/absent_$RDC"
echo 10 > "$STATE/df_avail"
touch "$STATE/pull_fail"
ins install
expect_rc "install with every precondition missing" 1
expect_out_has "reports the missing network" "network platform is missing"
expect_out_has "reports the data stack" "the data stack is not healthy"
expect_out_has "reports window.env" "window.env missing"
expect_out_has "reports jobs.env" "jobs.env missing"
expect_out_has "reports the password file" "jobs-redis.password missing"
expect_out_has "reports free disk" "free disk space"
expect_out_has "reports the builder pull when the image is absent" "cannot pull the pinned builder image"
expect_out_has "shows how to create the two files" "openssl rand -hex 24"
expect_out_has "the create commands never overwrite an existing file" "sudo test -e"
expect_out_has "an existing file with a wrong mode is fixed, not recreated" "sudo chmod 0640"
expect_out_has "says nothing was installed" "nothing was installed"
if [ ! -e "$R/opt/platform/jobs" ] && [ ! -e "$R/var/lib/platform/registry" ] && [ ! -e "$R/var/lib/platform/jobs-status" ]; then _pass; else _fail "no directory was created"; fi
expect_eq "no mutating docker call ran" "$(mutating_docker_calls)" ""
expect_calls_lacks "no ACL command ran" "docker exec -i"

fresh
chmod 600 "$R/etc/platform/jobs.env"
printf 'DISCORD_WEBHOOK=http://example.test/x\n' > "$R/etc/platform/jobs.env"
printf 'bad pw with spaces\n' > "$R/etc/platform/jobs-redis.password"
printf 'BACKUP_WINDOW_START=05:00\nBACKUP_WINDOW_END=03:30\nBACKUP_WINDOW_TZ=America/Los_Angeles\n' > "$R/opt/platform/backup/window.env"
ins install
expect_rc "invalid input contents fail install" 1
expect_out_has "jobs.env mode is reported" "jobs.env uid:gid/mode is"
expect_out_has "jobs.env content is judged" "jobs.env must hold exactly one line"
expect_out_has "the password character set is judged" "jobs-redis.password must use only"
expect_out_has "window.env content is judged" "window.env is not valid"
expect_out_lacks "the webhook is never printed" "example.test/x"
expect_out_lacks "the password is never printed" "bad pw"

# ---- 4. build network: checked only when the image for the current source hash is absent ----

fresh
RTAG="$(runner_tag_of "$script")"
touch "$STATE/pull_fail" "$STATE/moddl_fail"
rm -f "$R/etc/platform/jobs.env"
ins install
expect_rc "unreachable registry and proxy plus a missing input" 1
expect_out_has "the registry problem is listed" "cannot pull the pinned builder image"
expect_out_has "the registry problem names the pinned image" "golang:"
expect_out_has "the pull error text is shown" "pull error: stub registry down"
expect_out_has "the other problem is listed with it" "jobs.env missing"
expect_calls_lacks "nothing was built" "docker build"
rm -f "$STATE/pull_fail"
ins install
expect_out_has "the module proxy problem is listed" "go mod download"
expect_out_has "the module error text is shown" "go: module proxy error: stub"
expect_out_lacks "the pull succeeded now" "cannot pull"
rm -f "$STATE/moddl_fail"
expect_calls_has "the module download check ran against the extracted sources" "docker run --rm"

fresh
touch "$STATE/pull_fail" "$STATE/moddl_fail"
echo "platform-jobs-runner:$RTAG" > "$STATE/images"
ins install
expect_rc "first install with the image present and the network down" 0
expect_calls_lacks "no pull when the image is present" "docker pull"
expect_calls_lacks "no module check when the image is present" "docker run --rm"
expect_calls_lacks "no build when the image is present" "docker build"
expect_out_has "the image is reported as already present" "already: image platform-jobs-runner:$RTAG"
# the second install, still with the network stubs failing, prints only already:
t_reset_calls
ins install
expect_rc "second install with the image present and the network down" 0
only_already "install with the image present and registry and proxy unreachable prints only already:"
expect_calls_lacks "second install: no pull" "docker pull"
expect_calls_lacks "second install: no module check" "docker run --rm"
expect_calls_lacks "second install: no build" "docker build"

# a nearly full disk does not block an install that builds nothing
fresh
echo 10 > "$STATE/df_avail"
echo "platform-jobs-runner:$RTAG" > "$STATE/images"
ins install
expect_rc "a full disk does not block an install with the image present" 0

# ---- 5. a full first install, then idempotence ----

fresh
ins install
expect_rc "first install" 0
expect_out_has "image built" "changed: image platform-jobs-runner:$RTAG"
expect_calls_has "docker build tags the source hash" "-t platform-jobs-runner:$RTAG"
expect_out_has "the runner user is created" "changed: Redis runner user created"
expect_eq "ACL SETUSER ran once" "$(wc -l < "$STATE/setuser_count" | tr -d ' ')" "1"
expect_eq "ACL SAVE ran once" "$(wc -l < "$STATE/acl_save_count" | tr -d ' ')" "1"
expect_eq "the ACL password is the file content without its newline" "$(cat "$STATE/setuser_pw")" "$RUNNER_PW"
if grep -qF -e "$RUNNER_PW" -e "$HOOK" "$CALL_LOG"; then _fail "no secret in any argv" "a secret reached an argv"; else _pass; fi
expect_out_lacks "the password is not printed" "$RUNNER_PW"
expect_calls_has "a first install recreates the container" "--force-recreate"
expect_eq "compose got the image tag" "$(cat "$STATE/compose_tag")" "$RTAG"
expect_eq "the registry root is deploy-owned" "$(stat -c '%a' "$(REG)") $(cat "$STATE/owner/${R//\//_}_var_lib_platform_registry")" "755 1001:1001"
expect_eq "jobs-status is 65532 0755" "$(stat -c '%a' "$(STATUS)") $(cat "$STATE/owner/${R//\//_}_var_lib_platform_jobs-status")" "755 65532:65532"
expect_eq "jobs-state is 65532 0700" "$(stat -c '%a' "$R/var/lib/platform/jobs-state") $(cat "$STATE/owner/${R//\//_}_var_lib_platform_jobs-state")" "700 65532:65532"
expect_eq "inputs.sha256 is 0600" "$(stat -c '%a' "$(J)/inputs.sha256")" "600"
expect_eq "inputs.sha256 holds both hashes" "$(wc -l < "$(J)/inputs.sha256" | tr -d ' ')" "2"
if grep -q "^jobs-redis.password=$RUNNER_HASH\$" "$(J)/inputs.sha256"; then _pass; else _fail "the record holds the stripped-password hash"; fi
expect_eq "compose.yaml is 0644" "$(stat -c '%a' "$(J)/compose.yaml")" "644"
if grep -q 'user: "65532:65532"' "$(J)/compose.yaml"; then _pass; else _fail "the installed compose.yaml is the embedded payload"; fi

t_reset_calls
ins install
expect_rc "second install" 0
only_already "a second install prints only already: lines"
expect_calls_lacks "no ACL command on the second install" "docker exec -i"
expect_calls_lacks "no build on the second install" "docker build"
expect_calls_lacks "no recreate on the second install" "--force-recreate"
expect_eq "no second SETUSER" "$(wc -l < "$STATE/setuser_count" | tr -d ' ')" "1"

# ---- 6. password normalisation: with or without a trailing newline ----

printf '%s' "$RUNNER_PW" > "$R/etc/platform/jobs-redis.password"
t_reset_calls
ins install
expect_rc "install after rewriting the password without its newline" 0
only_already "the same password without a newline prints only already:"
expect_eq "no repeated SETUSER for the no-newline form" "$(wc -l < "$STATE/setuser_count" | tr -d ' ')" "1"
expect_calls_lacks "the no-newline form does not recreate" "--force-recreate"
ins verify
# verify needs a heartbeat file; this one only checks the record and the ACL hash
expect_out_has "the record still matches" "PASS: inputs.sha256 matches jobs.env and jobs-redis.password"

fresh
printf '%s' "$RUNNER_PW" > "$R/etc/platform/jobs-redis.password"
ins install
expect_rc "first install with a no-newline password" 0
expect_eq "the ACL password is the same for the no-newline form" "$(cat "$STATE/setuser_pw")" "$RUNNER_PW"
printf '%s\n' "$RUNNER_PW" > "$R/etc/platform/jobs-redis.password"
t_reset_calls
ins install
only_already "the newline form after the no-newline form prints only already:"
expect_eq "no repeated SETUSER (one newline stripped on both forms)" "$(wc -l < "$STATE/setuser_count" | tr -d ' ')" "1"

# ---- 7. changed inputs, failed recreate, unhealthy wait ----

fresh
ins install
ins verify
tsv 10 ok ok ok
ins verify
expect_rc "verify passes after a clean install with a fresh heartbeat" 0
printf '%s\n' "DISCORD_WEBHOOK=${HOOK}2" > "$R/etc/platform/jobs.env"
ins verify
expect_rc "a changed jobs.env without a recreate fails verify" 1
expect_out_has "the stale mount is named" "stale single-file mount"
t_reset_calls
ins install
expect_rc "install after a jobs.env change" 0
expect_calls_has "a changed jobs.env hash forces a recreate" "--force-recreate"
ins verify
expect_rc "verify passes again after the recreate" 0

printf '%s\n' "${RUNNER_PW}x" > "$R/etc/platform/jobs-redis.password"
t_reset_calls
ins install
expect_rc "install after a password change" 0
expect_calls_has "a changed password forces a recreate" "--force-recreate"
expect_out_has "a changed password re-applies the user" "changed: Redis runner user (password or rule changed)"
expect_eq "SETUSER ran again for the new password" "$(wc -l < "$STATE/setuser_count" | tr -d ' ')" "2"
expect_eq "SETUSER carried the new password" "$(cat "$STATE/setuser_pw")" "${RUNNER_PW}x"

# a failed recreate leaves the old record
cp "$(J)/inputs.sha256" "$T_TMP/record.old"
printf '%s\n' "DISCORD_WEBHOOK=${HOOK}3" > "$R/etc/platform/jobs.env"
touch "$STATE/up_fail"
ins install
expect_rc "a failed compose up fails install" 1
if cmp -s "$T_TMP/record.old" "$(J)/inputs.sha256"; then _pass; else _fail "a failed recreate keeps the old record"; fi
ins verify
expect_rc "verify still fails after the failed recreate" 1
rm -f "$STATE/up_fail"
t_reset_calls
ins install
expect_rc "the next install after the failure" 0
expect_calls_has "the next install recreates" "--force-recreate"

# an unhealthy wait leaves the old record
cp "$(J)/inputs.sha256" "$T_TMP/record.old"
printf '%s\n' "DISCORD_WEBHOOK=${HOOK}4" > "$R/etc/platform/jobs.env"
touch "$STATE/unhealthy_after_up"
ins install
expect_rc "an unhealthy runner fails install" 1
expect_out_has "the unhealthy wait is explained" "not healthy after 2s"
if cmp -s "$T_TMP/record.old" "$(J)/inputs.sha256"; then _pass; else _fail "an unhealthy wait keeps the old record"; fi
rm -f "$STATE/unhealthy_after_up"
t_reset_calls
ins install
expect_rc "the next install after an unhealthy wait" 0
expect_calls_has "the next install recreates after an unhealthy wait" "--force-recreate"

# a first install that fails the wait writes no record, and the next install recreates
fresh
touch "$STATE/unhealthy_after_up"
ins install
expect_rc "a first install with an unhealthy runner fails" 1
if [ ! -e "$(J)/inputs.sha256" ]; then _pass; else _fail "no record after a failed first install"; fi
rm -f "$STATE/unhealthy_after_up"
t_reset_calls
ins install
expect_rc "retry after the failed first install" 0
expect_calls_has "the retry recreates (no record)" "--force-recreate"

# a stopped runner is started again by a plain up
printf 'exited|\n' > "$STATE/state_$RUNC"
t_reset_calls
ins install
expect_rc "install with a stopped runner and a matching record" 0
expect_calls_lacks "a stopped runner with a matching record needs no force" "--force-recreate"
expect_out_has "the stopped runner is reported as started" "changed: runner started"
expect_eq "the plain up restarted the runner" "$(wc -l < "$STATE/restart_log" | tr -d ' ')" "1"

# a build that hangs is bounded
fresh
touch "$STATE/build_hang"
INSTALL_JOBS_BUILD_TIMEOUT=1 ins install
expect_rc "a hanging build is cut off" 1
expect_out_has "the build timeout is explained" "failed or timed out"
rm -f "$STATE/build_hang"
touch "$STATE/build_fail"
ins install
expect_rc "a failed build fails install" 1
expect_out_has "the build error tail is shown" "build error: stub"
rm -f "$STATE/build_fail"
touch "$STATE/setuser_fail"
ins install
expect_rc "a refused ACL SETUSER fails install" 1
expect_out_lacks "the password is not in the failure" "$RUNNER_PW"
expect_out_has "only the error class of the refused SETUSER is shown" "(redis answered: ERR)"
expect_out_lacks "the reply text of the refused SETUSER is not shown" "ERR stub"
rm -f "$STATE/setuser_fail"

# a drifted rule (the user turned off) with an unchanged password is re-applied by install
fresh
ins install
expect_rc "install before the rule drift" 0
sed -i 's/^user runner on /user runner off /' "$STATE/acl_list"
t_reset_calls
ins install
expect_rc "install over a drifted runner rule" 0
expect_out_has "a drifted rule is re-applied" "changed: Redis runner user (password or rule changed)"
expect_eq "SETUSER ran again for the drift" "$(wc -l < "$STATE/setuser_count" | tr -d ' ')" "2"
t_reset_calls
ins install
only_already "after the re-apply the next install prints only already:"

# a broken admin login is an up-front precondition, before any build
fresh
touch "$STATE/redis_acl_fail"
ins install
expect_rc "install with a broken Redis admin login" 1
expect_out_has "the admin login problem is listed up front" "cannot read ACL LIST as the Redis admin user"
expect_calls_lacks "nothing was built before the admin login problem" "docker build"

# ---- 8. per-file hash cases ----

base_runner="$(runner_tag_of "$script")"
base_testapp="$(testapp_tag_of "$script")"
if [ -n "$base_runner" ] && [ "$base_runner" != "$base_testapp" ]; then _pass; else _fail "both tags are computed and differ"; fi
while read -r path _; do
  mutate "$script" "$path" "$T_TMP/mut.sh"
  expect_eq "the runner tag changes when $path changes" "$([ "$(runner_tag_of "$T_TMP/mut.sh")" != "$base_runner" ] && echo changed || echo same)" "changed"
done < <(INSTALL_JOBS_SOURCE_ONLY=1 bash -c '. "$1"; runner_inputs' bash "$script")
for path in testapp/testapp_main.go testapp/testapp_handler.go Dockerfile.testapp compose.yaml; do
  mutate "$script" "$path" "$T_TMP/mut.sh"
  expect_eq "the runner tag does not change when $path changes" "$(runner_tag_of "$T_TMP/mut.sh")" "$base_runner"
done
for path in testapp/testapp_main.go testapp/testapp_handler.go Dockerfile.testapp go.mod go.sum; do
  mutate "$script" "$path" "$T_TMP/mut.sh"
  expect_eq "the testapp tag changes when $path changes" "$([ "$(testapp_tag_of "$T_TMP/mut.sh")" != "$base_testapp" ] && echo changed || echo same)" "changed"
done
mutate "$script" internal/queue/take.go "$T_TMP/mut.sh"
expect_eq "a runner-only edit does not change the testapp tag" "$(testapp_tag_of "$T_TMP/mut.sh")" "$base_testapp"
mutate "$script" Dockerfile "$T_TMP/mut.sh"
expect_eq "a runner Dockerfile edit does not change the testapp tag" "$(testapp_tag_of "$T_TMP/mut.sh")" "$base_testapp"
# a go.mod edit rebuilds both images
mutate "$script" go.mod "$T_TMP/mut.sh"
expect_eq "a go.mod edit changes both tags" "$([ "$(runner_tag_of "$T_TMP/mut.sh")" != "$base_runner" ] && [ "$(testapp_tag_of "$T_TMP/mut.sh")" != "$base_testapp" ] && echo both || echo no)" "both"

# a source change on the host rebuilds: install with a mutated script builds a new tag and recreates
fresh
ins install
mutate "$script" internal/mask/mask.go "$T_TMP/mut-install.sh"
chmod +x "$T_TMP/mut-install.sh"
MTAG="$(runner_tag_of "$T_TMP/mut-install.sh")"
t_reset_calls
run_cmd "$T_TMP/mut-install.sh" install
expect_rc "install with a changed source" 0
expect_calls_has "a changed source builds the new tag" "-t platform-jobs-runner:$MTAG"
expect_eq "compose got the new tag" "$(cat "$STATE/compose_tag")" "$MTAG"
tsv 10 ok ok ok
run_cmd "$script" verify
expect_rc "verify against the old source fails after the new one runs" 1
expect_out_has "image hash drift is named" "image hash drift"

# ---- 9. verify ----

good_verify() { # label
  fresh
  ins install >/dev/null
  tsv 10 ok ok ok
  ins verify
  expect_rc "$1: baseline verify passes" 0
}
good_verify "verify"
expect_out_has "verify summary" "all checks passed"
ins status
expect_rc "status exits 0" 0

verify_case() { # label want-rc phrase
  ins verify
  expect_rc "$1" "$2"
  expect_out_has "$1 (reason)" "$3"
}

printf 'platform.app\n' > "$STATE/labels_$RUNC"
verify_case "a labelled runner container fails verify" 1 "carries the platform.app label"
ins status
expect_rc "status never fails on a FAIL" 0
: > "$STATE/labels_$RUNC"

printf '%s|/opt/platform/backup/window.env|false\n' "$BACKUP_PATH" > "$STATE/mounts_$RUNC"
verify_case "a single-file window.env mount fails verify" 1 "not mounted read-only at /opt/platform/backup"
printf '%s|/opt/platform/backup|true\n' "$BACKUP_PATH" > "$STATE/mounts_$RUNC"
verify_case "a writable backup mount fails verify" 1 "not mounted read-only at /opt/platform/backup"
printf '%s|/opt/platform/backup|false\n' "$BACKUP_PATH" > "$STATE/mounts_$RUNC"

printf 'platform-jobs-runner:0000000000000000\n' > "$STATE/cimg_$RUNC"
verify_case "a container on an old image fails verify" 1 "image hash drift"
echo "platform-jobs-runner:$RTAG" > "$STATE/cimg_$RUNC"

printf 'running|unhealthy\n' > "$STATE/state_$RUNC"
verify_case "an unhealthy runner fails verify" 1 "is unhealthy"
printf 'running|healthy\n' > "$STATE/state_$RUNC"

printf 'platform\nextra\n' > "$STATE/networks_$RUNC"
verify_case "a second network fails verify" 1 "is not exactly on the platform network"
printf 'platform\n' > "$STATE/networks_$RUNC"

tsv 121 ok ok ok
verify_case "a heartbeat older than 120s fails verify" 1 "heartbeat is 121s old"
tsv 120 ok ok ok
ins verify
expect_rc "a heartbeat of exactly 120s passes" 0
tsv 10 ok ok invalid
verify_case "redis_state=invalid fails verify" 1 "redis_state is invalid"
tsv 10 invalid ok ok
verify_case "window_state=invalid fails verify" 1 "window_state is invalid"
tsv 10 ok ok down
verify_case "redis_state=down only warns" 0 "WARN: runner redis_state is down"
tsv 10 ok invalid ok
verify_case "config_state=invalid only warns" 0 "WARN: runner config_state is invalid"
tsv 10 ok bogus ok
verify_case "an unknown config_state fails verify" 1 "config_state is 'bogus'"

rm -f "$(STATUS)/runner.tsv"
verify_case "a missing runner.tsv fails verify" 1 "runner.tsv missing"
: > "$(STATUS)/runner.tsv"
verify_case "an empty runner.tsv fails verify" 1 "runner.tsv is empty"
printf 'a\tb\tc\td\te\n' > "$(STATUS)/runner.tsv"
verify_case "five fields fail verify" 1 "runner.tsv has 5 tab-separated fields, want exactly six"
printf 'a\tb\tc\td\te\tf\tg\n' > "$(STATUS)/runner.tsv"
verify_case "seven fields fail verify" 1 "runner.tsv has 7 tab-separated fields, want exactly six"
printf 'a b c d e f\n' > "$(STATUS)/runner.tsv"
verify_case "space-separated fields fail verify" 1 "runner.tsv has 1 tab-separated fields"
printf '2026-01-01T00:00:00Z\tnot-a-time\tok\tok\tok\tdev\n' > "$(STATUS)/runner.tsv"
verify_case "a garbled heartbeat fails verify" 1 "heartbeat_at is not an RFC3339 UTC time"
tsv 10 ok ok ok

# the ACL rule and hash
good_hash_line="user runner on sanitize-payload #$RUNNER_HASH $RUNNER_REST"
grep -v '^user runner ' "$STATE/acl_list" > "$STATE/acl_list.n"
printf '%s +@dangerous\n' "$good_hash_line" >> "$STATE/acl_list.n"
cp "$STATE/acl_list.n" "$STATE/acl_list"
verify_case "an extra ACL rule fails verify" 1 "unexpected rule '+@dangerous'"
grep -v '^user runner ' "$STATE/acl_list" > "$STATE/acl_list.n"
printf '%s\n' "$good_hash_line" | sed 's/~\*:jobs:\*/~*:jobs:* ~other:*/' >> "$STATE/acl_list.n"
cp "$STATE/acl_list.n" "$STATE/acl_list"
verify_case "an extra key scope fails verify" 1 "extra key or channel scope"
grep -v '^user runner ' "$STATE/acl_list" > "$STATE/acl_list.n"
printf 'user runner on sanitize-payload #%s %s\n' "$(printf '%s' other | sha256sum | cut -d ' ' -f 1)" "$RUNNER_REST" >> "$STATE/acl_list.n"
cp "$STATE/acl_list.n" "$STATE/acl_list"
verify_case "a runner hash that differs from the password file fails verify" 1 "password hash differs from jobs-redis.password"
grep -v '^user runner ' "$STATE/acl_list" > "$STATE/acl_list.n"
cp "$STATE/acl_list.n" "$STATE/acl_list"
verify_case "a missing runner user fails verify" 1 "runner user is missing"
touch "$STATE/redis_acl_fail"
verify_case "an unreadable ACL LIST fails verify" 1 "cannot read ACL LIST"
rm -f "$STATE/redis_acl_fail"
expect_out_lacks "no hash is ever printed" "$RUNNER_HASH"

# modes and the record
good_verify "modes"
chmod 600 "$R/etc/platform/jobs.env"
verify_case "a wrong jobs.env mode fails verify" 1 "jobs.env uid:gid/mode"
chmod 640 "$R/etc/platform/jobs.env"
chmod 777 "$(STATUS)"
verify_case "a wrong jobs-status mode fails verify" 1 "jobs-status directory uid:gid/mode"
chmod 755 "$(STATUS)"
rm -f "$(J)/inputs.sha256"
verify_case "a missing record fails verify" 1 "inputs.sha256 missing"

# ---- 10. the test app: explicit modes only ----

fresh
ins install
TTAG="$(testapp_tag_of "$script")"
t_reset_calls
ins verify
ins status
ins install
expect_calls_lacks "install, verify and status never touch the testapp container" "$TESTC"
expect_calls_lacks "install, verify and status never touch the jobstest alias" "jobstest"
if [ ! -e "$(REG)/jobstest" ]; then _pass; else _fail "install never writes the testapp registry file"; fi

ins testapp-up
expect_rc "testapp-up without the job secret" 1
expect_out_has "the missing job secret is explained" "platform new-db jobstest"
expect_calls_lacks "nothing built without the secret" "docker build"

mkdir -p "$R/var/lib/platform/job-secrets/jobstest"
printf '%s' 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN' > "$R/var/lib/platform/job-secrets/jobstest/jobs-secret"
touch "$STATE/pull_fail"
ins testapp-up
expect_rc "testapp-up with the registry unreachable and no image" 1
expect_out_has "the build network is checked for the testapp too" "cannot pull the pinned builder image"
rm -f "$STATE/pull_fail"
t_reset_calls
ins testapp-up
expect_rc "testapp-up" 0
expect_calls_has "the testapp image is built from the hash of group 2 plus go.mod and go.sum" "-t platform-jobs-testapp:$TTAG"
expect_calls_has "the testapp is built from its own Dockerfile" "Dockerfile.testapp"
expect_calls_lacks "testapp-up never touches the runner container or image" "$RUNC"
expect_eq "the testapp container carries exactly the platform.app=jobstest label" "$(cat "$STATE/labels_$TESTC")" "platform.app"
if grep -qxF 'platform.app=jobstest' "$STATE/run_args"; then _pass; else _fail "the run command labels the container platform.app=jobstest"; fi
if grep -qxF 'jobstest' "$STATE/run_args"; then _pass; else _fail "the run command sets the alias jobstest"; fi
if grep -qxF 'platform' "$STATE/run_args"; then _pass; else _fail "the testapp joins the platform network"; fi
if grep -qxF 'platform-jobs-testapp:'"$TTAG" "$STATE/run_args"; then _pass; else _fail "the container uses the hash-tagged image"; fi
yaml="$(REG)/jobstest/app.yaml"
expect_file "the registry file is written" "$yaml"
expect_eq "app.yaml is 0644" "$(stat -c '%a' "$yaml")" "644"
validate_out="$("$here/../registry/validate-app-yaml.sh" "$yaml" 2>&1)"
validate_rc=$?
expect_eq "app.yaml passes validate-app-yaml.sh" "$validate_rc $validate_out" "0 "
for k in schema_version name owner purpose template memory_cap port; do
  if grep -q "^$k:" "$yaml"; then _pass; else _fail "app.yaml has the required key $k"; fi
done
yaml_jobs="$(sed -n 's/^  - name: //p' "$yaml" | paste -sd, -)"
env_jobs="$(sed -n 's/^JOBS_DECLARED=//p' "$STATE/env_$TESTC")"
expect_eq "the JOBS_DECLARED env var equals the jobs of the written app.yaml" "$env_jobs" "$yaml_jobs"
default_jobs="$(sed -n 's/^const DefaultDeclared = "\(.*\)"$/\1/p' "$repo_jobs/testapp/testapp_handler.go")"
expect_eq "the declared jobs equal the testapp's DefaultDeclared" "$env_jobs" "$default_jobs"
if grep -qxF 'JOBS_SECRET_FILE=/run/jobs-secret' "$STATE/env_$TESTC"; then _pass; else _fail "the secret file env var is set"; fi
if grep -qF 'abcdefghijklmnop' "$CALL_LOG" "$STATE/run_args" "$STATE/env_$TESTC"; then _fail "the job secret value stays out of every argv and env"; else _pass; fi

t_reset_calls
ins testapp-up
expect_rc "second testapp-up" 0
only_already "a repeated testapp-up prints only already:"
expect_calls_lacks "no rebuild on a repeat" "docker build"
expect_calls_lacks "no run on a repeat" "docker run -d"

t_reset_calls
touch "$STATE/rm_log"
ins verify
ins status
ins install
expect_calls_lacks "install, verify and status leave a running testapp alone" "$TESTC"
if [ "$(wc -l < "$STATE/rm_log")" -eq 0 ]; then _pass; else _fail "no container was removed"; fi

# a container that holds the testapp's name without its label is somebody else's: never replaced, never removed
: > "$STATE/labels_$TESTC"
: > "$STATE/rm_log"
t_reset_calls
ins testapp-up
expect_rc "testapp-up refuses a foreign container of that name" 1
expect_out_has "the foreign container is named as not the test app" "without the platform.app=jobstest label"
ins testapp-down
expect_rc "testapp-down refuses a foreign container of that name" 1
expect_out_has "testapp-down explains the refusal" "is not removed"
if [ "$(wc -l < "$STATE/rm_log")" -eq 0 ]; then _pass; else _fail "the foreign container was removed"; fi
printf 'platform.app\n' > "$STATE/labels_$TESTC"

# a testapp that drifted off the platform network is recreated
printf 'other\n' > "$STATE/networks_$TESTC"
ins testapp-up
expect_rc "testapp-up over a testapp on the wrong network" 0
expect_out_has "a network-drifted testapp is recreated" "changed: $TESTC recreated"

# a stale testapp (wrong declared list) is recreated
printf 'JOBS_DECLARED=other\n' > "$STATE/env_$TESTC"
ins testapp-up
expect_rc "testapp-up over a stale container" 0
expect_out_has "a stale testapp is recreated" "changed: $TESTC recreated"

: > "$STATE/rm_log"
: > "$STATE/rmi_log"
t_reset_calls
ins testapp-down
expect_rc "testapp-down" 0
expect_eq "testapp-down removed exactly the testapp container" "$(cat "$STATE/rm_log")" "$TESTC"
expect_eq "testapp-down removed exactly the testapp image" "$(cat "$STATE/rmi_log")" "platform-jobs-testapp:$TTAG"
if [ ! -e "$yaml" ]; then _pass; else _fail "testapp-down removes the registry file"; fi
if grep -qxF "platform-jobs-runner:$RTAG" "$STATE/images" && [ -f "$STATE/cimg_$RUNC" ]; then _pass; else _fail "testapp-down leaves the runner image and container"; fi
if [ -f "$R/var/lib/platform/job-secrets/jobstest/jobs-secret" ]; then _pass; else _fail "testapp-down leaves the job secret"; fi
expect_out_has "testapp-down prints the by-hand removal commands" "ACL DELUSER jobstest"
t_reset_calls
ins testapp-down
expect_rc "second testapp-down" 0
only_already "a repeated testapp-down prints only already:"
expect_calls_lacks "nothing is removed on a repeat" "docker rm"

t_finish
