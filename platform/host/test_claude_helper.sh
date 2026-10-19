#!/usr/bin/env bash
# Stub tests for claude-helper.sh (the root helper behind the claude identity). The helper hard-codes its tool paths;
# each run uses a copy with those lines rewritten to call-log stubs. The docker stub serves a fixture of containers
# (labelled app containers, an exited one, several for one app, unlabelled infrastructure) and applies the
# --filter label=... semantics, so scope and label matching are exercised, not assumed.
# No address literals: the hygiene check flags them. SC1091: lib.sh is sourced by relative path.
# shellcheck disable=SC1091,SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
source_script="$here/claude-helper.sh"

t_init
STATE="$T_TMP/state"
mkdir -p "$STATE"
export STATE

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

# Fixture lines: "<id> <name> <app-label or -> <running|exited>".
cat > "$STATE/containers" <<'EOF'
aaaaaaaaaaaa web-1 shop running
bbbbbbbbbbbb web-2 shop running
cccccccccccc worker-1 shop exited
dddddddddddd api-1 blog running
eeeeeeeeeeee crashed-1 gone exited
ffffffffffff traefik - running
111111111111 cloudflared - running
222222222222 postgres - running
333333333333 redis - running
EOF
# name-length boundary apps: 2 and 31 characters
app31="a$(printf 'b%.0s' $(seq 1 30))"
printf '%s\n' "444444444444 ab-1 ab running" "555555555555 long-1 $app31 running" >> "$STATE/containers"

mkstub docker <<'EOF'
sub="$1"; shift
all=0; quiet=0; filter=""; format=""
while [ $# -gt 0 ]; do
  case "$1" in
    -a) all=1; shift ;;
    -q) quiet=1; shift ;;
    --filter) filter="$2"; shift 2 ;;
    --format) format="$2"; shift 2 ;;
    *) break ;;
  esac
done
if [ -f "$STATE/docker_fail" ]; then exit 1; fi
printf 'DOCKER_HOST=%s DOCKER_CONTEXT=%s HOME=%s DOCKER_CONFIG=%s PATH=%s\n' "${DOCKER_HOST-<unset>}" "${DOCKER_CONTEXT-<unset>}" "$HOME" "${DOCKER_CONFIG-<unset>}" "$PATH" > "$STATE/docker_env"
case "$sub" in
  ps)
    while read -r id name app state; do
      [ "$all" -eq 1 ] || [ "$state" = "running" ] || continue
      case "$filter" in
        "label=platform.app") [ "$app" != "-" ] || continue ;;
        label=platform.app=*) [ "$app" = "${filter#label=platform.app=}" ] || continue ;;
        "") ;;
        *) continue ;;
      esac
      if [ -f "$STATE/bad_id" ]; then id="not-hex!"; fi
      if [ "$quiet" -eq 1 ]; then echo "$id"
      elif [[ "$format" == *".ID"* ]]; then echo "$id $name"
      else printf '%s\t%s\t%s\n' "$app" "$name" "$state"; fi
    done < "$STATE/containers"
    ;;
  logs) echo "log line from $*" ;;
  stats) echo "stats for $*" ;;
  restart) [ ! -f "$STATE/restart_fail" ] || exit 1; echo "$*" ;;
  *) exit 7 ;;
esac
EOF

mkstub systemctl <<'EOF'
if [ "$1" = "is-active" ]; then
  if [ -f "$STATE/inactive_$2" ]; then echo inactive; exit 3; fi
  echo active; exit 0
fi
exit 9
EOF
mkstub free <<'EOF'
echo "Mem: 1000 400 600"
EOF
mkstub logger <<'EOF'
exit 0
EOF

# make_copy: a copy whose tool paths point at the stubs; prints its path.
make_copy() {
  local dest="$T_TMP/helper-copy"
  sed -e "s|^readonly DOCKER=.*\$|readonly DOCKER=$STUB_BIN/docker|" \
      -e "s|^readonly SYSTEMCTL=.*\$|readonly SYSTEMCTL=$STUB_BIN/systemctl|" \
      -e "s|^readonly FREE=.*\$|readonly FREE=$STUB_BIN/free|" \
      -e "s|^readonly LOGGER=.*\$|readonly LOGGER=$STUB_BIN/logger|" "$source_script" > "$dest"
  chmod +x "$dest"
  echo "$dest"
}
for marker in 'readonly DOCKER=/usr/bin/docker' 'readonly SYSTEMCTL=/usr/bin/systemctl' 'readonly FREE=/usr/bin/free' 'readonly LOGGER=/usr/bin/logger'; do
  if ! grep -qxF -- "$marker" "$source_script"; then echo "FAIL: claude-helper.sh no longer has: $marker; update this test"; exit 1; fi
done
helper="$(make_copy)"

h() { t_reset_calls; run_cmd "$helper" "$@"; }

# mutating docker verbs seen in the call log
docker_mutations() { grep -E '^docker (restart|rm|stop|kill|exec|run|start|pause|update|rename|cp|commit)( |$)' "$CALL_LOG" || true; }

# ---- ps / stats: only labelled app containers ----
h ps
expect_rc "ps succeeds" 0
expect_out_has "ps lists a running app container" "web-1"
expect_out_has "ps lists an exited app container" "crashed-1"
expect_out_has "ps lists another app" "api-1"
for infra in traefik cloudflared postgres redis; do
  expect_out_lacks "ps never lists infrastructure ($infra)" "$infra"
done
expect_eq "ps makes no docker mutation" "$(docker_mutations)" ""

h stats
expect_rc "stats succeeds" 0
expect_out_has "stats covers running app containers" "aaaaaaaaaaaa"
expect_out_has "stats covers every running app container" "dddddddddddd"
expect_out_lacks "stats excludes an exited app container" "cccccccccccc"
for id in ffffffffffff 111111111111 222222222222 333333333333; do
  expect_out_lacks "stats excludes unlabelled container $id" "$id"
done

# stats with no running app: a message, not a docker stats call with no ids
printf 'ffffffffffff traefik - running\n' > "$STATE/containers.bak"
mv "$STATE/containers" "$STATE/containers.full"
mv "$STATE/containers.bak" "$STATE/containers"
h stats
expect_rc "stats with no app containers" 0
expect_out_has "stats reports none" "no running app containers"
expect_calls_lacks "no docker stats call without ids" "docker stats"
mv "$STATE/containers.full" "$STATE/containers"

# ---- logs ----
h logs shop
expect_rc "logs aggregates" 0
expect_out_has "logs includes the first container" "==> web-1 <=="
expect_out_has "logs includes the second container" "==> web-2 <=="
expect_out_has "logs includes the exited container" "==> worker-1 <=="
expect_out_lacks "logs excludes another app" "api-1"
expect_calls_has "logs first container id" "docker logs --tail 100 --timestamps aaaaaaaaaaaa"
expect_calls_has "logs second container id" "docker logs --tail 100 --timestamps bbbbbbbbbbbb"
expect_calls_has "logs exited container id" "docker logs --tail 100 --timestamps cccccccccccc"
expect_calls_lacks "logs never touches infrastructure" "ffffffffffff"
expect_eq "logs makes no docker mutation" "$(docker_mutations)" ""

h logs shop 7
expect_rc "logs with an explicit line count" 0
expect_calls_has "line count reaches docker" "docker logs --tail 7 --timestamps aaaaaaaaaaaa"
h logs shop 1000
expect_rc "logs at the maximum" 0

lines_case() {
  h logs shop "$1"
  expect_rc "logs rejects lines '$1'" 2
  expect_eq "logs lines '$1': no docker call at all" "$(grep -c '^docker' "$CALL_LOG")" "0"
}
lines_case 0
lines_case 1001
lines_case 99999
lines_case -3
lines_case abc
lines_case 5.5
lines_case 05
lines_case ""
lines_case " 5"
lines_case $'5\n'

# ---- restart ----
h restart shop
expect_rc "restart of a labelled app" 0
expect_calls_has "restart acts on every container of the app, including the exited one" "docker restart aaaaaaaaaaaa bbbbbbbbbbbb cccccccccccc"
expect_eq "restart is exactly one docker restart call" "$(docker_mutations | wc -l)" "1"
expect_calls_lacks "restart never names an infrastructure container" "ffffffffffff"
expect_calls_lacks "restart never names another app" "dddddddddddd"

h restart gone
expect_rc "restart of a labelled-but-exited container succeeds" 0
expect_calls_has "restart targets the exited container" "docker restart eeeeeeeeeeee"

for infra in traefik cloudflared postgres redis; do
  h restart "$infra"
  expect_rc "restart of unlabelled $infra is rejected" 1
  expect_eq "restart of unlabelled $infra: no docker mutation in the log" "$(docker_mutations)" ""
done
h restart nosuchapp
expect_rc "restart of an app with zero matching containers" 1
expect_eq "zero-match restart: no docker mutation" "$(docker_mutations)" ""
h logs nosuchapp
expect_rc "logs of an app with zero matching containers" 1

touch "$STATE/bad_id"
h restart shop
expect_rc "an unexpected container id from docker fails closed" 1
expect_eq "unexpected id: no docker mutation" "$(docker_mutations)" ""
rm -f "$STATE/bad_id"

touch "$STATE/docker_fail"
h restart shop
expect_rc "a docker failure fails the helper" 1
expect_eq "docker failure: no restart" "$(docker_mutations)" ""
rm -f "$STATE/docker_fail"

# a failing docker restart propagates as a non-zero exit and no success line is printed
touch "$STATE/restart_fail"
h restart shop
# shellcheck disable=SC2154 # rc is set by run_cmd in lib.sh
if [ "$rc" -ne 0 ]; then _pass; else _fail "a failing docker restart makes the helper exit non-zero" "rc=$rc"; fi
expect_out_lacks "a failing restart prints no success line" "restarted"
rm -f "$STATE/restart_fail"

# name-length boundaries: 2 and 31 characters reach docker (1 and 32 are rejected below)
h restart ab
expect_rc "2-character app accepted" 0
expect_calls_has "2-character app restarted by id" "docker restart 444444444444"
h restart "$app31"
expect_rc "31-character app accepted" 0
expect_calls_has "31-character app restarted by id" "docker restart 555555555555"
h logs "$app31" 3
expect_rc "31-character app accepted by logs" 0

# ---- environment: nothing from the caller reaches the root docker CLI ----
rm -f "$STATE/docker_env"
t_reset_calls
run_cmd env DOCKER_HOST=hostile-host DOCKER_CONTEXT=hostile-ctx DOCKER_CONFIG=/home/hostile/.docker HOME=/home/hostile PATH="/home/hostile/bin:$PATH" "$helper" ps
expect_rc "ps under a hostile environment" 0
expect_eq "docker sees no caller DOCKER_*, a root HOME and a fixed PATH" "$(cat "$STATE/docker_env")" "DOCKER_HOST=<unset> DOCKER_CONTEXT=<unset> HOME=/root DOCKER_CONFIG=/root/.docker PATH=/usr/sbin:/usr/bin:/sbin:/bin"

# ---- status: read-only ----
h status
expect_rc "status succeeds" 0
expect_out_has "status shows a unit state" "docker: active"
expect_out_has "status shows the firewall unit" "docker-user-firewall: active"
expect_out_has "status shows memory headroom" "Mem:"
expect_eq "status makes no docker call at all" "$(grep -c '^docker' "$CALL_LOG")" "0"
touch "$STATE/inactive_docker"
h status
expect_rc "status reports an inactive unit without failing" 0
expect_out_has "inactive unit shown" "docker: inactive"
rm -f "$STATE/inactive_docker"

# ---- invalid arguments, invoked directly: exit 2, no docker call ----
reject_case() {
  local label="$1"
  shift
  h "$@"
  expect_rc "reject: $label" 2
  expect_eq "reject no docker call: $label" "$(grep -c '^docker' "$CALL_LOG")" "0"
}
reject_case "no arguments"
reject_case "unknown subcommand" frobnicate
reject_case "empty subcommand" ""
reject_case "ps with an argument" ps shop
reject_case "stats with an argument" stats shop
reject_case "status with an argument" status shop
reject_case "restart with no app" restart
reject_case "restart with two apps" restart shop blog
reject_case "restart empty app" restart ""
reject_case "restart uppercase" restart Shop
reject_case "restart dash-leading" restart --all
reject_case "restart with a dot" restart sh.op
reject_case "restart with a slash" restart ../x
reject_case "restart with a space inside one argument" restart "shop blog"
reject_case "restart with a newline" restart $'shop\nblog'
reject_case "restart with a trailing newline" restart $'shop\n'
reject_case "restart with a command substitution" restart '$(id)'
reject_case "restart with a glob" restart '*'
reject_case "restart too short" restart a
reject_case "restart too long" restart "a$(printf 'b%.0s' $(seq 1 31))"
reject_case "restart unicode" restart "caf$(printf '\303\251')"
reject_case "logs no app" logs
reject_case "logs three args" logs shop 5 6
reject_case "logs bad app" logs "Shop"
reject_case "logs a docker flag as app" logs --since

# Rejections are logged with the reason only (no argument text).
h restart 'Bad$(ZQXL)'
expect_calls_has "reject is logged" "logger -t platform-claude-helper rejected reason=bad-app"
expect_calls_lacks "the rejected argument text is not logged" "ZQXL"

# Every accepted subcommand is logged, by name and counts only, never with the app name.
logger_lines() { grep '^logger ' "$CALL_LOG" || true; }
h ps
expect_eq "ps is logged" "$(logger_lines)" "logger -t platform-claude-helper ps"
h stats
expect_eq "stats is logged" "$(logger_lines)" "logger -t platform-claude-helper stats"
h status
expect_eq "status is logged" "$(logger_lines)" "logger -t platform-claude-helper status"
h logs shop
expect_eq "logs is logged without the app name" "$(logger_lines)" "logger -t platform-claude-helper logs lines=100"
h logs shop 7
expect_eq "logs with a line count is logged without the app name" "$(logger_lines)" "logger -t platform-claude-helper logs lines=7"
h restart shop
expect_eq "restart is logged without the app name" "$(logger_lines)" "logger -t platform-claude-helper restart"
h restart nosuchapp
expect_eq "a zero-match restart is logged without the app name" "$(logger_lines)" "$(printf '%s\n%s' 'logger -t platform-claude-helper restart' 'logger -t platform-claude-helper no-match sub=restart')"

# ---- APP_RE, LINES_RE and MAX_LINES are defined identically in the wrapper and the helper ----
for key in APP_RE LINES_RE MAX_LINES; do
  w="$(grep "^readonly $key=" "$here/claude-access.sh" || true)"
  hl="$(grep "^readonly $key=" "$source_script" || true)"
  if [ -n "$w" ]; then _pass; else _fail "claude-access.sh defines $key"; fi
  expect_eq "$key is textually identical in wrapper and helper" "$w" "$hl"
done

# ---- the tracked file ----
expect_eq "helper shebang is bash -p" "$(head -n1 "$source_script")" "#!/bin/bash -p"
if grep -qxF 'export LC_ALL=C' "$source_script"; then _pass; else _fail "helper exports LC_ALL=C"; fi
if grep -qxF 'unset "${!DOCKER_@}"' "$source_script"; then _pass; else _fail "helper unsets every DOCKER_* variable"; fi
expect_eq "no eval in the helper" "$(grep -cE '(^|[^a-z_])eval ' "$source_script")" "0"
expect_eq "no docker exec/run/rm in the helper" "$(grep -cE 'DOCKER\" (exec|run|rm|stop|kill)' "$source_script")" "0"

t_finish
