#!/usr/bin/env bash
# Stub tests for install-cloudflared-host.sh. Every host file lands under INSTALL_CLOUDFLARED_ROOT, the privilege prefix
# is a logging fakesudo, and docker/stat/getent/ss/ps/systemctl are stubs on PATH (stat reports root ownership and the
# token gid unless a test overrides it; modes are real). No docker, firewall, systemd or network is touched.
#
# FIXTURES FLAGGED UNVERIFIED: the shapes of the stubbed `docker ps -q`, `docker inspect --format {{.State.Pid}}`,
# `docker info --format {{.LoggingDriver}}` and `ss -ltnpH` output are reconstructed from the documented formats, not
# captured from a live host.
#
# No address literals and no real token: the fixture token below is a fake string.
# SC2016: stub bodies are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# SC2154: $out and $rc are set by run_cmd in lib.sh.
# shellcheck disable=SC1091,SC2016,SC2034,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/install-cloudflared-host.sh"
repo_compose="$here/../ingress/compose.host-network.yaml"

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
exit 0
EOF

# systemctl must never be called: it only logs.
mkstub systemctl <<'EOF'
exit 0
EOF

# stat: real mode; owner root:root, except the token file (root:64321) and the webhook and state dirs (65532:65532).
# A test lists "<basename> <uid:gid>" lines in $STATE/stat_override to change an owner. %g on the socket reports
# $STATE/docker_gid.
mkstub stat <<'EOF'
fmt="$2"
path="${@: -1}"
base="$(basename "$path")"
if [ ! -e "$path" ] && [ ! -L "$path" ]; then exit 1; fi
ug="0:0"
[ "$base" != "cloudflared.token" ] || ug="0:64321"
case "$base" in cloudflared.webhook | cloudflared-supervisor-blue | cloudflared-supervisor-green) ug="65532:65532" ;; esac
if [ -f "$STATE/stat_override" ]; then
  line="$(grep -F -- "$base " "$STATE/stat_override" | head -n1 || true)"
  [ -z "$line" ] || ug="${line##* }"
fi
case "$fmt" in
  '%g') if [ "$base" = "dsock" ]; then cat "$STATE/docker_gid"; else echo "${ug#*:}"; fi ;;
  '%u:%g %a') echo "$ug $(/usr/bin/stat -c '%a' -- "$path")" ;;
  *) /usr/bin/stat -c "$fmt" -- "$path" ;;
esac
EOF

mkstub getent <<'EOF'
case "$1" in
  group)
    if [ "${2:-}" = "64321" ] && [ ! -f "$STATE/group_absent" ]; then
      echo "cftoken:x:64321:$(cat "$STATE/group_members" 2>/dev/null)"
      exit 0
    fi
    # a bare `getent group` lists every entry: $STATE/group_all (absent: nothing listed)
    if [ -z "${2:-}" ]; then cat "$STATE/group_all" 2>/dev/null; exit 0; fi
    exit 2 ;;
  passwd) cat "$STATE/passwd" 2>/dev/null; exit 0 ;;
esac
exit 2
EOF

# ss: prints $STATE/ss_out. ps: `ps -o ppid= -p N` answers from $STATE/ppid_N.
mkstub ss <<'EOF'
[ ! -f "$STATE/ss_fail" ] || exit 1
cat "$STATE/ss_out" 2>/dev/null
exit 0
EOF

mkstub ps <<'EOF'
pid="${@: -1}"
[ -f "$STATE/ppid_$pid" ] || exit 1
cat "$STATE/ppid_$pid"
exit 0
EOF

# docker: read-only subset with an independent switch per operation (files in $STATE): info_fail, compose_version_fail,
# compose_config_fail, ps_fail, inspect_fail. A colour runs when $STATE/running_<service> holds its pid.
mkstub docker <<'EOF'
S="$STATE"
sub="$1"
shift
case "$sub" in
  info)
    [ ! -f "$S/info_fail" ] || exit 1
    cat "$S/logdriver" 2>/dev/null || echo journald
    exit 0 ;;
  compose)
    case "$1" in
      version) [ ! -f "$S/compose_version_fail" ] || exit 1; echo "Docker Compose version v2"; exit 0 ;;
    esac
    case "$*" in
      *" config -q"*) [ ! -f "$S/compose_config_fail" ] || exit 1; exit 0 ;;
    esac
    exit 0 ;;
  ps)
    [ ! -f "$S/ps_fail" ] || exit 1
    proj=0
    for a in "$@"; do [ "$a" != "label=com.docker.compose.project=platform-cloudflared" ] || proj=1; done
    [ "$proj" -eq 1 ] || exit 0
    for a in "$@"; do
      case "$a" in
        label=com.docker.compose.service=*)
          svc="${a#label=com.docker.compose.service=}"
          [ ! -f "$S/running_$svc" ] || echo "id_$svc" ;;
      esac
    done
    exit 0 ;;
  inspect)
    [ ! -f "$S/inspect_fail" ] || exit 1
    id="${@: -1}"
    cat "$S/running_${id#id_}"
    exit 0 ;;
esac
exit 0
EOF

# ---- fixtures ----

TOKEN='FIXTURE-TUNNEL-TOKEN-NOT-A-REAL-SECRET-0123456789'
WEBHOOK='FIXTURE-WEBHOOK-NOT-A-REAL-URL-0123456789'
LOOP="$(t_ip4 127 0 0 1)"

# fresh: a clean root and clean state for the next scenario, all inputs valid and Docker reachable.
fresh() {
  rm -rf "$T_TMP/root" "$STATE" "$T_TMP/dsock"
  mkdir -p "$T_TMP/root/etc/platform" "$STATE"
  t_reset_calls
  R="$T_TMP/root"
  printf '%s\n' "$TOKEN" > "$R/etc/platform/cloudflared.token"
  chmod 640 "$R/etc/platform/cloudflared.token"
  printf '%s\n' "$WEBHOOK" > "$R/etc/platform/cloudflared.webhook"
  chmod 600 "$R/etc/platform/cloudflared.webhook"
  : >"$T_TMP/dsock"
  echo 998 > "$STATE/docker_gid"
  printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'admin:x:1000:1000::/home/admin:/bin/bash' > "$STATE/passwd"
  export INSTALL_CLOUDFLARED_ROOT="$R"
  export INSTALL_CLOUDFLARED_SUDO=fakesudo
  export INSTALL_CLOUDFLARED_SOCKET="$T_TMP/dsock"
  unset INSTALL_CLOUDFLARED_DOCKER
}

ins() { run_cmd "$script" "$@"; }
installed() { fresh; ins install; t_reset_calls; }

# forbid <label>: no container start/stop/pull/network/run, no systemctl, no deploy-group or ingress.env read.
forbid() {
  if grep -qE '^(fakesudo )?docker (compose (.* )?(up|start|stop|restart|pull|down|rm)( |$)|run( |$)|start( |$)|stop( |$)|pull( |$)|rm( |$)|network( |$))' "$CALL_LOG"; then
    _fail "$1: a forbidden docker call ran" "$(grep -E '^(fakesudo )?docker ' "$CALL_LOG" | head -n3)"
  else _pass; fi
  expect_calls_lacks "$1: no systemctl" "systemctl"
  expect_calls_lacks "$1: no systemd path" "systemd"
  expect_eq "$1: no systemd directory created" "$([ -e "$R/etc/systemd" ] || [ -e "$R/lib/systemd" ] && echo yes || echo no)" "no"
  expect_calls_lacks "$1: no deploy group lookup" "getent group deploy"
  expect_calls_lacks "$1: no ingress.env read" "ingress.env"
}

no_docker_calls() {
  if grep -qE '^(fakesudo )?docker ' "$CALL_LOG"; then _fail "$1" "a docker command ran: $(grep -E '^(fakesudo )?docker ' "$CALL_LOG" | head -n1)"; else _pass; fi
}

# nothing_placed <label>: no compose, no .new file and no state directory under the fake root.
nothing_placed() {
  expect_eq "$1: nothing was placed" "$(find "$R" ! -type l \( -name 'compose.yaml*' -o -name 'cloudflared-supervisor-*' \) 2>/dev/null | wc -l)" "0"
}

# ---- usage ----

fresh
ins bogus
expect_rc "unknown subcommand is a usage error" 2
expect_out_has "usage is printed" "usage: install-cloudflared-host.sh"
expect_calls_lacks "an unknown subcommand makes no sudo call" "fakesudo"
expect_calls_lacks "an unknown subcommand makes no nosudo call" "nosudo"
ins install extra
expect_rc "too many arguments is a usage error" 2
expect_calls_lacks "too many arguments makes no sudo call" "fakesudo"
ins --help
expect_rc "--help succeeds" 0
expect_out_has "--help shows the usage" "Usage: install-cloudflared-host.sh"
expect_out_lacks "--help stops before the code" "set -euo"

# ---- no usable privilege: every subcommand fails closed and does nothing else ----

for sub in install status verify; do
  fresh
  INSTALL_CLOUDFLARED_SUDO=nosudo ins "$sub"
  expect_rc "$sub without privilege" 1
  expect_out_has "$sub without privilege names the cause" "no usable privilege"
  expect_eq "$sub without privilege runs only the probe" "$(grep -c . "$CALL_LOG")" "1"
  nothing_placed "$sub without privilege"
done

# ---- a fresh install ----

fresh
before="$(md5sum "$R/etc/platform/cloudflared.token" "$R/etc/platform/cloudflared.webhook")"
ins install
expect_rc "a fresh install succeeds" 0
expect_eq "the placed compose is byte-identical to the tracked source" "$(cmp -s "$R/opt/platform/cloudflared/compose.yaml" "$repo_compose" && echo same)" "same"
expect_eq "blue state dir mode" "$(/usr/bin/stat -c %a "$R/var/lib/cloudflared-supervisor-blue")" "755"
expect_eq "green state dir mode" "$(/usr/bin/stat -c %a "$R/var/lib/cloudflared-supervisor-green")" "755"
expect_eq "compose mode" "$(/usr/bin/stat -c %a "$R/opt/platform/cloudflared/compose.yaml")" "644"
expect_out_has "install ends with the manual start command" "not started: start a colour by hand with docker compose -p platform-cloudflared -f /opt/platform/cloudflared/compose.yaml up -d cloudflared-blue"
expect_out_has "install reports changes" "changed: $R/opt/platform/cloudflared/compose.yaml"
no_docker_calls "a fresh install makes no docker call"
expect_calls_has "blue state dir is chowned to the container user" "chown 65532:65532 $R/var/lib/cloudflared-supervisor-blue"
expect_calls_has "green state dir is chowned to the container user" "chown 65532:65532 $R/var/lib/cloudflared-supervisor-green"
expect_calls_has "the install dir is chowned to root" "chown root:root $R/opt/platform/cloudflared"
expect_calls_has "the compose is chowned to root" "chown root:root $R/opt/platform/cloudflared/compose.yaml.new"
if grep -E '^(fakesudo )?(cp|mv|chmod|chown|tee|install|rm|touch|ln) ' "$CALL_LOG" | grep -qE 'cloudflared\.(token|webhook)'; then _fail "no mutating command names a secret file"; else _pass; fi
forbid "a fresh install"
expect_out_lacks "the token never appears in output" "$TOKEN"
expect_out_lacks "the webhook never appears in output" "$WEBHOOK"
expect_calls_lacks "the token never appears in the call log" "$TOKEN"
expect_calls_lacks "the webhook never appears in the call log" "$WEBHOOK"
expect_eq "neither secret file was rewritten" "$(md5sum "$R/etc/platform/cloudflared.token" "$R/etc/platform/cloudflared.webhook")" "$before"

t_reset_calls
ins install
expect_rc "a second install succeeds" 0
expect_out_lacks "a second install changes nothing" "changed:"
expect_eq "a second install prints only already: lines plus the closing line" "$(grep -vc -E '^(already:|not started:)' <<<"$out")" "0"
expect_out_has "a second install still prints the closing line" "not started:"
no_docker_calls "a second install makes no docker call"

# install repairs drift: a changed compose, a wrong mode, a wrong owner, a wrong install-dir mode
installed
echo "# drift" >> "$R/opt/platform/cloudflared/compose.yaml"
chmod 600 "$R/opt/platform/cloudflared/compose.yaml"
ins install
expect_rc "install repairs a drifted compose" 0
expect_out_has "repair of the compose is reported" "changed: $R/opt/platform/cloudflared/compose.yaml"
expect_eq "the repaired compose is byte-identical to the tracked source" "$(cmp -s "$R/opt/platform/cloudflared/compose.yaml" "$repo_compose" && echo same)" "same"
expect_eq "the repaired compose mode is 644" "$(/usr/bin/stat -c %a "$R/opt/platform/cloudflared/compose.yaml")" "644"

installed
chmod 700 "$R/opt/platform/cloudflared"
ins install
expect_rc "install repairs the install directory mode" 0
expect_out_has "repair of the install directory is reported" "changed: $R/opt/platform/cloudflared/"
expect_eq "the repaired install directory mode is 755" "$(/usr/bin/stat -c %a "$R/opt/platform/cloudflared")" "755"

installed
echo "compose.yaml 1000:1000" > "$STATE/stat_override"
ins install
expect_rc "install repairs a wrong compose owner" 0
expect_out_has "repair of the compose owner is reported" "changed: $R/opt/platform/cloudflared/compose.yaml"
expect_calls_has "the repair chowns the compose to root" "chown root:root $R/opt/platform/cloudflared/compose.yaml.new"
rm -f "$STATE/stat_override"
ins install
expect_out_lacks "a later install is a no-op once the owner is right" "changed:"

# the default subcommand is status
ins
expect_rc "no argument runs status" 0
expect_out_has "status is the default" "all checks passed"

# ---- bad inputs: rc 1, the instruction text, nothing written, no docker call ----

precond() { # label, setup function, expected fragment
  fresh
  "$2"
  local snap
  snap="$(find "$R" -printf '%p %y %m\n' | sort)"
  ins install
  expect_eq "precondition changes nothing under the root: $1" "$(find "$R" -printf '%p %y %m\n' | sort)" "$snap"
  expect_rc "precondition: $1" 1
  expect_out_has "precondition message: $1" "$3"
  expect_out_has "instruction text: $1" "sudo groupadd --gid 64321 cloudflared-token"
  expect_out_has "instruction text creates /etc/platform: $1" "sudo install -d -m 0755 -o root -g root /etc/platform"
  expect_out_has "instruction text creates the token file: $1" "sudo install -m 0640 -o root -g 64321 /dev/null /etc/platform/cloudflared.token"
  expect_out_has "instruction text creates the webhook file: $1" "sudo install -m 0600 -o 65532 -g 65532 /dev/null /etc/platform/cloudflared.webhook"
  expect_out_lacks "never shows the token: $1" "$TOKEN"
  expect_out_lacks "never shows the webhook: $1" "$WEBHOOK"
  no_docker_calls "no docker call: $1"
  nothing_placed "$1"
}
c_tok_missing() { rm "$R/etc/platform/cloudflared.token"; }
c_tok_empty() { : > "$R/etc/platform/cloudflared.token"; }
c_tok_blank() { printf ' \t\n\n' > "$R/etc/platform/cloudflared.token"; }
c_tok_symlink() { mv "$R/etc/platform/cloudflared.token" "$R/etc/platform/real.token"; ln -s real.token "$R/etc/platform/cloudflared.token"; }
c_tok_dir() { rm "$R/etc/platform/cloudflared.token"; mkdir "$R/etc/platform/cloudflared.token"; }
c_tok_owner() { echo "cloudflared.token 1000:64321" > "$STATE/stat_override"; }
c_tok_group() { echo "cloudflared.token 0:0" > "$STATE/stat_override"; }
c_tok_mode() { chmod 600 "$R/etc/platform/cloudflared.token"; }
c_wh_missing() { rm "$R/etc/platform/cloudflared.webhook"; }
c_wh_empty() { : > "$R/etc/platform/cloudflared.webhook"; }
c_wh_symlink() { mv "$R/etc/platform/cloudflared.webhook" "$R/etc/platform/real.webhook"; ln -s real.webhook "$R/etc/platform/cloudflared.webhook"; }
c_wh_dir() { rm "$R/etc/platform/cloudflared.webhook"; mkdir "$R/etc/platform/cloudflared.webhook"; }
c_wh_owner() { echo "cloudflared.webhook 0:0" > "$STATE/stat_override"; }
c_wh_mode() { chmod 640 "$R/etc/platform/cloudflared.webhook"; }
c_grp_absent() { touch "$STATE/group_absent"; }
c_grp_member() { echo "claude" > "$STATE/group_members"; }
c_grp_primary() { echo 'svc:x:1100:64321::/home/svc:/bin/false' >> "$STATE/passwd"; }
c_grp_docker() { echo 64321 > "$STATE/docker_gid"; }
c_grp_dup_member() { printf '%s\n' 'cftoken:x:64321:' 'other:x:64321:bob' > "$STATE/group_all"; }
c_grp_dup() { printf '%s\n' 'cftoken:x:64321:' 'other:x:64321:' > "$STATE/group_all"; }
c_acct_unlistable() { rm -f "$STATE/passwd"; }
c_sock_absent() { rm "$T_TMP/dsock"; }
c_opt_symlink() { mkdir -p "$R/real_opt" "$R/opt"; ln -s ../real_opt "$R/opt/platform"; }
c_inst_symlink() { mkdir -p "$R/real_inst" "$R/opt/platform"; ln -s ../../real_inst "$R/opt/platform/cloudflared"; }
c_var_symlink() { mkdir -p "$R/real_var" "$R/var"; ln -s ../real_var "$R/var/lib"; }
c_state_symlink() { mkdir -p "$R/real_state" "$R/var/lib"; ln -s ../../real_state "$R/var/lib/cloudflared-supervisor-green"; }

precond "token missing" c_tok_missing "token file missing"
precond "token empty" c_tok_empty "token file is empty"
precond "token whitespace-only" c_tok_blank "no non-blank content"
precond "token symlink" c_tok_symlink "token file is a symlink"
precond "token directory" c_tok_dir "not a regular file"
precond "token wrong owner" c_tok_owner "token file uid:gid/mode"
precond "token wrong group" c_tok_group "token file uid:gid/mode"
precond "token wrong mode" c_tok_mode "token file uid:gid/mode"
precond "webhook missing" c_wh_missing "webhook file missing"
precond "webhook empty" c_wh_empty "webhook file is empty"
precond "webhook symlink" c_wh_symlink "webhook file is a symlink"
precond "webhook directory" c_wh_dir "not a regular file"
precond "webhook wrong owner" c_wh_owner "webhook file uid:gid/mode"
precond "webhook wrong mode" c_wh_mode "webhook file uid:gid/mode"
precond "token group missing" c_grp_absent "no group with gid 64321"
precond "token group has members" c_grp_member "has members"
precond "token group is a primary group" c_grp_primary "is an account's primary group"
precond "token group is the Docker socket's group" c_grp_docker "Docker socket's group"
precond "token group second entry has members" c_grp_dup_member "a group entry with gid 64321 has members"
precond "token group gid duplicated" c_grp_dup "more than one group entry carries gid 64321"
precond "accounts cannot be listed" c_acct_unlistable "cannot list accounts"
precond "Docker socket absent" c_sock_absent "Docker must be installed first"
precond "symlinked /opt/platform" c_opt_symlink "path is a symlink: /opt/platform"
precond "symlinked install directory" c_inst_symlink "path is a symlink: /opt/platform/cloudflared"
precond "symlinked /var/lib" c_var_symlink "path is a symlink: /var/lib"
precond "symlinked state directory" c_state_symlink "path is a symlink: /var/lib/cloudflared-supervisor-green"
expect_eq "a symlinked state directory's target stays empty" "$(find "$R/real_state" | wc -l)" "1"

# the webhook-copy instruction is stated
fresh
c_wh_missing
ins install
expect_out_has "the instructions say the webhook is the Pi's" "a copy of the same webhook the Pi uses"
expect_out_has "the instructions say how it moves" "over a trusted channel"

# the token file is never rewritten by a refused run either
fresh
c_wh_missing
before="$(md5sum "$R/etc/platform/cloudflared.token")"
ins install
expect_eq "a refused install leaves the token alone" "$(md5sum "$R/etc/platform/cloudflared.token")" "$before"

# ---- status / verify ----

installed
ins status
expect_rc "status passes on a clean install" 0
expect_out_has "status says all checks passed" "all checks passed"
expect_out_has "status reports the logging driver" "docker default logging driver: journald"
expect_out_has "status reports no colour running" "no platform-cloudflared colour is running"
expect_calls_lacks "status does not run compose config" "config -q"
forbid "status"
ins verify
expect_rc "verify passes on a clean install" 0
expect_calls_has "verify runs compose config -q on the placed file" "compose -p platform-cloudflared -f $R/opt/platform/cloudflared/compose.yaml config -q"
forbid "verify"
expect_out_lacks "verify never shows the token" "$TOKEN"
expect_out_lacks "verify never shows the webhook" "$WEBHOOK"

# a running connector of the project, and the systemd unit untouched
installed
echo 500 > "$STATE/running_cloudflared-blue"
ins status
expect_rc "status passes with a colour running" 0
expect_out_has "status names the running colour" "containers running: cloudflared-blue"
forbid "status with a running colour"
ins verify
expect_rc "verify passes with a colour running" 0
forbid "verify with a running colour"

vcase() { # label, setup, expected fragment; checks status and verify
  local sub
  for sub in status verify; do
    installed
    "$2"
    ins "$sub"
    expect_rc "$sub fails: $1" 1
    expect_out_has "$sub names the failure: $1" "$3"
  done
}
v_tok_perm() { chmod 600 "$R/etc/platform/cloudflared.token"; }
v_wh_empty() { : > "$R/etc/platform/cloudflared.webhook"; }
v_drift() { echo "# drift" >> "$R/opt/platform/cloudflared/compose.yaml"; }
v_compose_missing() { rm "$R/opt/platform/cloudflared/compose.yaml"; }
v_sd_owner() { echo "cloudflared-supervisor-blue 0:0" > "$STATE/stat_override"; }
v_sd_missing() { rmdir "$R/var/lib/cloudflared-supervisor-green"; }
v_sd_symlink() { mv "$R/var/lib/cloudflared-supervisor-blue" "$R/var/lib/real-blue"; ln -s real-blue "$R/var/lib/cloudflared-supervisor-blue"; }
vcase "bad token" v_tok_perm "token file uid:gid/mode"
vcase "bad webhook" v_wh_empty "webhook file is empty"
vcase "compose drift" v_drift "differs from the embedded payload"
vcase "compose missing" v_compose_missing "compose file missing"
vcase "state dir owner" v_sd_owner "state directory /var/lib/cloudflared-supervisor-blue"
vcase "state dir missing" v_sd_missing "state directory missing"
vcase "state dir symlink" v_sd_symlink "state directory is a symlink"
vcase "token group is the socket's group" c_grp_docker "Docker socket's group"

# an invalid placed compose fails verify only
installed
touch "$STATE/compose_config_fail"
ins verify
expect_rc "verify fails on an invalid placed file" 1
expect_out_has "verify names the config failure" "compose config -q failed"
ins status
expect_rc "status ignores compose config" 0

# logging driver is reported and never fails
installed
echo "json-file" > "$STATE/logdriver"
ins status
expect_rc "a json-file driver does not fail status" 0
expect_out_has "the driver is printed" "docker default logging driver: json-file"
ins verify
expect_rc "a json-file driver does not fail verify" 0

# compose plugin missing: verify fails, status reports
installed
touch "$STATE/compose_version_fail"
ins verify
expect_rc "verify fails without the compose plugin" 1
expect_out_has "verify names the missing plugin" "docker compose plugin missing"
expect_calls_lacks "verify runs no compose config without the plugin" "config -q"
ins status
expect_rc "status does not fail without the compose plugin" 0
expect_out_has "status reports the missing plugin" "docker compose plugin missing"

# Docker state (1a): socket absent
installed
rm "$T_TMP/dsock"
ins status
expect_rc "status passes with the socket absent" 0
expect_out_has "status reports docker unavailable (socket absent)" "docker: unavailable"
expect_out_has "status notes the skipped socket-group check" "does not exist"
ins verify
expect_rc "verify fails with the socket absent" 1
expect_out_has "verify names the cause (socket absent)" "cannot be verified"
no_docker_calls "no docker call with the socket absent"

# Docker state (1b): CLI missing (socket present, even when it carries the token gid: the sub-check is skipped)
installed
echo 64321 > "$STATE/docker_gid"
export INSTALL_CLOUDFLARED_DOCKER=no-such-docker-cli
ins status
expect_rc "status passes with the CLI missing" 0
expect_out_has "status reports docker unavailable (CLI missing)" "docker: unavailable"
expect_out_has "status notes the CLI problem" "docker CLI is not installed"
ins verify
expect_rc "verify fails with the CLI missing" 1
expect_out_has "verify names the cause (CLI missing)" "cannot be verified"
unset INSTALL_CLOUDFLARED_DOCKER

# Docker state (2): socket present, daemon unreachable
installed
touch "$STATE/info_fail"
ins status
expect_rc "status passes with the daemon unreachable" 0
expect_out_has "status reports container state unavailable" "docker: unavailable (container state)"
expect_out_has "status reports the logging driver unavailable" "docker: unavailable (logging driver)"
ins verify
expect_out_has "verify reports container state unavailable" "docker: unavailable (container state)"
expect_out_has "verify reports the logging driver unavailable" "docker: unavailable (logging driver)"
expect_rc "verify passes with the daemon unreachable" 0
expect_out_has "verify skips the compose config" "compose config: skipped (docker: unavailable)"
expect_calls_lacks "verify ran no compose config" "config -q"

# inspect/ps failing is reported, not failed
installed
touch "$STATE/ps_fail"
ins status
expect_rc "status passes when docker ps fails" 0
expect_out_has "status notes the unreadable container state" "cannot read the state"

installed
echo 500 > "$STATE/running_cloudflared-blue"
touch "$STATE/inspect_fail"
printf 'LISTEN 0 4096 %s:20251 0.0.0.0:* users:(("cloudflared",pid=500,fd=3))\n' "$LOOP" > "$STATE/ss_out"
ins status
expect_rc "status passes when docker inspect fails" 0
expect_out_has "status notes the unreadable container state after an inspect failure" "cannot read the state"
expect_out_has "listeners are owner unknown after an inspect failure" "owner unknown"

# an existing state dir is repaired, its content kept
fresh
mkdir -p "$R/var/lib/cloudflared-supervisor-blue"
chmod 700 "$R/var/lib/cloudflared-supervisor-blue"
echo keep > "$R/var/lib/cloudflared-supervisor-blue/data"
ins install
expect_rc "install repairs an existing state dir" 0
expect_out_has "the repaired state dir is reported changed" "changed: $R/var/lib/cloudflared-supervisor-blue/"
expect_eq "the repaired state dir mode" "$(/usr/bin/stat -c %a "$R/var/lib/cloudflared-supervisor-blue")" "755"
expect_eq "the state dir content survives" "$(cat "$R/var/lib/cloudflared-supervisor-blue/data")" "keep"

# ---- listeners on 127.0.0.1:20251-20254 ----

ssline() { # port pid
  printf 'LISTEN 0 4096 %s:%s 0.0.0.0:* users:(("cloudflared",pid=%s,fd=3))\n' "$LOOP" "$1" "$2"
}
listener_case() { # label, expect-warning(yes|no), setup function
  local sub
  for sub in status verify; do
    installed
    "$3"
    ins "$sub"
    expect_rc "$sub with listeners passes: $1" 0
    if [ "$2" = "yes" ]; then expect_out_has "$sub warns: $1" "warning: port"; else expect_out_lacks "$sub does not warn: $1" "warning:"; fi
  done
}
l_none() { : > "$STATE/ss_out"; }
l_other_port() { ssline 8080 900 > "$STATE/ss_out"; }
l_own() { echo 500 > "$STATE/running_cloudflared-blue"; ssline 20251 500 > "$STATE/ss_out"; }
l_grandchild() { echo 500 > "$STATE/running_cloudflared-blue"; ssline 20252 700 > "$STATE/ss_out"; echo 600 > "$STATE/ppid_700"; echo 500 > "$STATE/ppid_600"; }
l_foreign() { echo 500 > "$STATE/running_cloudflared-blue"; ssline 20251 900 > "$STATE/ss_out"; echo 800 > "$STATE/ppid_900"; echo 1 > "$STATE/ppid_800"; }
l_no_container() { ssline 20253 900 > "$STATE/ss_out"; echo 1 > "$STATE/ppid_900"; }
l_both() { echo 500 > "$STATE/running_cloudflared-blue"; echo 510 > "$STATE/running_cloudflared-green"; ssline 20251 500 > "$STATE/ss_out"; ssline 20254 511 >> "$STATE/ss_out"; echo 510 > "$STATE/ppid_511"; }
l_unreachable() { touch "$STATE/info_fail"; ssline 20251 500 > "$STATE/ss_out"; }
l_socket_absent() { rm "$T_TMP/dsock"; ssline 20251 500 > "$STATE/ss_out"; }
listener_case "no listener" no l_none
listener_case "a listener on another port" no l_other_port
listener_case "the container's own listener" no l_own
listener_case "a grandchild of the container pid" no l_grandchild
listener_case "a foreign chain" yes l_foreign
listener_case "a listener with no container running" yes l_no_container
listener_case "both colours running, either counts" no l_both
l_wildcard() { printf 'LISTEN 0 4096 0.0.0.0:20251 0.0.0.0:* users:(("cloudflared",pid=900,fd=3))\n' > "$STATE/ss_out"; echo 1 > "$STATE/ppid_900"; }
listener_case "a wildcard bind on a watched port (reported or ignored, never a failure)" no l_wildcard

# ss itself failing is a note, never a failure
installed
touch "$STATE/ss_fail"
ins status
expect_rc "status passes when ss fails" 0
expect_out_has "status notes the ss failure" "note: ss failed"
ins verify
expect_rc "verify passes when ss fails" 0
expect_out_has "verify notes the ss failure" "note: ss failed"

# ss missing from PATH is a note, never a failure
installed
noss="$T_TMP/noss"
rm -rf "$noss"
mkdir -p "$noss"
saved_path="$PATH"
IFS=: read -r -a path_dirs <<<"$PATH"
for d in "${path_dirs[@]}"; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="${f##*/}"
    [ "$b" != "ss" ] || continue
    [ -e "$noss/$b" ] || ln -s "$f" "$noss/$b" 2>/dev/null || true
  done
done
PATH="$noss"
export PATH
ins status
PATH="$saved_path"
export PATH
expect_rc "status passes when ss is not installed" 0
expect_out_has "status notes that ss is missing" "note: ss not found"

installed
l_unreachable
ins status
expect_rc "status passes with listeners and the daemon unreachable" 0
expect_out_has "every listener is warned as owner unknown" "owner unknown"
ins verify
expect_rc "verify passes with listeners and the daemon unreachable" 0
expect_out_has "verify warns owner unknown with the daemon unreachable" "owner unknown"
installed
l_socket_absent
ins status
expect_rc "status passes with listeners and the socket absent" 0
expect_out_has "listeners are warned as owner unknown with the socket absent" "owner unknown"

# ---- the systemd unit and a running connector never matter ----

installed
echo 500 > "$STATE/running_cloudflared-blue"
echo 510 > "$STATE/running_cloudflared-green"
for sub in install status verify; do
  t_reset_calls
  ins "$sub"
  expect_rc "$sub with both colours running" 0
  forbid "$sub with both colours running"
done

t_finish
