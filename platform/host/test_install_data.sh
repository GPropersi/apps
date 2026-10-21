#!/usr/bin/env bash
# Stub tests for install-data.sh. Every default host path lands under INSTALL_DATA_ROOT, the privilege prefix is a
# logging fakesudo, and docker/stat/getent/chown/install/ssh are stateful stubs on PATH (owners are recorded by the
# chown and install stubs and reported by the stat stub; modes are real). No docker, firewall or network is touched.
#
# FIXTURES FLAGGED UNVERIFIED: the shapes of the stubbed `docker inspect` (State, Labels, Networks, Env/Cmd/Healthcheck),
# `docker network inspect`, `docker port`, Redis `ACL LIST` / `CONFIG GET` / `INFO memory` and `psql -At` output are
# reconstructed from the documented formats, not captured from a live host. The Step 6 live-docker run replaces them
# with real captures; the mutation cases stay.
#
# No routable address literals and no real password: the fixture passwords below are fake strings.
# SC2016: stub bodies and payload checks are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# SC2154: $out and $rc are set by run_cmd in lib.sh.
# shellcheck disable=SC1091,SC2016,SC2034,SC2059,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/install-data.sh"

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

# chown <owner:group> <path>: records the owner (root is 0) for the stat stub.
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

# install [-d] -m <mode> -o <owner> -g <group> [--] <dir> | <src> <dest>: a directory, or a file copy (replacing dest)
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

# stat: real mode; owner from the recorded owners (default 0:0). %g on the socket reports $STATE/docker_gid.
mkstub stat <<'EOF'
fmt="$2"
path="${@: -1}"
if [ ! -e "$path" ] && [ ! -L "$path" ]; then exit 1; fi
[ ! -f "$STATE/statfail/${path//\//_}" ] || exit 1
ug="$(cat "$STATE/owner/${path//\//_}" 2>/dev/null || echo 0:0)"
case "$fmt" in
  '%g') if [ "$path" = "$DSOCK" ]; then cat "$STATE/docker_gid"; else echo "${ug#*:}"; fi ;;
  '%u:%g %a') echo "$ug $(/usr/bin/stat -c '%a' -- "$path")" ;;
  *) /usr/bin/stat -c "$fmt" -- "$path" ;;
esac
EOF

# getent: group <gid> (state: group_absent_<gid>, group_members_<gid>), group (group_dup), passwd [name].
mkstub getent <<'EOF'
case "$1" in
  group)
    gid="${2:-}"
    if [ -z "$gid" ]; then
      if [ -f "$STATE/group_dup" ]; then
        echo "adm-grp:x:64322:"
        echo "other:x:64322:claude"
      fi
      exit 0
    fi
    if [ ! -f "$STATE/group_absent_$gid" ]; then
      echo "grp$gid:x:$gid:$(cat "$STATE/group_members_$gid" 2>/dev/null)"
      exit 0
    fi
    exit 2 ;;
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

# redis-cli stand-in for the REDIS_ADMIN_SNIPPET test: reports the password it was handed through the environment.
mkstub redis-cli <<'EOF'
printf '%s' "$REDISCLI_AUTH" > "$STATE/redis_cli_auth"
exit 0
EOF

# docker: stateful. Switch files live in $STATE (see the cases). Container names default to the stack's fixed names.
mkstub docker <<'EOF'
S="$STATE"
sub="$1"
shift
case "$sub" in
  network)
    case "$1" in
      inspect) [ -f "$S/network_exists" ] || exit 1; cat "$S/network_desc" 2>/dev/null || echo "bridge false"; exit 0 ;;
      create) touch "$S/network_exists"; echo netid; exit 0 ;;
    esac
    exit 0 ;;
  compose)
    for a in "$@"; do
      case "$a" in
        up) [ ! -f "$S/up_fail" ] || exit 1; touch "$S/stack_up"; exit 0 ;;
      esac
    done
    exit 0 ;;
  port) cat "$S/port_$1" 2>/dev/null; exit 0 ;;
  inspect)
    fmt="$2"
    name="$3"
    [ ! -f "$S/absent_$name" ] || exit 1
    [ ! -f "$S/inspect_fail_$name" ] || exit 1
    case "$fmt" in
      *State.Status*) cat "$S/state_$name" 2>/dev/null || echo "running|healthy" ;;
      *Labels*) cat "$S/labels_$name" 2>/dev/null ;;
      *Networks*) cat "$S/networks_$name" 2>/dev/null ;;
      *Config.Env* | *Config.Cmd* | *Config.Healthcheck*)
        # the fixture line is "<Env> <Cmd> <Healthcheck>"; emit only the columns the template asks for
        read -r e c h < "$S/envcmd_$name" 2>/dev/null || true
        parts=()
        [[ "$fmt" != *Config.Env* ]] || parts+=("$e")
        [[ "$fmt" != *Config.Cmd* ]] || parts+=("$c")
        [[ "$fmt" != *Config.Healthcheck* ]] || parts+=("$h")
        echo "${parts[*]}" ;;
    esac
    exit 0 ;;
  exec)
    name="$1"
    shift
    if [ "$1" = "psql" ]; then
      [ ! -f "$S/pg_fail" ] || exit 1
      sql="${@: -1}"
      case "$sql" in
        *log_min_error_statement*) cat "$S/pg_logmin" 2>/dev/null || echo panic ;;
        "SHOW log_statement") cat "$S/pg_logstmt" 2>/dev/null || echo none ;;
        "SHOW hba_file") cat "$S/pg_hba_file" 2>/dev/null || echo /etc/postgresql/pg_hba.conf ;;
        *pg_hba_file_rules*) cat "$S/pg_hba_bad" 2>/dev/null || echo 0 ;;
        # the open-database query: reports pg_open only when it carries the "datacl IS NULL" branch
        *"datacl IS NULL"*) cat "$S/pg_open" 2>/dev/null ;;
        *count*) cat "$S/pg_apps" 2>/dev/null || echo 0 ;;
      esac
      exit 0
    fi
    # redis: sh -c <snippet> sh <admin file> <redis-cli args...>
    cmd="${*:6}"
    case "$cmd" in
      "acl list") [ ! -f "$S/redis_acl_fail" ] || exit 1; cat "$S/acl_list" ;;
      "config get maxmemory-policy") printf 'maxmemory-policy\r\n%s\r\n' "$(cat "$S/redis_policy" 2>/dev/null || echo noeviction)" ;;
      "config get appendonly") printf 'appendonly\r\n%s\r\n' "$(cat "$S/redis_aof" 2>/dev/null || echo yes)" ;;
      "info memory")
        [ ! -f "$S/redis_info_fail" ] || exit 1
        printf '# Memory\r\nused_memory:%s\r\nmaxmemory:%s\r\n' "$(cat "$S/redis_used" 2>/dev/null || echo 1000)" "$(cat "$S/redis_max" 2>/dev/null || echo 100000)" ;;
      *) exit 1 ;;
    esac
    exit 0 ;;
esac
exit 0
EOF

# ---- fixtures ----

PGPW='fixture-postgres-admin-password-0001'
RPW='fixture-redis-admin-password-0002'
PGC=platform-data-postgres
RDC=platform-data-redis
ACL_BASE=$'user admin on sanitize-payload #fixturehash ~* &* +@all\nuser default off sanitize-payload resetchannels -@all\nuser health on nopass sanitize-payload resetchannels -@all +ping'
ACL_APP='user app1 on sanitize-payload #fixturehash ~app1:* resetchannels +@all -@dangerous -scan -randomkey -dbsize'

# fresh: a clean root and clean state for the next scenario, all inputs valid, nothing installed yet.
fresh() {
  rm -rf "$T_TMP/root" "$STATE" "$T_TMP/dsock"
  mkdir -p "$T_TMP/root/etc/platform" "$T_TMP/root/proc/sys/vm" "$STATE/owner"
  t_reset_calls
  R="$T_TMP/root"
  DSOCK="$T_TMP/dsock"
  export DSOCK
  printf '%s\n' "$PGPW" > "$R/etc/platform/postgres-admin.password"
  printf '%s\n' "$RPW" > "$R/etc/platform/redis-admin.password"
  chmod 640 "$R/etc/platform/postgres-admin.password" "$R/etc/platform/redis-admin.password"
  echo "0:64322" > "$STATE/owner/${R//\//_}_etc_platform_postgres-admin.password"
  echo "0:64322" > "$STATE/owner/${R//\//_}_etc_platform_redis-admin.password"
  echo 1 > "$R/proc/sys/vm/overcommit_memory"
  : > "$DSOCK"
  echo 998 > "$STATE/docker_gid"
  touch "$STATE/network_exists"
  printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' 'admin:x:1000:1000::/home/admin:/bin/bash' 'deploy:x:1001:1001::/home/deploy:/usr/local/bin/platform-login' 'claude:x:1002:1002::/home/claude:/usr/local/bin/claude-access' > "$STATE/passwd"
  printf 'com.docker.compose.project\ncom.docker.compose.service\n' > "$STATE/labels_$PGC"
  cp "$STATE/labels_$PGC" "$STATE/labels_$RDC"
  printf 'platform\n' > "$STATE/networks_$PGC"
  printf 'platform\n' > "$STATE/networks_$RDC"
  printf '["POSTGRES_PASSWORD_FILE=/etc/platform/postgres-admin.password"] ["postgres","-c","log_statement=none"] null\n' > "$STATE/envcmd_$PGC"
  printf '[] ["--maxmemory","96mb"] {"Test":["CMD","redis-cli","--user","health","--pass","placeholder","ping"]}\n' > "$STATE/envcmd_$RDC"
  printf '%s\n' "$ACL_BASE" > "$STATE/acl_list"
  export INSTALL_DATA_ROOT="$R"
  export INSTALL_DATA_SUDO=fakesudo
  export INSTALL_DATA_SOCKET="$DSOCK"
  export INSTALL_DATA_HEALTH_TIMEOUT=2
  export INSTALL_DATA_POLL=0.1
  unset INSTALL_DATA_PG_CONTAINER INSTALL_DATA_REDIS_CONTAINER INSTALL_DATA_DIR INSTALL_DATA_VAR_DIR INSTALL_DATA_SECRETS_ROOT
  unset INSTALL_DATA_PG_ADMIN_FILE INSTALL_DATA_REDIS_ADMIN_FILE INSTALL_DATA_OVERCOMMIT_FILE INSTALL_DATA_REDIS_CTR_ADMIN_FILE
}

ins() { run_cmd "$script" "$@"; }

D() { printf '%s' "$R/opt/platform/data"; }
SECRETS() { printf '%s' "$R/var/lib/platform/secrets"; }
# nosetgid <mode> <dir>: chmod keeps a directory's setgid bit on a numeric mode, so it is cleared explicitly.
nosetgid() { chmod "$1" "$2"; chmod g-s "$2"; }
setowner() { echo "$2" > "$STATE/owner/${1//\//_}"; }

# mutating docker calls: anything but the read-only network inspect, inspect, port and exec
mutating_docker_calls() {
  grep -E '^docker ' "$CALL_LOG" | grep -vE '^docker (network inspect|inspect|port|exec) ' || true
}
expect_no_mutating_docker() {
  expect_eq "$1" "$(mutating_docker_calls)" ""
}
# install always runs a plain `compose up -d --remove-orphans` (a no-op on a converged stack); nothing else may mutate
expect_only_plain_up() {
  expect_eq "$1" "$(mutating_docker_calls | grep -vE ' up -d --remove-orphans$' || true)" ""
}
no_leaks() { # label: neither fixture password is in the output or in any recorded argv
  if grep -qF -e "$PGPW" -e "$RPW" "$CALL_LOG"; then _fail "$1" "a fixture password reached an argv"; else _pass; fi
  expect_out_lacks "$1 (postgres password not printed)" "$PGPW"
  expect_out_lacks "$1 (redis password not printed)" "$RPW"
}

snap_take() {
  rm -rf "$T_TMP/snap"
  mkdir -p "$T_TMP/snap"
  cp -a "$R" "$T_TMP/snap/root"
  cp -a "$STATE" "$T_TMP/snap/state"
}
snap_restore() {
  rm -rf "$R" "$STATE"
  cp -a "$T_TMP/snap/root" "$R"
  cp -a "$T_TMP/snap/state" "$STATE"
  t_reset_calls
}

# ---- 1. usage, help and the privilege gate ----

fresh
ins --bogus
expect_rc "unknown argument" 2
ins --host
expect_rc "--host without a value" 2
ins --host -oProxyCommand=x
expect_rc "option-looking --host" 2
INSTALL_DATA_HEALTH_TIMEOUT=abc ins verify
expect_rc "non-numeric health timeout" 2
ins --help
expect_rc "--help succeeds" 0
expect_out_has "--help shows the usage line" "Usage: install-data.sh"
expect_out_has "--help shows the exit codes" "Exit: 0 ok"
expect_out_lacks "--help stops before the code" "set -euo"
INSTALL_DATA_SUDO=nosudo ins install
expect_rc "no usable privilege" 1
expect_out_has "privilege failure is explained" "no usable privilege"
t_reset_calls
ins --host alias install
expect_rc "--host streams over ssh" 0
expect_calls_has "ssh runs bash -s with the mode" "ssh -o BatchMode=yes -- alias bash -s -- install"
if cmp -s "$STATE/ssh_stdin" "$script"; then _pass; else _fail "the script itself is streamed to ssh"; fi

# ---- 2. preconditions: every problem is reported together, nothing installed, no mutating docker call ----

precondition_case() { # label, setup function, expected message
  fresh
  "$2"
  ins install
  expect_rc "precondition: $1 fails" 1
  expect_out_has "precondition: $1 is named" "$3"
  expect_out_has "precondition: $1 prints instructions" "Create the host-side inputs yourself"
  expect_out_has "precondition: $1 says nothing was installed" "nothing was installed"
  expect_no_mutating_docker "precondition: $1 runs no mutating docker command"
  if [ -e "$(D)" ]; then _fail "precondition: $1 wrote nothing" "the install directory exists"; else _pass; fi
  case "$2" in
    c_secrets_symlink | c_secrets_file | c_var_symlink) ;; # these pre-create the state directory themselves
    *) if [ -e "$R/var/lib/platform" ] || [ -L "$R/var/lib/platform" ]; then _fail "precondition: $1 created no state directory" "$R/var/lib/platform exists"; else _pass; fi ;;
  esac
  no_leaks "precondition: $1"
}
c_no_deploy() { printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' > "$STATE/passwd"; }
c_no_network() { rm -f "$STATE/network_exists"; }
c_net_ipv6() { echo "bridge true" > "$STATE/network_desc"; }
c_net_driver() { echo "overlay false" > "$STATE/network_desc"; }
c_pg_missing() { rm -f "$R/etc/platform/postgres-admin.password"; }
c_rd_missing() { rm -f "$R/etc/platform/redis-admin.password"; }
c_pg_mode() { chmod 644 "$R/etc/platform/postgres-admin.password"; }
c_rd_group() { setowner "$R/etc/platform/redis-admin.password" "0:0"; }
c_pg_owner() { setowner "$R/etc/platform/postgres-admin.password" "1000:64322"; }
c_pg_empty() { : > "$R/etc/platform/postgres-admin.password"; }
c_pg_newline_only() { printf '\n' > "$R/etc/platform/postgres-admin.password"; }
c_rd_multiline() { printf 'line-one\nline-two\n' > "$R/etc/platform/redis-admin.password"; }
c_rd_multiline_nonl() { printf 'line-one\nline-two' > "$R/etc/platform/redis-admin.password"; }
c_rd_two_newlines() { printf 'line-one\n\n' > "$R/etc/platform/redis-admin.password"; }
c_pg_symlink() { mv "$R/etc/platform/postgres-admin.password" "$R/etc/platform/real-pg"; ln -s real-pg "$R/etc/platform/postgres-admin.password"; }
c_admin_group_absent() { touch "$STATE/group_absent_64322"; }
c_secrets_group_absent() { touch "$STATE/group_absent_64323"; }
c_admin_group_members() { echo "claude" > "$STATE/group_members_64322"; }
c_secrets_group_members() { echo "deploy" > "$STATE/group_members_64323"; }
c_group_dup() { touch "$STATE/group_dup"; }
c_admin_group_primary() { echo 'svc:x:2000:64322::/home/svc:/bin/false' >> "$STATE/passwd"; }
c_secrets_group_primary() { echo 'svc:x:2000:64323::/home/svc:/bin/false' >> "$STATE/passwd"; }
c_admin_group_docker() { echo 64322 > "$STATE/docker_gid"; }
c_secrets_group_docker() { echo 64323 > "$STATE/docker_gid"; }
c_secrets_symlink() { mkdir -p "$R/var/lib/platform" "$R/elsewhere"; ln -s "$R/elsewhere" "$R/var/lib/platform/secrets"; }
c_secrets_file() { mkdir -p "$R/var/lib/platform"; : > "$R/var/lib/platform/secrets"; }
c_var_symlink() { mkdir -p "$R/elsewhere"; mkdir -p "$R/var/lib"; ln -s "$R/elsewhere" "$R/var/lib/platform"; }
precondition_case "missing deploy user" c_no_deploy "the deploy user does not exist"
precondition_case "missing deploy user names the make command" c_no_deploy "make host-deploy-user"
precondition_case "missing platform network" c_no_network "network platform is missing"
precondition_case "missing network names the make command" c_no_network "make host-ingress"
precondition_case "IPv6 network" c_net_ipv6 "want 'bridge false'"
precondition_case "wrong network driver" c_net_driver "want 'bridge false'"
precondition_case "missing Postgres admin file" c_pg_missing "Postgres admin password file missing"
precondition_case "missing Redis admin file" c_rd_missing "Redis admin password file missing"
precondition_case "Postgres admin file mode" c_pg_mode "uid:gid/mode is '0:64322 644'"
precondition_case "Redis admin file group" c_rd_group "uid:gid/mode is '0:0 640'"
precondition_case "Postgres admin file owner" c_pg_owner "uid:gid/mode is '1000:64322 640'"
precondition_case "empty Postgres admin file" c_pg_empty "admin password file is empty"
precondition_case "newline-only Postgres admin file" c_pg_newline_only "has no content"
precondition_case "multi-line Redis admin file" c_rd_multiline "more than one line"
precondition_case "multi-line Redis admin file without a trailing newline" c_rd_multiline_nonl "more than one line"
precondition_case "a line plus an empty line" c_rd_two_newlines "more than one line"
precondition_case "symlinked Postgres admin file" c_pg_symlink "is a symlink"
precondition_case "missing admin group" c_admin_group_absent "no group with gid 64322"
precondition_case "missing app-secrets group" c_secrets_group_absent "no group with gid 64323"
precondition_case "admin group with members" c_admin_group_members "group (gid 64322) has members"
precondition_case "app-secrets group with members" c_secrets_group_members "group (gid 64323) has members"
precondition_case "duplicate group entries" c_group_dup "more than one group entry carries gid 64322"
precondition_case "admin group as an account's primary group" c_admin_group_primary "group (gid 64322) is an account's primary group"
precondition_case "app-secrets group as an account's primary group" c_secrets_group_primary "group (gid 64323) is an account's primary group"
precondition_case "admin group is the Docker socket's group" c_admin_group_docker "group (gid 64322) is the Docker socket's group"
precondition_case "app-secrets group is the Docker socket's group" c_secrets_group_docker "group (gid 64323) is the Docker socket's group"
precondition_case "secrets root as a symlink" c_secrets_symlink "secrets root is a symlink"
precondition_case "secrets root as a file" c_secrets_file "secrets root is not a directory"
precondition_case "state directory as a symlink" c_var_symlink "platform state directory is a symlink"

# the symlink target is untouched and nothing was created through it
fresh
c_secrets_symlink
ins install
expect_eq "a symlinked secrets root target stays empty" "$(ls -A "$R/elsewhere")" ""

# all problems at once
fresh
c_no_deploy
c_no_network
c_pg_missing
c_rd_multiline
c_admin_group_absent
c_secrets_group_members
ins install
expect_rc "several problems fail" 1
for want in "the deploy user does not exist" "network platform is missing" "Postgres admin password file missing" "Redis admin password file has more than one line" "no group with gid 64322" "group (gid 64323) has members"; do
  expect_out_has "all problems are reported together: $want" "$want"
done
expect_out_has "instructions name the admin group" "groupadd --gid 64322"
expect_out_has "instructions name the app-secrets group" "groupadd --gid 64323"
expect_out_has "instructions create a password file with the group" "install -m 0640 -o root -g 64322 /dev/null"
no_leaks "several problems"
expect_eq "the only docker call is the read-only network inspect" "$(grep -cE '^docker ' "$CALL_LOG")" "$(grep -cE '^docker network inspect ' "$CALL_LOG")"

# a single trailing newline is accepted, with or without it on a single line
accept_case() {
  fresh
  "$2"
  ins install
  expect_rc "accepted: $1" 0
  expect_out_lacks "accepted: $1 reports no precondition failure" "preconditions failed"
}
c_pg_nonl() { printf '%s' "$PGPW" > "$R/etc/platform/postgres-admin.password"; }
c_rd_nl() { printf '%s\n' "$RPW" > "$R/etc/platform/redis-admin.password"; }
accept_case "a single-line file without a trailing newline" c_pg_nonl
accept_case "a single-line file with one trailing newline" c_rd_nl

# ---- 3. a clean install ----

fresh
ins install
expect_rc "clean install" 0
expect_out_has "install ends done" "install-data: done"
expect_out_has "install reports healthy containers" "healthy: both containers"
no_leaks "clean install"
for f in compose.yaml pg_hba.conf reserved-names.txt connection.env; do
  expect_eq "$f is mode 644" "$(/usr/bin/stat -c '%a' "$(D)/$f")" "644"
done
expect_eq "redis-entrypoint.sh is mode 755" "$(/usr/bin/stat -c '%a' "$(D)/redis-entrypoint.sh")" "755"
expect_eq "the install directory is mode 755" "$(/usr/bin/stat -c '%a' "$(D)")" "755"
expect_eq "the state directory is mode 755" "$(/usr/bin/stat -c '%a' "$R/var/lib/platform")" "755"
expect_eq "the secrets root is mode 2710 (setgid)" "$(/usr/bin/stat -c '%a' "$(SECRETS)")" "2710"
expect_eq "the secrets root is owned by deploy and group 64323" "$(cat "$STATE/owner/${R//\//_}_var_lib_platform_secrets")" "1001:64323"
expect_calls_has "the state directory is created with explicit owner and mode" "install -d -m 0755 -o root -g root $R/var/lib/platform"
expect_calls_has "the missing parent of the install directory is created with an explicit mode" "install -d -m 0755 -o root -g root $R/opt/platform"
expect_calls_has "files are installed with owner and mode in one step" "install -m 644 -o root -g root -- "
expect_calls_lacks "no cp-then-chown window for placed files" "chown root:root $R/opt"
expect_calls_has "the stack is started with a forced recreate on first install" "--force-recreate"
expect_eq "connection.env holds exactly the four host and port values" "$(cat "$(D)/connection.env")" "$(printf '%s\n' 'PLATFORM_PG_HOST=postgres' 'PLATFORM_PG_PORT=5432' 'PLATFORM_REDIS_HOST=redis' 'PLATFORM_REDIS_PORT=6379')"
if grep -rqF -e "$PGPW" -e "$RPW" "$R/opt" "$R/var"; then _fail "no secret appears in any installed file"; else _pass; fi
if cmp -s "$(D)/redis-entrypoint.sh" "$here/../data/redis-entrypoint.sh" && cmp -s "$(D)/compose.yaml" "$here/../data/compose.yaml" && cmp -s "$(D)/pg_hba.conf" "$here/../data/pg_hba.conf" && cmp -s "$(D)/reserved-names.txt" "$here/../registry/reserved-names.txt"; then
  _pass
else
  _fail "the installed payloads equal their tracked sources"
fi

# the gid in the script equals the group_add of both services in compose.yaml
if [ "$(grep -c '^      - "64322"$' "$here/../data/compose.yaml")" = "2" ]; then _pass; else _fail "compose.yaml group_add holds the admin gid for both services"; fi

# a second run on the converged host: only already: lines, no mutating docker call
snap_take
t_reset_calls
ins install
expect_rc "second install" 0
expect_out_lacks "second install changes nothing" "changed:"
expect_out_has "second install reports already: for the stack" "already: stack running"
expect_out_has "second install reports already: for the secrets root" "already: $(SECRETS)/"
expect_out_has "second install reports already: for the entrypoint" "already: $(D)/redis-entrypoint.sh"
expect_only_plain_up "second install makes no mutating docker call besides the plain up -d"
expect_calls_has "second install runs a plain up -d (closes the stale-container window)" "up -d --remove-orphans"
expect_calls_lacks "second install does not recreate" "--force-recreate"

# a stopped container on an unchanged host: started without a forced recreate
snap_restore
echo "exited|" > "$STATE/state_$PGC"
ins install
expect_calls_has "a stopped container is started" "compose -p platform-data"
expect_calls_lacks "a stopped container is not force-recreated" "--force-recreate"
# (the stub keeps the state file, so the health wait fails here: the start itself is what this case checks)

# a changed mounted file recreates the containers
snap_restore
echo "# changed" >> "$(D)/pg_hba.conf"
ins install
expect_rc "install repairs a changed mounted file" 0
expect_out_has "the changed file is reported" "changed: $(D)/pg_hba.conf"
expect_calls_has "a changed mounted file recreates the containers" "--force-recreate"
# a changed entrypoint also recreates
snap_restore
echo "# changed" >> "$(D)/redis-entrypoint.sh"
ins install
expect_calls_has "a changed entrypoint recreates the containers" "--force-recreate"
# a changed compose.yaml is applied by a plain up -d (docker recreates what changed), not a forced recreate
snap_restore
echo "# changed" >> "$(D)/compose.yaml"
ins install
expect_rc "install repairs a changed compose.yaml" 0
expect_out_has "the changed compose.yaml is reported" "changed: $(D)/compose.yaml"
expect_out_has "a changed compose.yaml reports the stack as started" "changed: stack started"
expect_calls_has "a changed compose.yaml runs up -d" "up -d --remove-orphans"
expect_calls_lacks "a changed compose.yaml alone is not force-recreated" "--force-recreate"
# a changed non-mounted file does not
snap_restore
echo "# changed" >> "$(D)/reserved-names.txt"
ins install
expect_rc "install repairs a changed reserved-names.txt" 0
expect_out_has "reserved-names.txt is reported" "changed: $(D)/reserved-names.txt"
expect_calls_lacks "a changed list does not recreate the containers" "--force-recreate"
# a wrong entrypoint mode is repaired
snap_restore
chmod 644 "$(D)/redis-entrypoint.sh"
ins install
expect_eq "install repairs the entrypoint mode" "$(/usr/bin/stat -c '%a' "$(D)/redis-entrypoint.sh")" "755"

# an existing secrets root with a wrong mode, owner or group is corrected, non-recursively
snap_restore
mkdir -p "$(SECRETS)/app1"
echo hidden > "$(SECRETS)/app1/db-password"
chmod 640 "$(SECRETS)/app1/db-password"
nosetgid 0700 "$(SECRETS)"
setowner "$(SECRETS)" "0:0"
t_reset_calls
ins install
expect_rc "install corrects the secrets root" 0
expect_out_has "the correction is reported" "changed: $(SECRETS)/ (was '0:0 700'"
expect_eq "the secrets root mode is corrected" "$(/usr/bin/stat -c '%a' "$(SECRETS)")" "2710"
expect_eq "the secrets root owner is corrected" "$(cat "$STATE/owner/${R//\//_}_var_lib_platform_secrets")" "1001:64323"
expect_eq "the app directory content is untouched" "$(cat "$(SECRETS)/app1/db-password")" "hidden"
expect_eq "the app file mode is untouched" "$(/usr/bin/stat -c '%a' "$(SECRETS)/app1/db-password")" "640"
expect_calls_lacks "no recursive chown" "chown -R"
expect_calls_lacks "no recursive chmod" "chmod -R"
expect_calls_lacks "nothing inside the secrets root is chowned" "app1"

# a stray setgid bit on the state directory is cleared (a numeric chmod alone would keep it)
snap_restore
chmod 2755 "$R/var/lib/platform"
ins install
expect_rc "install corrects a setgid state directory" 0
expect_eq "the state directory loses the stray setgid bit" "$(/usr/bin/stat -c '%a' "$R/var/lib/platform")" "755"

# a stack that never becomes healthy, and a compose failure
snap_restore
echo "running|starting" > "$STATE/state_$RDC"
ins install
expect_rc "an unhealthy stack fails the install" 1
expect_out_has "the unhealthy container is named" "$RDC is starting"
snap_restore
touch "$STATE/up_fail"
echo "# x" >> "$(D)/compose.yaml"
ins install
expect_rc "a failed compose up fails the install" 1
expect_out_has "the compose failure is named" "docker compose up failed"

# ---- 4. verify on the converged host ----

snap_restore
ins verify
expect_rc "verify passes on the converged host" 0
expect_out_has "verify summary" "install-data: all checks passed"
expect_out_has "a revoked PUBLIC CONNECT is a PASS" "PASS: PUBLIC has no CONNECT on postgres and template1"
no_leaks "verify"
expect_out_lacks "no WARN on a healthy host" "WARN:"
ins status
expect_rc "status passes" 0
expect_calls_lacks "verify never recreates" "--force-recreate"
expect_no_mutating_docker "verify makes no mutating docker call"
# the admin password reaches redis-cli only inside the container; the stub snippet receives the container path
expect_calls_has "Redis admin calls go through docker exec" "docker exec $RDC sh -c"
expect_calls_has "the admin file is passed by its in-container path" "sh /etc/platform/redis-admin.password acl list"
expect_calls_lacks "no --pass or -a password flag on any Redis admin call" "redis-cli --user admin --pass"

# verify cases: each mutation names its reason
vcase() { # label, setup function, expected output
  snap_restore
  "$2"
  ins verify
  expect_rc "verify fails: $1" 1
  expect_out_has "verify names the reason: $1" "$3"
  no_leaks "verify: $1"
}
v_port() { echo "0.0.0.0:5432" > "$STATE/port_$PGC"; }
v_port_redis() { echo "6379/tcp -> 0.0.0.0:6379" > "$STATE/port_$RDC"; }
v_label_pg() { printf 'platform.app\n' >> "$STATE/labels_$PGC"; }
v_label_rd() { printf 'platform.app\n' >> "$STATE/labels_$RDC"; }
v_net() { printf 'platform\nextra\n' > "$STATE/networks_$PGC"; }
v_net_only_other() { printf 'bridge\n' > "$STATE/networks_$RDC"; }
v_env_pg() { printf '["POSTGRES_PASSWORD=%s"] [] null\n' "$PGPW" > "$STATE/envcmd_$PGC"; }
v_cmd_pg() { printf '[] ["postgres","--password=%s"] null\n' "$PGPW" > "$STATE/envcmd_$PGC"; }
v_hc_rd() { printf '[] [] {"Test":["CMD","redis-cli","--pass","%s"]}\n' "$RPW" > "$STATE/envcmd_$RDC"; }
v_env_rd() { printf '["REDIS_PASSWORD=%s"] [] null\n' "$RPW" > "$STATE/envcmd_$RDC"; }
v_cross() { printf '["X=%s"] [] null\n' "$PGPW" > "$STATE/envcmd_$RDC"; }
v_inspect_fail() { touch "$STATE/inspect_fail_$PGC"; }
v_default_on() { printf '%s\n' "$ACL_BASE" | sed 's/^user default off.*/user default on nopass ~* \&* +@all/' > "$STATE/acl_list"; }
v_default_missing() { printf '%s\n' "$ACL_BASE" | grep -v '^user default' > "$STATE/acl_list"; }
v_policy() { echo allkeys-lru > "$STATE/redis_policy"; }
v_aof() { echo no > "$STATE/redis_aof"; }
v_pg_open_apps() { echo postgres > "$STATE/pg_open"; echo 2 > "$STATE/pg_apps"; }
v_pg_open_t1() { echo template1 > "$STATE/pg_open"; echo 1 > "$STATE/pg_apps"; }
v_root_owner() { setowner "$(SECRETS)" "1000:64323"; }
v_root_group() { setowner "$(SECRETS)" "1001:1001"; }
v_root_mode() { nosetgid 0750 "$(SECRETS)"; }
v_root_nosetgid() { nosetgid 0710 "$(SECRETS)"; }
v_root_missing() { rmdir "$(SECRETS)"; }
v_parent_mode() { nosetgid 0775 "$R/var/lib/platform"; }
v_parent_owner() { setowner "$R/var/lib/platform" "1001:0"; }
v_reserved_missing() { rm -f "$(D)/reserved-names.txt"; }
v_reserved_mode() { chmod 600 "$(D)/reserved-names.txt"; }
v_reserved_bytes() { echo extra >> "$(D)/reserved-names.txt"; }
v_ep_missing() { rm -f "$(D)/redis-entrypoint.sh"; }
v_ep_mode() { chmod 644 "$(D)/redis-entrypoint.sh"; }
v_ep_bytes() { echo "# x" >> "$(D)/redis-entrypoint.sh"; }
v_compose_mode() { chmod 600 "$(D)/compose.yaml"; }
v_compose_bytes() { echo "# x" >> "$(D)/compose.yaml"; }
v_hba_bytes() { echo "# x" >> "$(D)/pg_hba.conf"; }
v_conn_mode() { chmod 664 "$(D)/connection.env"; }
v_conn_bytes() { echo "EXTRA=1" >> "$(D)/connection.env"; }
v_unhealthy() { echo "running|unhealthy" > "$STATE/state_$PGC"; }
v_stopped() { echo "exited|" > "$STATE/state_$RDC"; }
v_absent() { touch "$STATE/absent_$RDC"; }
v_logmin() { echo all > "$STATE/pg_logmin"; }
v_acl_extra() { printf '%s\nuser mallory on #fixturehash ~* &* +@all\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_noreset() { printf '%s\nuser app1 on #fixturehash ~app1:* +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_allkeys() { printf '%s\nuser app1 on #fixturehash ~* resetchannels +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_nocmds() { printf '%s\nuser app1 on #fixturehash ~app1:* resetchannels +@all -@dangerous -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_norand() { printf '%s\nuser app1 on #fixturehash ~app1:* resetchannels +@all -@dangerous -scan -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_nodbsize() { printf '%s\nuser app1 on #fixturehash ~app1:* resetchannels +@all -@dangerous -scan -randomkey\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_nodanger() { printf '%s\nuser app1 on #fixturehash ~app1:* resetchannels +@all -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_otherkeys() { printf '%s\nuser app1 on #fixturehash ~app1:* ~other:* resetchannels +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_channels() { printf '%s\nuser app1 on #fixturehash ~app1:* &* resetchannels +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_allow_after() { printf '%s\nuser app1 on #fixturehash ~app1:* resetchannels -@all -@dangerous -scan -randomkey -dbsize +scan\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_nopass() { printf '%s\nuser app1 on nopass ~app1:* resetchannels +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_reserved() { printf '%s\nuser postgres on #fixturehash ~postgres:* resetchannels +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_badname() { printf '%s\nuser App_1 on #fixturehash ~App_1:* resetchannels +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_health_wide() { printf '%s\n' "$ACL_BASE" | sed 's/^user health .*/user health on nopass resetchannels -@all +ping +get/' > "$STATE/acl_list"; }
v_acl_health_keys() { printf '%s\n' "$ACL_BASE" | sed 's/^user health .*/user health on nopass ~* resetchannels -@all +ping/' > "$STATE/acl_list"; }
v_acl_admin_nopass() { printf '%s\n' "$ACL_BASE" | sed 's/^user admin .*/user admin on nopass ~* \&* +@all/' > "$STATE/acl_list"; }
v_acl_fail() { touch "$STATE/redis_acl_fail"; }
v_info_fail() { touch "$STATE/redis_info_fail"; }
v_pg_fail() { touch "$STATE/pg_fail"; }
v_admin_mode() { chmod 644 "$R/etc/platform/postgres-admin.password"; }
v_admin_empty() { : > "$R/etc/platform/redis-admin.password"; }
v_group_members() { echo claude > "$STATE/group_members_64322"; }
v_no_deploy() { printf '%s\n' 'root:x:0:0:root:/root:/bin/bash' > "$STATE/passwd"; }
v_net_gone() { rm -f "$STATE/network_exists"; }
v_default_neither() { printf '%s\n' "$ACL_BASE" | sed 's/^user default off.*/user default nopass resetchannels -@all/' > "$STATE/acl_list"; }
v_acl_selector() { printf '%s\nuser app1 on #fixturehash (~* +@all) ~app1:* resetchannels +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_selector_first() { printf '%s\nuser app1 on #fixturehash (~* +@all) ~app1:* resetchannels -@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_reset() { printf '%s\nuser app1 on #fixturehash reset ~app1:* resetchannels +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_nocommands() { printf '%s\nuser app1 on #fixturehash ~app1:* resetchannels nocommands -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_alldbs() { printf '%s\nuser app1 on #fixturehash ~app1:* resetchannels alldbs +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_unknown() { printf '%s\nuser app1 on #fixturehash ~app1:* resetchannels frobnicate +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_pwtoken() { printf '%s\nuser app1 on #fixturehash >hunter2secret ~app1:* resetchannels +@all -@dangerous -scan -randomkey -dbsize\n' "$ACL_BASE" > "$STATE/acl_list"; }
v_acl_health_hash() { printf '%s\n' "$ACL_BASE" | sed 's/^user health .*/user health on nopass #leakedhash resetchannels -@all +ping/' > "$STATE/acl_list"; }
v_hba_file() { echo /var/lib/postgresql/data/pg_hba.conf > "$STATE/pg_hba_file"; }
v_hba_rules() { echo 1 > "$STATE/pg_hba_bad"; }
v_logstmt() { echo all > "$STATE/pg_logstmt"; }
v_stat_fail() { mkdir -p "$STATE/statfail"; touch "$STATE/statfail/${R//\//_}_opt_platform_data_compose.yaml"; }
v_secrets_symlink() { rm -rf "$(SECRETS)"; mkdir -p "$R/elsewhere"; ln -s "$R/elsewhere" "$(SECRETS)"; }
v_state_symlink() { mv "$R/var/lib/platform" "$R/var/lib/real-platform"; ln -s real-platform "$R/var/lib/platform"; }
v_admin_symlink() { mv "$R/etc/platform/redis-admin.password" "$R/etc/platform/real-rd"; ln -s real-rd "$R/etc/platform/redis-admin.password"; }
vcase "published Postgres port" v_port "$PGC publishes a port"
vcase "published Redis port" v_port_redis "$RDC publishes a port"
vcase "platform.app label on Postgres" v_label_pg "$PGC carries the platform.app label"
vcase "platform.app label on Redis" v_label_rd "$RDC carries the platform.app label"
vcase "extra network" v_net "$PGC is not exactly on the platform network"
vcase "only another network" v_net_only_other "$RDC is not exactly on the platform network"
vcase "Postgres password in Env" v_env_pg "the Postgres admin password appears in the Env, Cmd or Healthcheck of $PGC"
vcase "Postgres password in Cmd" v_cmd_pg "the Postgres admin password appears in the Env, Cmd or Healthcheck of $PGC"
vcase "Redis password in the healthcheck" v_hc_rd "the Redis admin password appears in the Env, Cmd or Healthcheck of $RDC"
vcase "Redis password in Env" v_env_rd "the Redis admin password appears in the Env, Cmd or Healthcheck of $RDC"
vcase "Postgres password in the Redis container" v_cross "the Postgres admin password appears in the Env, Cmd or Healthcheck of $RDC"
vcase "uninspectable container" v_inspect_fail "cannot inspect the labels of $PGC"
vcase "default Redis user enabled" v_default_on "the Redis default user is enabled"
vcase "default Redis user missing" v_default_missing "the Redis default user is missing"
vcase "eviction policy changed" v_policy "Redis eviction policy is 'allkeys-lru'"
vcase "AOF off" v_aof "Redis appendonly is 'no'"
vcase "PUBLIC CONNECT once an app database exists" v_pg_open_apps "PUBLIC still has CONNECT on: postgres"
vcase "PUBLIC CONNECT on template1 once an app database exists" v_pg_open_t1 "PUBLIC still has CONNECT on: template1"
vcase "secrets root wrong owner" v_root_owner "uid:gid/mode is '1000:64323 2710'"
vcase "secrets root wrong group" v_root_group "uid:gid/mode is '1001:1001 2710'"
vcase "secrets root wrong mode" v_root_mode "uid:gid/mode is '1001:64323 750'"
vcase "secrets root without setgid" v_root_nosetgid "uid:gid/mode is '1001:64323 710'"
vcase "secrets root missing" v_root_missing "is missing or not a directory"
vcase "state directory wrong mode" v_parent_mode "uid:gid/mode is '0:0 775'"
vcase "state directory wrong owner" v_parent_owner "uid:gid/mode is '1001:0 755'"
vcase "reserved-names.txt missing" v_reserved_missing "reserved-names.txt missing"
vcase "reserved-names.txt wrong mode" v_reserved_mode "reserved-names.txt uid:gid/mode is '0:0 600', want '0:0 644'"
vcase "reserved-names.txt altered" v_reserved_bytes "reserved-names.txt bytes differ from the embedded payload"
vcase "redis-entrypoint.sh missing" v_ep_missing "redis-entrypoint.sh missing"
vcase "redis-entrypoint.sh not executable" v_ep_mode "redis-entrypoint.sh uid:gid/mode is '0:0 644', want '0:0 755'"
vcase "redis-entrypoint.sh altered" v_ep_bytes "redis-entrypoint.sh bytes differ from the embedded payload"
vcase "compose.yaml wrong mode" v_compose_mode "compose.yaml uid:gid/mode is '0:0 600', want '0:0 644'"
vcase "compose.yaml altered" v_compose_bytes "compose.yaml bytes differ from the embedded payload"
vcase "pg_hba.conf altered" v_hba_bytes "pg_hba.conf bytes differ from the embedded payload"
vcase "connection.env wrong mode" v_conn_mode "connection.env uid:gid/mode is '0:0 664', want '0:0 644'"
vcase "connection.env altered" v_conn_bytes "connection.env bytes differ from the embedded payload"
vcase "unhealthy Postgres" v_unhealthy "$PGC is unhealthy"
vcase "stopped Redis" v_stopped "$RDC is exited"
vcase "missing Redis container" v_absent "container $RDC does not exist"
vcase "log_min_error_statement changed" v_logmin "Postgres log_min_error_statement is 'all', want panic"
vcase "ACL user with a broad rule" v_acl_extra "Redis user mallory lacks the key scope ~mallory:*"
vcase "app user without resetchannels" v_acl_noreset "Redis user app1 lacks resetchannels"
vcase "app user with ~*" v_acl_allkeys "Redis user app1 lacks the key scope ~app1:*"
vcase "app user with ~* also has an extra scope" v_acl_allkeys "has an extra key or channel scope '~*'"
vcase "app user lacking -scan" v_acl_nocmds "Redis user app1 lacks -scan"
vcase "app user lacking -randomkey" v_acl_norand "Redis user app1 lacks -randomkey"
vcase "app user lacking -dbsize" v_acl_nodbsize "Redis user app1 lacks -dbsize"
vcase "app user lacking -@dangerous" v_acl_nodanger "Redis user app1 lacks -@dangerous"
vcase "app user with a second key scope" v_acl_otherkeys "extra key or channel scope '~other:*'"
vcase "app user with a channel scope" v_acl_channels "extra key or channel scope '&*'"
vcase "app user allowing a command after the denies" v_acl_allow_after "allows '+scan' after the deny rules"
vcase "app user without a password" v_acl_nopass "Redis user app1 has no password (nopass)"
vcase "app user named like a reserved name" v_acl_reserved "unexpected Redis ACL user 'postgres'"
vcase "app user whose name is not a valid app name" v_acl_badname "unexpected Redis ACL user 'App_1'"
vcase "health user with an extra command" v_acl_health_wide "the Redis health user has an unexpected rule '+get'"
vcase "health user with a key scope" v_acl_health_keys "the Redis health user has an unexpected rule '~*'"
vcase "admin user without a password" v_acl_admin_nopass "the Redis admin user has no password (nopass)"
vcase "ACL LIST failing" v_acl_fail "cannot read ACL LIST"
vcase "INFO memory failing" v_info_fail "cannot read INFO memory from Redis"
vcase "Postgres queries failing" v_pg_fail "cannot read Postgres log_min_error_statement"
vcase "admin file mode changed after install" v_admin_mode "uid:gid/mode is '0:64322 644'"
vcase "admin file emptied after install" v_admin_empty "Redis admin password file is empty"
vcase "admin group gained a member after install" v_group_members "group (gid 64322) has members"
vcase "deploy user gone after install" v_no_deploy "the deploy user does not exist"
vcase "network gone after install" v_net_gone "network platform is missing"
vcase "default Redis user neither on nor off" v_default_neither "the Redis default user is not switched off"
vcase "app user with a selector" v_acl_selector "Redis user app1 has an unexpected rule '?~*'"
vcase "app user with a selector closing token" v_acl_selector "Redis user app1 has an unexpected rule '+@all?'"
vcase "app user with a selector placed before the deny rules" v_acl_selector_first "Redis user app1 has an unexpected rule '?~*'"
vcase "app user with reset" v_acl_reset "Redis user app1 has an unexpected rule 'reset'"
vcase "app user with nocommands" v_acl_nocommands "Redis user app1 has an unexpected rule 'nocommands'"
vcase "app user with alldbs" v_acl_alldbs "Redis user app1 has an unexpected rule 'alldbs'"
vcase "app user with an unknown token" v_acl_unknown "Redis user app1 has an unexpected rule 'frobnicate'"
vcase "app user with a password token" v_acl_pwtoken "Redis user app1 has an unexpected rule '<redacted>'"
vcase "health user with a hash token" v_acl_health_hash "the Redis health user has an unexpected rule '<redacted>'"
vcase "Postgres hba_file is not the installed one" v_hba_file "Postgres hba_file is '/var/lib/postgresql/data/pg_hba.conf'"
vcase "pg_hba rules with an error or a weak method" v_hba_rules "pg_hba_file_rules has 1 rule(s)"
vcase "log_statement changed" v_logstmt "Postgres log_statement is 'all', want none"
vcase "an unreadable file is reported, not fatal" v_stat_fail "compose.yaml uid:gid/mode is 'unreadable'"
vcase "secrets root replaced by a symlink after install" v_secrets_symlink "secrets root is a symlink"
vcase "state directory replaced by a symlink after install" v_state_symlink "platform state directory is a symlink"
vcase "Redis admin file replaced by a symlink after install" v_admin_symlink "Redis admin password file is a symlink"
# no credential material is printed for a rejected token
snap_restore
v_acl_pwtoken
ins verify
expect_out_lacks "a password token in an ACL rule is never printed" "hunter2secret"
snap_restore
v_acl_health_hash
ins verify
expect_out_lacks "a hash token in the health rule is never printed" "leakedhash"
snap_restore
INSTALL_DATA_POLL=x ins verify
expect_rc "a non-numeric poll interval" 2

# verify passes on a host with provisioned apps, and when no PUBLIC CONNECT remains
snap_restore
printf '%s\n%s\n' "$ACL_BASE" "$ACL_APP" > "$STATE/acl_list"
echo 1 > "$STATE/pg_apps"
ins verify
expect_rc "verify passes with a provisioned app (valid Redis user, revoked PUBLIC CONNECT)" 0
expect_out_has "the revoked posture is a PASS" "PASS: PUBLIC has no CONNECT on postgres and template1"
printf '%s\n%s\n%s\n' "$ACL_BASE" "$ACL_APP" 'user other-app on #fixturehash ~other-app:* resetchannels +@all -@dangerous -scan -randomkey -dbsize' > "$STATE/acl_list"
ins verify
expect_rc "verify passes with two provisioned apps" 0

# the "no apps yet" pair
snap_restore
echo "postgres template1" | tr ' ' '\n' > "$STATE/pg_open"
echo 0 > "$STATE/pg_apps"
ins verify
expect_rc "PUBLIC CONNECT present with no app database: not a failure" 0
expect_out_has "reported as already:" "already: no apps yet, posture applied by new-db"
expect_out_lacks "no FAIL line" "FAIL:"
echo 1 > "$STATE/pg_apps"
ins verify
expect_rc "PUBLIC CONNECT present with an app database: failure" 1

# the Redis memory trio
snap_restore
echo 85000 > "$STATE/redis_used"
ins verify
expect_rc "85% memory exits 0" 0
expect_out_has "85% memory prints a WARN" "WARN: Redis memory is at 85% of maxmemory"
ins status
expect_rc "85% memory in status exits 0" 0
echo 80000 > "$STATE/redis_used"
ins verify
expect_out_has "exactly 80% prints a WARN" "WARN: Redis memory is at 80%"
echo 79999 > "$STATE/redis_used"
ins verify
expect_out_lacks "just under 80% prints no WARN" "WARN:"
echo 50000 > "$STATE/redis_used"
ins verify
expect_rc "50% memory exits 0" 0
expect_out_lacks "50% memory prints no WARN" "WARN:"
echo 0 > "$STATE/redis_max"
ins verify
expect_rc "an unbounded maxmemory fails" 1
expect_out_has "unbounded maxmemory is named" "maxmemory is 0"
rm -f "$STATE/redis_max"
touch "$STATE/redis_info_fail"
ins verify
expect_rc "a failing INFO is a FAIL, not a WARN" 1
expect_out_lacks "a failing INFO prints no WARN about memory" "WARN: Redis memory"
# a WARN does not hide a real failure
rm -f "$STATE/redis_info_fail"
echo 85000 > "$STATE/redis_used"
echo allkeys-lru > "$STATE/redis_policy"
ins verify
expect_rc "a WARN together with a FAIL still fails" 1
expect_out_has "the WARN is still printed" "WARN: Redis memory"

# vm.overcommit_memory is advisory
snap_restore
echo 0 > "$R/proc/sys/vm/overcommit_memory"
ins verify
expect_rc "overcommit 0 exits 0" 0
expect_out_has "overcommit 0 prints a WARN" "WARN: vm.overcommit_memory is '0'"
rm -f "$R/proc/sys/vm/overcommit_memory"
ins verify
expect_rc "an unreadable overcommit file exits 0" 0
expect_out_has "an unreadable overcommit file prints a WARN" "WARN: vm.overcommit_memory is 'unreadable'"

# status never fails, whatever is wrong
snap_restore
echo allkeys-lru > "$STATE/redis_policy"
ins status
expect_rc "status exits 0 even with a failed check" 0
expect_out_has "status still reports the failure" "FAIL: Redis eviction policy"
expect_out_has "status counts the failures" "1 check(s) failed"

# test overrides: container names and host paths
snap_restore
cp "$STATE/labels_$PGC" "$STATE/labels_livetest-pg"
cp "$STATE/labels_$RDC" "$STATE/labels_livetest-redis"
cp "$STATE/networks_$PGC" "$STATE/networks_livetest-pg"
cp "$STATE/networks_$RDC" "$STATE/networks_livetest-redis"
cp "$STATE/envcmd_$PGC" "$STATE/envcmd_livetest-pg"
cp "$STATE/envcmd_$RDC" "$STATE/envcmd_livetest-redis"
INSTALL_DATA_PG_CONTAINER=livetest-pg INSTALL_DATA_REDIS_CONTAINER=livetest-redis ins verify
expect_rc "verify works against throwaway container names" 0
expect_calls_has "the overridden Postgres container is addressed" "docker exec livetest-pg psql"
expect_calls_has "the overridden Redis container is addressed" "docker exec livetest-redis sh -c"
expect_calls_lacks "the default container names are not used" "docker exec $PGC"
t_reset_calls
mkdir -p "$R/alt-secrets"
chmod 2710 "$R/alt-secrets"
setowner "$R/alt-secrets" "1001:64323"
INSTALL_DATA_SECRETS_ROOT="$R/alt-secrets" ins verify
expect_rc "verify honours the secrets root override" 0
nosetgid 0700 "$R/alt-secrets"
INSTALL_DATA_SECRETS_ROOT="$R/alt-secrets" ins verify
expect_rc "a wrong overridden secrets root fails" 1
expect_out_has "the overridden path is the one reported" "$R/alt-secrets uid:gid/mode is '1001:64323 700'"
INSTALL_DATA_REDIS_CTR_ADMIN_FILE=/run/other/redis.pw ins verify
expect_calls_has "the in-container admin file path is overridable" "sh /run/other/redis.pw acl list"

# ---- 5. the Redis admin snippet strips exactly one trailing newline and uses the environment only ----

fresh
snippet="$(sed -n "s/^readonly REDIS_ADMIN_SNIPPET='\\(.*\\)'\$/\\1/p" "$script")"
if [ -n "$snippet" ]; then _pass; else _fail "the Redis admin snippet is extractable"; fi
snippet_pw() { # file content (printf format) -> the REDISCLI_AUTH the stub redis-cli received
  printf "$1" > "$T_TMP/pwfile"
  rm -f "$STATE/redis_cli_auth"
  sh -c "$snippet" sh "$T_TMP/pwfile" ping
  cat "$STATE/redis_cli_auth"
}
expect_eq "snippet: one trailing newline stripped" "$(snippet_pw 'secret\n')" "secret"
expect_eq "snippet: no trailing newline" "$(snippet_pw 'secret')" "secret"
expect_eq "snippet: exactly one of two trailing newlines stripped" "$(snippet_pw 'secret\n\n'; echo x)" "secret
x"
expect_eq "snippet: password with spaces and quotes kept" "$(snippet_pw 'a b"c$d\n')" 'a b"c$d'
expect_calls_has "snippet: redis-cli runs as admin without printing the warning" "redis-cli --user admin --no-auth-warning ping"
expect_calls_lacks "snippet: the password is not in redis-cli's argv" "secret"

t_finish
