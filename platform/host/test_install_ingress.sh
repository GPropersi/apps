#!/usr/bin/env bash
# Stub tests for install-ingress.sh. Every host file lands under INSTALL_INGRESS_ROOT, the privilege prefix is a logging
# fakesudo, and docker/stat/getent/chown/ssh are stateful stubs on PATH (stat reports root ownership and the token gid
# unless a test overrides it; modes are real). No docker, firewall or network is touched.
#
# FIXTURES FLAGGED UNVERIFIED: the shapes of the stubbed `docker compose ps --format`, `docker port`, `docker inspect`
# (labels, mounts, networks, Env/Cmd), `docker network inspect` and `getent` output are reconstructed from the formats
# documented for those commands, not captured from a live host. After the first live run, replace them with sanitized
# real captures (follow-up listed in the plan); the mutation cases stay.
#
# No address literals and no real token: the fixture token below is a fake string. The hygiene check flags literals.
# SC2016: stub bodies and payload checks are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# SC2154: $out and $rc are set by run_cmd in lib.sh.
# shellcheck disable=SC1091,SC2016,SC2034,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/install-ingress.sh"
ingress_src="$here/../ingress"

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

# stat: real mode; owner root:root, except the token file (root:64321). A test lists "<basename> <uid:gid>" lines in
# $STATE/stat_override to change an owner. %g on the socket reports $STATE/docker_gid.
mkstub stat <<'EOF'
fmt="$2"
path="${@: -1}"
base="$(basename "$path")"
if [ ! -e "$path" ] && [ ! -L "$path" ]; then exit 1; fi
ug="0:0"
[ "$base" != "cloudflared.token" ] || ug="0:64321"
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

# getent group 64321 / getent passwd: state files group_absent, group_members, passwd.
mkstub getent <<'EOF'
case "$1" in
  group)
    if [ "${2:-}" = "64321" ] && [ ! -f "$STATE/group_absent" ]; then
      echo "cftoken:x:64321:$(cat "$STATE/group_members" 2>/dev/null)"
      exit 0
    fi
    if [ -z "${2:-}" ] && [ -f "$STATE/group_dup" ]; then
      echo "cftoken:x:64321:"
      echo "other:x:64321:claude"
      exit 0
    fi
    exit 2 ;;
  passwd) cat "$STATE/passwd" 2>/dev/null; exit 0 ;;
esac
exit 2
EOF

mkstub ssh <<'EOF'
cat > "$STATE/ssh_stdin"
exit 0
EOF

# docker: stateful. Install side: network ls/inspect/create, compose up/ps, port, inspect, exec nslookup.
# Live side: run/ps/exec (a curl that behaves like Traefik for the fixture hosts)/stop/start/logs/rm.
# Mutation switches are files in $STATE (see the live tests).
mkstub docker <<'EOF'
S="$STATE"
sub="$1"
shift
friendly='<h1>This app is down or does not exist</h1>'
case "$sub" in
  network)
    case "$1" in
      ls) [ ! -f "$S/net_ls_fail" ] || exit 1; [ ! -f "$S/network_exists" ] || echo platform; exit 0 ;;
      inspect) [ -f "$S/network_exists" ] || exit 1; cat "$S/network_desc" 2>/dev/null || echo "bridge false"; exit 0 ;;
      create) touch "$S/network_exists"; echo netid; exit 0 ;;
    esac
    exit 0 ;;
  compose)
    for a in "$@"; do
      case "$a" in
        up) [ ! -f "$S/up_fail" ] || exit 1; touch "$S/stack_up"; exit 0 ;;
        ps) [ ! -f "$S/ps_fail" ] || exit 1; [ -f "$S/stack_up" ] || exit 0; cat "$S/ps"; exit 0 ;;
      esac
    done
    exit 0 ;;
  port) cat "$S/port_$1" 2>/dev/null; exit 0 ;;
  inspect)
    fmt="$2"
    name="$3"
    [ ! -f "$S/inspect_fail_$name" ] || exit 1
    case "$fmt" in
      *Labels*) cat "$S/labels_$name" 2>/dev/null ;;
      *Mounts*) cat "$S/mounts_$name" 2>/dev/null ;;
      *Networks*) cat "$S/networks_$name" 2>/dev/null ;;
      *Config.Env*) cat "$S/envcmd_$name" 2>/dev/null ;;
    esac
    exit 0 ;;
  run)
    name=""
    while [ $# -gt 0 ]; do
      case "$1" in --name) name="$2"; shift 2 ;; *) shift ;; esac
    done
    [ ! -f "$S/run_fail_$name" ] || exit 1
    touch "$S/created_$name"
    case "$name" in
      ingress-livetest) echo aaaaaaaaaaaa ;;
      ingress-livetest-sibling) echo bbbbbbbbbbbb ;;
      *) echo cccccccccccc ;;
    esac
    exit 0 ;;
  ps)
    all="$*"
    case "$all" in
      *label=platform.app=ingress-livetest*) cat "$S/live_existing_label" 2>/dev/null ;;
      *name=ingress-livetest*) cat "$S/live_existing_name" 2>/dev/null ;;
      *com.docker.compose.service=traefik*) echo dddddddddddd ;;
    esac
    exit 0 ;;
  stop) touch "$S/stopped"; exit 0 ;;
  start) rm -f "$S/stopped" "$S/killed"; exit 0 ;;
  rm)
    for a in "$@"; do [ "$a" = "-f" ] || echo "$a" >> "$S/removed_ids"; done
    [ ! -f "$S/rm_fail" ] || exit 1
    rm -f "$S"/created_*
    exit 0 ;;
  logs)
    case "$1" in
      dddddddddddd)
        n="$(cat "$S/tlog_calls" 2>/dev/null || echo 0)"
        n=$((n + 1))
        echo "$n" > "$S/tlog_calls"
        cat "$S/traefik_log_pre" 2>/dev/null
        if [ "$n" -ge 2 ]; then cat "$S/traefik_log_post" 2>/dev/null; fi ;;
      *) cat "$S/log_$1" 2>/dev/null ;;
    esac
    exit 0 ;;
  exec)
    name="$1"
    shift
    case "$name" in
      ingress-livetest)
        # the listener kill
        [ ! -f "$S/kill_fail" ] || exit 1
        touch "$S/killed"
        exit 0 ;;
      ingress-livetest-curl)
        shift # curl
        if [ -f "$S/kill_on_exec" ]; then
          n="$(cat "$S/exec_calls" 2>/dev/null || echo 0)"
          n=$((n + 1))
          echo "$n" > "$S/exec_calls"
          if [ "$n" -eq "$(cat "$S/kill_on_exec")" ]; then kill -TERM "$(cat "$S/installer_pid")"; exit 0; fi
        fi
        host=""
        fmt=""
        while [ $# -gt 1 ]; do
          case "$1" in
            -H) host="${2#Host: }"; shift 2 ;;
            -w) fmt=1; shift 2 ;;
            *) shift ;;
          esac
        done
        url="$1"
        rest="${url#http://}"
        hostport="${rest%%/*}"
        path="/${rest#*/}"
        port="${hostport##*:}"
        if [ "$port" != "80" ]; then exit "$(cat "$S/ping_rc" 2>/dev/null || echo 7)"; fi
        respond() { # code body
          printf '%s\n%s' "$2" "$1"
          exit 0
        }
        lower="$(printf '%s' "$path" | tr 'A-Z' 'a-z')"
        app_host="ingress-livetest.example.test"
        sib_host="ingress-livetest-sibling.example.test"
        if [ "$host" = "$app_host" ] && [ -f "$S/created_ingress-livetest" ]; then
          if [ -f "$S/stopped" ]; then
            if [ -f "$S/stop_502" ]; then respond 502 "$friendly"; fi
            respond 503 "$friendly"
          fi
          [ ! -f "$S/app_unrouted" ] || respond 404 "not found"
          case "$lower" in
            *jobs*)
              if [ -f "$S/jobs_leak" ]; then echo "url:$path" >> "$S/log_ingress-livetest"; respond 200 ok; fi
              ov="$(grep -F -- "$path " "$S/variant_override" 2>/dev/null | head -n1 || true)"
              if [ -n "$ov" ]; then
                code="${ov##* }"
                if [ "$code" = "503" ]; then respond 503 "$friendly"; fi
                respond "$code" "plain"
              fi
              case "$path" in
                /_jobs%*) respond 400 "Bad Request" ;;
              esac
              respond 503 "$friendly" ;;
          esac
          if [ -f "$S/killed" ] && [ ! -f "$S/kill_ineffective" ]; then
            if [ -f "$S/killed_503" ]; then respond 503 "$friendly"; fi
            respond 502 "$friendly"
          fi
          [ -f "$S/no_app_log" ] || echo "url:$path" >> "$S/log_ingress-livetest"
          respond 200 ok
        fi
        if [ "$host" = "$sib_host" ]; then
          if [ -f "$S/sibling_routed" ]; then echo "url:$path" >> "$S/log_ingress-livetest-sibling"; respond 200 ok; fi
          respond 503 "$friendly"
        fi
        if [ -f "$S/unmatched_200" ]; then respond 200 ok; fi
        if [ -f "$S/no_friendly" ]; then respond 503 ""; fi
        respond 503 "$friendly" ;;
      *)
        # container DNS check
        exit "$(cat "$S/dns_rc" 2>/dev/null || echo 0)" ;;
    esac ;;
esac
exit 0
EOF

# ---- fixtures ----

TOKEN='FIXTURE-TUNNEL-TOKEN-NOT-A-REAL-SECRET-0123456789'
NAMES=(platform-ingress-cloudflared-1 platform-ingress-traefik-1 platform-ingress-socket-proxy-1 platform-ingress-down-page-1)
CF=platform-ingress-cloudflared-1
TR=platform-ingress-traefik-1
SP=platform-ingress-socket-proxy-1
DP=platform-ingress-down-page-1
PROBE_IP="$(t_ip4 203 0 113 7)"

# fresh: a clean root and clean state for the next scenario, all inputs valid.
fresh() {
  rm -rf "$T_TMP/root" "$STATE" "$T_TMP/dsock"
  mkdir -p "$T_TMP/root/etc/platform" "$STATE"
  t_reset_calls
  R="$T_TMP/root"
  printf '%s\n' "$TOKEN" > "$R/etc/platform/cloudflared.token"
  chmod 640 "$R/etc/platform/cloudflared.token"
  printf '# comment\nPLATFORM_DOMAIN=example.test\n' > "$R/etc/platform/ingress.env"
  chmod 644 "$R/etc/platform/ingress.env"
  : > "$T_TMP/dsock"
  echo 998 > "$STATE/docker_gid"
  printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'admin:x:1000:1000::/home/admin:/bin/bash' 'claude:x:1002:1002::/home/claude:/usr/local/bin/claude-access' > "$STATE/passwd"
  printf '%s|cloudflared|running|healthy\n%s|traefik|running|healthy\n%s|socket-proxy|running|healthy\n%s|down-page|running|healthy\n' "$CF" "$TR" "$SP" "$DP" > "$STATE/ps"
  local n
  for n in "${NAMES[@]}"; do
    printf 'com.docker.compose.project\ncom.docker.compose.service\n' > "$STATE/labels_$n"
    printf '/opt/platform/ingress/dynamic\n' > "$STATE/mounts_$n"
    printf 'platform\n' > "$STATE/networks_$n"
  done
  printf '/var/run/docker.sock\n' > "$STATE/mounts_$SP"
  printf 'ingress-proxy\n' > "$STATE/networks_$SP"
  printf 'platform\ningress-proxy\n' > "$STATE/networks_$TR"
  printf '["TUNNEL_TOKEN_FILE=/run/cloudflared/token"] ["tunnel","--no-autoupdate","run"]\n' > "$STATE/envcmd_$CF"
  export INSTALL_INGRESS_ROOT="$R"
  export INSTALL_INGRESS_SUDO=fakesudo
  export INSTALL_INGRESS_SOCKET="$T_TMP/dsock"
  export INSTALL_INGRESS_HEALTH_TIMEOUT=2
  export INSTALL_INGRESS_POLL=0.1
  export INSTALL_INGRESS_LIVE_SLEEP=0
  unset INSTALL_INGRESS_LIVE_LOCAL INSTALL_INGRESS_HOLD_TTY INSTALL_INGRESS_HOLD_TIMEOUT
}

ins() { run_cmd "$script" "$@"; }

no_docker_calls() { # label: no docker command ran, with or without privilege
  if grep -qE '^(fakesudo )?docker ' "$CALL_LOG"; then _fail "$1" "a docker command ran: $(grep -E '^(fakesudo )?docker ' "$CALL_LOG" | head -n1)"; else _pass; fi
}

REPO_COMPOSE="$ingress_src/compose.yaml"
REPO_DYNAMIC="$ingress_src/dynamic.yml"
REPO_INDEX="$ingress_src/down-page/index.html"
INST="/opt/platform/ingress"

# ---- usage ----

fresh
ins bogus
expect_rc "unknown argument is a usage error" 2
ins status --hold
expect_rc "--hold without --live is a usage error" 2
ins install --live
expect_rc "--live with install is a usage error" 2
ins verify --live
expect_rc "--live without --host is a usage error" 2
ins status --host -oProxyCommand=x
expect_rc "an option-looking --host is refused" 2
ins --help
expect_rc "--help succeeds" 0
expect_out_has "--help shows the usage" "Usage: install-ingress.sh"
expect_out_lacks "--help stops before the code" "set -euo"

# streaming: the script itself goes over one ssh call
fresh
ins install --host alias
expect_rc "streaming install" 0
expect_calls_has "streams with bash -s" "ssh -o BatchMode=yes -- alias bash -s -- install"
expect_eq "streams this very script" "$(cmp -s "$STATE/ssh_stdin" "$script" && echo same)" "same"

# no usable privilege
fresh
INSTALL_INGRESS_SUDO=nosudo ins install
expect_rc "install without privilege" 1
expect_out_has "names the missing privilege" "no usable privilege"
no_docker_calls "no privilege: no docker command"

# ---- precondition failures: rc 1, a message naming the cause, no secret, no docker command ----

precond() { # label, setup function, expected message
  fresh
  "$2"
  ins install
  expect_rc "precondition: $1" 1
  expect_out_has "precondition message: $1" "$3"
  expect_out_lacks "precondition output never shows the token: $1" "$TOKEN"
  no_docker_calls "precondition runs no docker command: $1"
  expect_eq "precondition installs nothing: $1" "$(find "$R/opt" 2>/dev/null | wc -l)" "0"
}
c_tok_missing() { rm "$R/etc/platform/cloudflared.token"; }
c_tok_empty() { : > "$R/etc/platform/cloudflared.token"; }
c_tok_blank() { printf ' \n\n' > "$R/etc/platform/cloudflared.token"; }
c_tok_owner() { echo "cloudflared.token 1000:64321" > "$STATE/stat_override"; }
c_tok_group() { echo "cloudflared.token 0:0" > "$STATE/stat_override"; }
c_tok_mode_0600() { chmod 600 "$R/etc/platform/cloudflared.token"; }
c_tok_mode_0644() { chmod 644 "$R/etc/platform/cloudflared.token"; }
c_tok_mode_0400() { chmod 400 "$R/etc/platform/cloudflared.token"; }
c_tok_mode_0660() { chmod 660 "$R/etc/platform/cloudflared.token"; }
c_tok_symlink() { mv "$R/etc/platform/cloudflared.token" "$R/etc/platform/real.token"; ln -s real.token "$R/etc/platform/cloudflared.token"; }
c_env_missing() { rm "$R/etc/platform/ingress.env"; }
c_env_gw() { chmod 664 "$R/etc/platform/ingress.env"; }
c_env_ww() { chmod 666 "$R/etc/platform/ingress.env"; }
c_env_owner() { echo "ingress.env 1000:0" > "$STATE/stat_override"; }
c_dom_missing() { printf '# nothing\n' > "$R/etc/platform/ingress.env"; }
c_dom_twice() { printf 'PLATFORM_DOMAIN=example.test\nPLATFORM_DOMAIN=other.test\n' > "$R/etc/platform/ingress.env"; }
c_dom_upper() { printf 'PLATFORM_DOMAIN=Example.Test\n' > "$R/etc/platform/ingress.env"; }
c_dom_single() { printf 'PLATFORM_DOMAIN=localhost\n' > "$R/etc/platform/ingress.env"; }
c_dom_under() { printf 'PLATFORM_DOMAIN=a_b.example.test\n' > "$R/etc/platform/ingress.env"; }
c_dom_quote() { printf 'PLATFORM_DOMAIN="example.test"\n' > "$R/etc/platform/ingress.env"; }
c_dom_dot() { printf 'PLATFORM_DOMAIN=example.test.\n' > "$R/etc/platform/ingress.env"; }
c_dom_space() { printf 'PLATFORM_DOMAIN=example.test \n' > "$R/etc/platform/ingress.env"; }
c_dom_empty() { printf 'PLATFORM_DOMAIN=\n' > "$R/etc/platform/ingress.env"; }
c_sock_missing() { rm "$T_TMP/dsock"; }
c_sock_root() { echo 0 > "$STATE/docker_gid"; }
c_grp_absent() { touch "$STATE/group_absent"; }
c_grp_member() { echo "claude" > "$STATE/group_members"; }
c_grp_primary() { echo 'svc:x:1100:64321::/home/svc:/bin/false' >> "$STATE/passwd"; }
c_grp_docker() { echo 64321 > "$STATE/docker_gid"; }
c_grp_noaccts() { : > "$STATE/passwd"; }
precond "token file missing" c_tok_missing "token file missing"
precond "token file empty" c_tok_empty "token file is empty"
precond "token file blank" c_tok_blank "no non-blank content"
precond "token file wrong owner" c_tok_owner "uid:gid/mode is '1000:64321 640'"
precond "token file wrong group" c_tok_group "uid:gid/mode is '0:0 640'"
precond "token file mode 0600" c_tok_mode_0600 "uid:gid/mode is '0:64321 600'"
precond "token file mode 0644" c_tok_mode_0644 "uid:gid/mode is '0:64321 644'"
precond "token file mode 0400" c_tok_mode_0400 "uid:gid/mode is '0:64321 400'"
precond "token file mode 0660" c_tok_mode_0660 "uid:gid/mode is '0:64321 660'"
precond "token file is a symlink" c_tok_symlink "token file is a symlink"
precond "env file missing" c_env_missing "ingress env file missing"
precond "env file group writable" c_env_gw "group or world writable"
precond "env file world writable" c_env_ww "group or world writable"
precond "env file not root owned" c_env_owner "not owned by root"
precond "domain missing" c_dom_missing "exactly one PLATFORM_DOMAIN="
precond "domain twice" c_dom_twice "exactly one PLATFORM_DOMAIN="
precond "domain uppercase" c_dom_upper "not a lowercase DNS name"
precond "domain single label" c_dom_single "not a lowercase DNS name"
precond "domain underscore" c_dom_under "not a lowercase DNS name"
precond "domain quoted" c_dom_quote "not a lowercase DNS name"
precond "domain trailing dot" c_dom_dot "not a lowercase DNS name"
precond "domain trailing space" c_dom_space "not a lowercase DNS name"
precond "domain empty" c_dom_empty "not a lowercase DNS name"
precond "docker socket missing" c_sock_missing "Docker socket missing"
precond "docker socket group is root" c_sock_root "Docker socket group is root"
precond "token group does not resolve" c_grp_absent "no group with gid 64321 exists"
precond "token group has a member" c_grp_member "has members"
precond "token gid is an account's primary gid" c_grp_primary "an account's primary group"
precond "token gid equals the docker gid" c_grp_docker "the Docker socket's group"
precond "accounts cannot be listed" c_grp_noaccts "cannot list accounts"
c_grp_dup() { touch "$STATE/group_dup"; }
precond "a second group entry shares the token gid" c_grp_dup "more than one group entry carries gid 64321"
fresh
rm "$R/etc/platform/cloudflared.token"
ins install
expect_out_has "missing token prints the exact chown instruction" "sudo chown root:64321 /etc/platform/cloudflared.token"
expect_out_has "missing token prints the chmod instruction" "sudo chmod 0640 /etc/platform/cloudflared.token"
expect_out_has "the instructions create the group at the fixed gid" "groupadd --gid 64321"
expect_out_has "the instructions explain the domain value" "PLATFORM_DOMAIN="
fresh
ins install
expect_calls_lacks "the installer never edits the group database" "groupadd"
expect_calls_lacks "the installer never edits accounts" "useradd"

# ---- install: happy path, exact argv ----

fresh
ins install
expect_rc "install on a clean host" 0
expect_out_has "install reports the placed compose file" "changed: $R$INST/compose.yaml"
expect_out_has "install reports done" "install-ingress: done"
expect_out_lacks "install never prints the token" "$TOKEN"
expect_eq "compose.yaml is the tracked source, byte for byte" "$(cmp -s "$R$INST/compose.yaml" "$REPO_COMPOSE" && echo same)" "same"
expect_eq "dynamic.yml lands in the mounted dynamic/ directory" "$(cmp -s "$R$INST/dynamic/dynamic.yml" "$REPO_DYNAMIC" && echo same)" "same"
expect_eq "index.html lands in down-page/" "$(cmp -s "$R$INST/down-page/index.html" "$REPO_INDEX" && echo same)" "same"
expect_eq "the derived gid file holds the socket group" "$(cat "$R$INST/docker-gid.env")" "DOCKER_GID=998"
expect_eq "compose.yaml mode" "$(stat -c %a "$R$INST/compose.yaml")" "644"
expect_calls_has "files are chowned to root" "chown root:root $R$INST/compose.yaml.new"
expect_calls_has "exact network create argv (bridge, IPv6 off)" "docker network create --driver bridge --ipv6=false platform"
expect_calls_has "exact compose up argv" "docker compose -p platform-ingress -f $R$INST/compose.yaml --env-file $R/etc/platform/ingress.env --env-file $R$INST/docker-gid.env up -d --remove-orphans"
expect_calls_has "container health is polled through compose ps" "ps --all --format"
for bad in iptables ip6tables nft ufw docker-user.rules firewall; do
  expect_calls_lacks "install never touches the firewall ($bad)" "$bad"
done
expect_calls_lacks "install does not touch /etc/group or accounts" "usermod"

# a second run changes nothing
t_reset_calls
ins install
expect_rc "second install" 0
expect_out_lacks "second install changes nothing" "changed:"
expect_out_has "second install: compose.yaml already" "already: $R$INST/compose.yaml"
expect_out_has "second install: dynamic.yml already" "already: $R$INST/dynamic/dynamic.yml"
expect_out_has "second install: index.html already" "already: $R$INST/down-page/index.html"
expect_out_has "second install: gid file already" "already: $R$INST/docker-gid.env"
expect_out_has "second install: network already" "already: network platform"
expect_calls_lacks "second install: no compose up" " up -d"
expect_calls_lacks "second install: no network create" "network create"
expect_calls_lacks "second install: no copy" "fakesudo cp"
expect_calls_lacks "second install: no move" "fakesudo mv"
expect_calls_lacks "second install: no stop, restart or removal" "docker rm"

# a changed socket group is rewritten, reported as changed, and the stack is brought up again
echo 999 > "$STATE/docker_gid"
t_reset_calls
ins install
expect_rc "install with a new socket group" 0
expect_out_has "stale gid reports changed" "changed: $R$INST/docker-gid.env"
expect_eq "stale gid rewritten" "$(cat "$R$INST/docker-gid.env")" "DOCKER_GID=999"
expect_calls_has "stale gid brings the stack up again" " up -d"

# a stack that is down is started even when no file changed
rm "$STATE/stack_up"
t_reset_calls
ins install
expect_calls_has "a stopped stack is started again" " up -d"

# network exists but wrong
wrong_net() {
  fresh
  touch "$STATE/network_exists"
  echo "$1" > "$STATE/network_desc"
  ins install
  expect_rc "network exists as '$1'" 1
  expect_out_has "wrong network names the cause: $1" "exists but is '$1'"
  expect_calls_lacks "wrong network is not recreated: $1" "network create"
  expect_calls_lacks "wrong network: the stack is not started: $1" " up -d"
}
wrong_net "bridge true"
wrong_net "overlay false"
wrong_net "macvlan false"
fresh
touch "$STATE/network_exists"
ins install
expect_rc "an existing correct network is reused" 0
expect_calls_lacks "an existing correct network is not recreated" "network create"
fresh
touch "$STATE/net_ls_fail"
ins install
expect_rc "docker network ls failing" 1
expect_out_has "docker network ls failure is named" "cannot list docker networks"
fresh
touch "$STATE/up_fail"
ins install
expect_rc "compose up failing" 1
expect_out_has "compose up failure is named" "docker compose up failed"

# bounded health wait
fresh
printf '%s|cloudflared|running|healthy\n%s|traefik|running|unhealthy\n%s|socket-proxy|running|healthy\n%s|down-page|running|healthy\n' "$CF" "$TR" "$SP" "$DP" > "$STATE/ps"
start=$SECONDS
INSTALL_INGRESS_HEALTH_TIMEOUT=1 ins install
elapsed=$((SECONDS - start))
expect_rc "stack never healthy" 1
expect_out_has "unhealthy container is named" "$TR is unhealthy"
expect_out_lacks "healthy containers are not named" "$CF is"
if [ "$elapsed" -le 8 ]; then _pass; else _fail "the health wait is bounded" "took ${elapsed}s with a 1s timeout"; fi
fresh
printf '%s|cloudflared|running|healthy\n%s|traefik|running|healthy\n%s|socket-proxy|running|starting\n' "$CF" "$TR" "$SP" > "$STATE/ps"
INSTALL_INGRESS_HEALTH_TIMEOUT=1 ins install
expect_rc "a missing container is not healthy" 1
expect_out_has "a missing container is named" "service down-page has no container"
expect_out_has "a starting container is named" "$SP is starting"

# ---- token gid constant equals the compose group_add ----

gid_mismatch() { # script path: prints MISMATCH lines when the two numbers differ
  local file="$1" const compose_gid
  const="$(sed -n 's/^readonly TOKEN_GID=\([0-9][0-9]*\)$/\1/p' "$file")"
  compose_gid="$(awk '/^payload_compose\(\)/ { on = 1 } on && /^  cloudflared:/ { cf = 1 } on && cf && /group_add:/ { ga = 1; next } on && cf && ga && /^ *- "[0-9]+"$/ { gsub(/[^0-9]/, ""); print; exit }' "$file")"
  if [ -z "$const" ] || [ -z "$compose_gid" ]; then echo "MISMATCH: cannot read the gid constant ($const) or the compose group_add ($compose_gid)"; return 0; fi
  [ "$const" = "$compose_gid" ] || echo "MISMATCH: TOKEN_GID=$const but compose group_add=$compose_gid"
}
expect_eq "the token gid constant equals the compose group_add gid" "$(gid_mismatch "$script")" ""
sed 's/^readonly TOKEN_GID=64321$/readonly TOKEN_GID=64322/' "$script" > "$T_TMP/mut-const.sh"
expect_out_has_text "$(gid_mismatch "$T_TMP/mut-const.sh")" "MISMATCH: TOKEN_GID=64322 but compose group_add=64321" "mutation: changing the constant fails the gid check"
sed 's/^      - "64321"$/      - "64399"/' "$script" > "$T_TMP/mut-compose.sh"
expect_out_has_text "$(gid_mismatch "$T_TMP/mut-compose.sh")" "MISMATCH: TOKEN_GID=64321 but compose group_add=64399" "mutation: changing the embedded compose group_add fails the gid check"
expect_eq "the tracked compose.yaml also carries the same group_add gid" "$(grep -c '^      - "64321"$' "$REPO_COMPOSE")" "1"

# ---- status / verify ----

installed() { fresh; ins install; t_reset_calls; }

installed
ins status
expect_rc "status after install" 0
expect_out_lacks "a clean status has no FAIL" "FAIL"
expect_out_has "a clean status says so" "all checks passed"
ins verify
expect_rc "verify after install" 0
expect_out_lacks "verify output never has the token" "$TOKEN"

# status never exits non-zero, verify exits 1 on each failing check, and the message names the cause
vcase() { # label, setup function, expected FAIL fragment
  installed
  "$2"
  ins status
  expect_rc "status stays rc 0: $1" 0
  expect_out_has "status shows the failure: $1" "$3"
  ins verify
  expect_rc "verify fails: $1" 1
  expect_out_has "verify names the cause: $1" "$3"
  expect_out_lacks "verify never prints the token: $1" "$TOKEN"
}
v_port() { echo "8080/tcp" > "$STATE/port_$TR"; }
v_sock_traefik() { printf '/var/run/docker.sock\n' > "$STATE/mounts_$TR"; }
v_sock_other() { printf '/var/run/docker.sock\n' > "$STATE/mounts_$DP"; }
v_sock_proxy_none() { printf '/etc/hosts\n' > "$STATE/mounts_$SP"; }
v_label() { printf 'platform.app\n' > "$STATE/labels_$DP"; }
v_unhealthy() { printf '%s|cloudflared|running|healthy\n%s|traefik|running|unhealthy\n%s|socket-proxy|running|healthy\n%s|down-page|running|healthy\n' "$CF" "$TR" "$SP" "$DP" > "$STATE/ps"; }
v_exited() { printf '%s|cloudflared|exited|\n%s|traefik|running|healthy\n%s|socket-proxy|running|healthy\n%s|down-page|running|healthy\n' "$CF" "$TR" "$SP" "$DP" > "$STATE/ps"; }
v_no_net() { rm "$STATE/network_exists"; }
v_net_v6() { echo "bridge true" > "$STATE/network_desc"; }
v_token_env() { printf '["TUNNEL_TOKEN=%s"] ["tunnel"]\n' "$TOKEN" > "$STATE/envcmd_$CF"; }
v_token_cmd() { printf '["A=b"] ["tunnel","--token","%s","run"]\n' "$TOKEN" > "$STATE/envcmd_$CF"; }
v_stale_gid() { echo 777 > "$STATE/docker_gid"; }
v_group_member() { echo "claude" > "$STATE/group_members"; }
v_traefik_net() { printf 'ingress-proxy\n' > "$STATE/networks_$TR"; }
v_dns() { echo 1 > "$STATE/dns_rc"; }
v_drift() { echo "# drift" >> "$R$INST/compose.yaml"; }
v_mode() { chmod 600 "$R$INST/dynamic/dynamic.yml"; }
v_missing_file() { rm "$R$INST/down-page/index.html"; }
v_gid_file() { rm "$R$INST/docker-gid.env"; }
v_ps_fail() { touch "$STATE/ps_fail"; }
v_token_perm() { chmod 600 "$R/etc/platform/cloudflared.token"; }
vcase "a container publishes a port" v_port "FAIL: $TR publishes a port"
vcase "traefik mounts the docker socket" v_sock_traefik "FAIL: $TR mounts the Docker socket"
vcase "another container mounts the docker socket" v_sock_other "FAIL: $DP mounts the Docker socket"
vcase "socket-proxy lacks the socket mount" v_sock_proxy_none "socket-proxy does not mount the Docker socket"
vcase "an ingress container carries platform.app" v_label "FAIL: $DP carries the platform.app label"
vcase "an unhealthy container" v_unhealthy "FAIL: $TR is unhealthy"
vcase "an exited container" v_exited "FAIL: $CF is exited"
vcase "the platform network is missing" v_no_net "network platform is missing"
vcase "the platform network has IPv6 on" v_net_v6 "network platform is 'bridge true'"
vcase "the token appears in Env" v_token_env "the tunnel token appears in the Env or Cmd of $CF"
vcase "the token appears in Cmd" v_token_cmd "the tunnel token appears in the Env or Cmd of $CF"
vcase "the stored gid is stale" v_stale_gid "stored DOCKER_GID differs"
vcase "the token group has a member" v_group_member "token group is private: token group (gid 64321) has members"
vcase "traefik is off the platform network" v_traefik_net "traefik is not on the platform network"
vcase "container DNS cannot resolve the edge" v_dns "egress-allow.cidrs"
vcase "compose.yaml drifted from the payload" v_drift "compose.yaml bytes differ from the embedded payload"
vcase "dynamic.yml has the wrong mode" v_mode "dynamic.yml uid:gid/mode is '0:0 600'"
vcase "a payload file is missing" v_missing_file "down-page index.html missing"
vcase "the gid file is missing" v_gid_file "stored DOCKER_GID file missing"
vcase "the compose project cannot be read" v_ps_fail "cannot read the state of the compose project"
vcase "the token file mode drifted" v_token_perm "token file: token file uid:gid/mode is '0:64321 600'"

# the token comparison passes on the clean fixture (above) and the failing case's output lacked the token (vcase)
# status on a host with nothing installed still exits 0
fresh
ins status
expect_rc "status on an empty host" 0
expect_out_has "status on an empty host reports FAILs" "FAIL"
ins verify
expect_rc "verify on an empty host" 1

# ---- verify --live ----

APP_HOST="ingress-livetest.example.test"
header_variants() { awk '/^# variants-begin$/ { on = 1; next } /^# variants-end$/ { on = 0 } on && !/^# variant \| code$/' "$REPO_DYNAMIC" | sed 's/^# //'; }
live_fresh() {
  fresh
  export INSTALL_INGRESS_LIVE_LOCAL=1
  printf '{"msg":"start"}\n' > "$STATE/traefik_log_pre"
  : > "$STATE/traefik_log_post"
}
live() { run_cmd "$script" verify --live "$@"; }
removed_all() { # label
  expect_eq "$1: all three containers removed by id" "$(sort "$STATE/removed_ids" 2>/dev/null | tr '\n' ' ')" "aaaaaaaaaaaa bbbbbbbbbbbb cccccccccccc "
  expect_eq "$1: no fixture left" "$(find "$STATE" -maxdepth 1 -name 'created_*' | wc -l)" "0"
}

# nothing is created without --live
live_fresh
ins verify
expect_calls_lacks "verify without --live creates no container" "run -d"
expect_calls_lacks "verify without --live removes nothing" "docker rm"
expect_calls_lacks "verify without --live starts no curl probe" "curl"

# happy path
live_fresh
live
expect_rc "verify --live passes" 0
expect_out_has "verify --live says so" "all live checks passed"
removed_all "happy path"
expect_calls_has "labelled app: exact argv prefix" "docker run -d --name ingress-livetest --network platform --label platform.app=ingress-livetest --expose 8080 docker.io/library/busybox:1.37.0@sha256:"
sibling_line="$(grep -F -- '--name ingress-livetest-sibling' "$CALL_LOG" | head -n1)"
expect_eq "the sibling carries no platform.app label" "$(grep -c 'platform.app' <<<"$sibling_line")" "0"
curl_line="$(grep -F -- '--name ingress-livetest-curl' "$CALL_LOG" | head -n1)"
expect_eq "the curl container carries no platform.app label" "$(grep -c 'platform.app' <<<"$curl_line")" "0"
expect_eq "the curl container is the pinned curl image" "$(grep -c 'docker.io/curlimages/curl:8.23.0@sha256:' <<<"$curl_line")" "1"
runs_ok=yes
while IFS= read -r l; do
  [[ "$l" =~ @sha256:[0-9a-f]{64} ]] || runs_ok="no: $l"
done < <(grep '^docker run ' "$CALL_LOG")
expect_eq "every created container image is pinned by tag and digest" "$runs_ok" "yes"
expect_eq "three containers were created" "$(grep -c '^docker run ' "$CALL_LOG")" "3"
expect_eq "the test app image is the busybox pin compose.yaml already uses" "$(grep -c "$(sed -n 's/^readonly LIVE_IMAGE="\(.*\)"$/\1/p' "$script")" "$REPO_COMPOSE")" "1"
expect_eq "the curl image pin has an exact tag and digest" "$(sed -n 's/^readonly CURL_IMAGE="\(.*\)"$/\1/p' "$script" | grep -cE '^[a-z0-9.-]+/[a-z0-9._/-]+:[0-9]+\.[0-9]+\.[0-9]+@sha256:[0-9a-f]{64}$')" "1"
expect_out_has "positive control passes" "PASS: positive control: a normal path reaches the labelled app (200)"
expect_out_has "positive control log check passes" "PASS: positive control: the request appears in the app's own log"
while IFS=' ' read -r vname _ vcode; do
  expect_out_has "variant $vname passes" "PASS: /_jobs variant $vname answers the recorded $vcode"
  expect_out_has "variant $vname is absent from the app log" "PASS: /_jobs variant $vname is absent from the app's log"
done < <(header_variants)
expect_out_has "ping refusal passes" "PASS: the Traefik ping port refuses a connection from a sibling container"
expect_out_has "killed listener passes" "PASS: a killed listener in a running container answers the friendly 502"
expect_out_has "stop-then-down passes" "PASS: a stopped app answers the friendly 503 on /"
expect_out_has "stop-then-down non-root passes" "PASS: a stopped app answers the friendly 503 on a non-root path"
expect_out_lacks "a normal run never holds" "HOLD:"
expect_eq "every probe goes to traefik:80" "$(grep -c '^docker exec ingress-livetest-curl curl' "$CALL_LOG")" "$(grep -cE 'http://traefik:(80|8082)/' "$CALL_LOG")"

# the same probe set goes through ssh with sudo when not local
live_fresh
unset INSTALL_INGRESS_LIVE_LOCAL
mkstub ssh <<'EOF'
cat > /dev/null
exit 255
EOF
run_cmd "$script" verify --live --host alias
expect_rc "live over an unreachable ssh fails" 1
expect_calls_has "live commands run through ssh with BatchMode" "ssh -o BatchMode=yes -o ConnectTimeout=10"
expect_calls_has "live docker commands run under sudo -n" "-- alias sudo -n cat"
live_fresh

# stale leftovers refuse the run and create nothing
live_fresh
echo "0123456789ab" > "$STATE/live_existing_label"
live
expect_rc "a labelled leftover refuses the run" 1
expect_out_has "the stale-leftover message gives the removal command" "sudo docker rm -f ingress-livetest ingress-livetest-sibling ingress-livetest-curl"
expect_calls_lacks "a labelled leftover: nothing created" "run -d"
live_fresh
echo "0123456789ab" > "$STATE/live_existing_name"
live
expect_rc "a same-name leftover refuses the run" 1
expect_out_has "same-name leftover gives the removal command" "sudo docker rm -f ingress-livetest ingress-livetest-sibling ingress-livetest-curl"
expect_calls_lacks "a same-name leftover: nothing created" "run -d"

# one mutated failure per probe: rc 1, a distinct message, and everything is still removed
lfail() { # label, switch file, expected message
  live_fresh
  touch "$STATE/$2"
  live
  expect_rc "live probe fails: $1" 1
  expect_out_has "live failure message: $1" "$3"
  removed_all "after the failure ($1)"
}
lfail "app not routed" app_unrouted "FAIL: positive control: a normal path reaches the labelled app (200): status 404, want 200"
lfail "app log blind" no_app_log "the request does not appear in the app's log"
lfail "unmatched host served" unmatched_200 "FAIL: unmatched host answers the friendly 503 on /: status 200, want 503"
lfail "unmatched host without the friendly body" no_friendly "unmatched host answers the friendly 503 on /: status 503 as wanted but the friendly body is missing"
lfail "sibling routed" sibling_routed "FAIL: unlabelled sibling name answers the friendly 503 on /"
lfail "sibling reached" sibling_routed "the unlabelled sibling received a request"
lfail "a variant reaches the app" jobs_leak "/_jobs variant sub reached the app"
lfail "killed listener still served" kill_ineffective "a killed listener in a running container answers the friendly 502: status 200, want 502"
lfail "killed listener answered 503" killed_503 "a killed listener in a running container answers the friendly 502: status 503, want 502"
lfail "listener could not be killed" kill_fail "could not kill the test app's listener"
lfail "stopped app keeps answering 502" stop_502 "the stopped app still answers 502"
live_fresh
touch "$STATE/rm_fail"
live
expect_rc "containers that cannot be removed fail the run" 1
expect_out_has "the removal failure is reported" "FAIL: could not remove the test containers"
expect_out_has "the manual removal command is printed" "remove them by hand: ssh <alias> sudo docker rm -f ingress-livetest ingress-livetest-sibling ingress-livetest-curl"

lfail_val() { # label, ping_rc value, expected message
  live_fresh
  echo "$2" > "$STATE/ping_rc"
  live
  expect_rc "ping probe fails: $1" 1
  expect_out_has "ping probe message: $1" "$3"
  removed_all "after the ping failure ($1)"
}
lfail_val "the ping port answers" 0 "the Traefik ping port answered a sibling container"
lfail_val "the ping port times out" 28 "timed out instead of refusing"
lfail_val "the ping probe fails another way" 6 "ended with curl exit 6, want 7"

# a variant answered with another code than the recorded one
live_fresh
echo "/_jobs%2Fx 200" > "$STATE/variant_override"
live
expect_rc "a variant with an unexpected code fails" 1
expect_out_has "the variant is named with both codes" "FAIL: /_jobs variant enc-slash answers the recorded 400: status 200, want 400"
removed_all "after the variant code failure"
live_fresh
echo "/_jobs 502" > "$STATE/variant_override"
live
expect_out_has "a 503 variant answering 502 fails" "FAIL: /_jobs variant exact answers the recorded 503 with the friendly body: status 502, want 503"

# the probe table's codes come from the dynamic.yml header block, never from this script
live_fresh
sed 's/^# exact | 503$/# exact | 400/' "$script" > "$T_TMP/mut-header.sh"
chmod +x "$T_TMP/mut-header.sh"
run_cmd "$T_TMP/mut-header.sh" verify --live
expect_rc "a changed header code fails the run" 1
expect_out_has "the changed variant is named" "FAIL: /_jobs variant exact answers the recorded 400: status 503, want 400"
removed_all "after the header mutation"
live_fresh
sed '/^# upper | 503$/d' "$script" > "$T_TMP/mut-header2.sh"
chmod +x "$T_TMP/mut-header2.sh"
run_cmd "$T_TMP/mut-header2.sh" verify --live
expect_rc "a missing header row fails the run" 1
expect_out_has "the variant without a recorded code is named" "FAIL: /_jobs variant upper: no recorded code in the dynamic.yml variants block"
expect_eq "the script never retypes a recorded variant code" "$(grep -cE '^ *"?(exact|upper|sub)"? *\| *[0-9]{3}' "$script")" "0"

# a container that cannot be created: what exists is removed
live_fresh
touch "$STATE/run_fail_ingress-livetest-curl"
live
expect_rc "the curl container cannot be created" 1
expect_out_has "the creation failure is named" "could not create a test container"
expect_eq "the two containers already created are removed" "$(sort "$STATE/removed_ids" | tr '\n' ' ')" "aaaaaaaaaaaa bbbbbbbbbbbb "

# signals during the run still remove every container
live_bg() { # script args...; sets rc and out from the background run
  "$@" > "$T_TMP/bg.out" 2>&1 &
  BGPID=$!
  echo "$BGPID" > "$STATE/installer_pid"
  wait "$BGPID"
  rc=$?
  out="$(cat "$T_TMP/bg.out")"
}
live_fresh
echo 3 > "$STATE/kill_on_exec"
live_bg "$script" verify --live
expect_rc "TERM during the probes exits 143" 143
removed_all "after TERM during the probes"
live_fresh
echo 9 > "$STATE/kill_on_exec"
live_bg "$script" verify --live
expect_rc "TERM again, later in the run, exits 143" 143
removed_all "after a later TERM"

# --hold
traefik_line() { # host [with-ip: yes|no]
  if [ "${2:-no}" = "yes" ]; then
    printf '{"RequestHost":"%s","RequestPath":"/","request_Cf-Connecting-Ip":"%s","DownstreamStatus":200}\n' "$1" "$PROBE_IP"
  else
    printf '{"RequestHost":"%s","RequestPath":"/index.html","DownstreamStatus":200}\n' "$1"
  fi
}
hold_fresh() {
  live_fresh
  printf '\n' > "$T_TMP/tty-enter"
  export INSTALL_INGRESS_HOLD_TTY="$T_TMP/tty-enter"
  export INSTALL_INGRESS_HOLD_TIMEOUT=5
  traefik_line "$APP_HOST" no > "$STATE/traefik_log_pre"
}
hold_fresh
traefik_line "$APP_HOST" yes > "$STATE/traefik_log_post"
live --hold
expect_rc "hold: a tunnel entry with the right Host passes" 0
expect_out_has "hold: the public test hostname is printed" "https://$APP_HOST"
expect_out_has "hold: the tunnel entry passes" "PASS: hold: a request through the real tunnel (Cf-Connecting-Ip) was seen"
expect_out_has "hold: the Host check passes" "PASS: hold: the tunnel entry's Host equals the public test hostname"
expect_out_lacks "hold: the client address is never printed" "$PROBE_IP"
removed_all "after a passing hold"
expect_calls_has "hold: the stopped app is started again" "docker start ingress-livetest"

hold_fresh
traefik_line "$APP_HOST" no > "$STATE/traefik_log_post"
live --hold
expect_rc "hold: a probe-only log fails" 1
expect_out_has "hold: no Cf-Connecting-Ip entry is reported" "FAIL: hold: no request that carries Cf-Connecting-Ip arrived through the real tunnel"
removed_all "after a probe-only hold"

hold_fresh
{ traefik_line "$APP_HOST" yes; traefik_line "$APP_HOST" no; } > "$STATE/traefik_log_pre"
traefik_line "$APP_HOST" no > "$STATE/traefik_log_post"
live --hold
expect_rc "hold: a Cf-Connecting-Ip line from before the hold does not count" 1
expect_out_has "hold: the pre-hold entry is excluded" "FAIL: hold: no request that carries Cf-Connecting-Ip arrived"

hold_fresh
traefik_line "wrong.example.test" yes > "$STATE/traefik_log_post"
live --hold
expect_rc "hold: a wrong-Host tunnel entry fails" 1
expect_out_has "hold: the tunnel entry is still seen" "PASS: hold: a request through the real tunnel"
expect_out_has "hold: the Host check fails" "FAIL: hold: the tunnel entry's Host is not the public test hostname"
removed_all "after a wrong-Host hold"

hold_fresh
touch "$STATE/app_unrouted"
live --hold
expect_rc "hold: failed probes skip the hold" 1
expect_out_has "hold: the skip is reported" "hold skipped: automated probes failed"
expect_out_lacks "hold: no wait after failed probes" "HOLD:"

# without --hold the run never waits, even with a terminal that would block
hold_fresh
mkfifo "$T_TMP/blocking-tty"
export INSTALL_INGRESS_HOLD_TTY="$T_TMP/blocking-tty"
start=$SECONDS
run_cmd timeout 30 "$script" verify --live
elapsed=$((SECONDS - start))
expect_rc "no --hold: the run completes" 0
expect_out_lacks "no --hold: nothing is held" "HOLD:"
if [ "$elapsed" -lt 25 ]; then _pass; else _fail "no --hold: the run never waits" "took ${elapsed}s"; fi

# hold ended by the timeout: no readable terminal (timeout alone), then a terminal that stays silent
hold_fresh
traefik_line "$APP_HOST" yes > "$STATE/traefik_log_post"
export INSTALL_INGRESS_HOLD_TTY="$T_TMP/no-such-tty"
export INSTALL_INGRESS_HOLD_TIMEOUT=1
start=$SECONDS
live --hold
elapsed=$((SECONDS - start))
expect_rc "hold: ended by the timeout alone when no terminal is readable" 0
if [ "$elapsed" -ge 1 ] && [ "$elapsed" -lt 20 ]; then _pass; else _fail "hold: the timeout bounds the wait" "took ${elapsed}s"; fi
export INSTALL_INGRESS_HOLD_TTY="$T_TMP/blocking-tty"
rm -f "$STATE/tlog_calls" "$STATE/removed_ids" "$STATE/stopped" "$STATE/killed"
( exec 9>"$T_TMP/blocking-tty"; sleep 8 ) &
holder=$!
start=$SECONDS
live --hold
elapsed=$((SECONDS - start))
kill "$holder" 2>/dev/null
wait "$holder" 2>/dev/null
expect_rc "hold: ended by the timeout when the terminal stays silent" 0
if [ "$elapsed" -ge 1 ] && [ "$elapsed" -lt 8 ]; then _pass; else _fail "hold: a silent terminal ends at the timeout" "took ${elapsed}s"; fi

# a signal during the hold still removes every container, promptly
hold_fresh
traefik_line "$APP_HOST" yes > "$STATE/traefik_log_post"
export INSTALL_INGRESS_HOLD_TTY="$T_TMP/no-such-tty"
export INSTALL_INGRESS_HOLD_TIMEOUT=60
: > "$T_TMP/bg.out"
"$script" verify --live --hold > "$T_TMP/bg.out" 2>&1 &
BGPID=$!
waited=0
while ! grep -q 'HOLD:' "$T_TMP/bg.out" && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
start=$SECONDS
kill -TERM "$BGPID"
wait "$BGPID"
rc=$?
elapsed=$((SECONDS - start))
out="$(cat "$T_TMP/bg.out")"
expect_rc "TERM during the hold exits 143" 143
removed_all "after TERM during the hold"
if [ "$elapsed" -lt 20 ]; then _pass; else _fail "TERM during the hold is prompt" "took ${elapsed}s"; fi
hold_fresh
traefik_line "$APP_HOST" yes > "$STATE/traefik_log_post"
export INSTALL_INGRESS_HOLD_TTY="$T_TMP/no-such-tty"
export INSTALL_INGRESS_HOLD_TIMEOUT=60
"$script" verify --live --hold > "$T_TMP/bg.out" 2>&1 &
BGPID=$!
waited=0
while ! grep -q 'HOLD:' "$T_TMP/bg.out" && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
kill -HUP "$BGPID"
wait "$BGPID"
rc=$?
out="$(cat "$T_TMP/bg.out")"
expect_rc "HUP during the hold exits 129" 129
removed_all "after HUP during the hold"

t_finish
