#!/usr/bin/env bash
# Pre-merge run of the pinned Traefik against dynamic.yml and the Traefik settings in compose.yaml.
#
# Needs docker; on a host without a usable docker daemon (CI has none) it skips with a loud notice. Run it once
# un-skipped on a docker host before merge.
#
# What it proves (the live host reconfirms it):
#   - the /_jobs deny never lets a request reach an app (shared table + variant list), with a positive control in
#     the same run, and a mutation pass proves the checks can fail;
#   - an unmatched host, an app 503 and an app 502 get the friendly page body with the status kept;
#   - the ping entrypoint is loopback-only (a sibling container is refused) and Traefik's own healthcheck works;
#   - the access log has no cookie value and no query string, and keeps Cf-Connecting-Ip.
#
# Traefik's settings come from compose.yaml (never retyped here). Only three entries are replaced for the run: the
# Docker provider network (a throwaway network, never `platform`), its endpoint (the test-owned Docker socket
# path, INGRESS_TEST_DOCKER_SOCK, default /var/run/docker.sock) and the domain value (a fake domain).
# Everything else is used verbatim and asserted unchanged. No host port is published; requests go straight to the
# container address on the throwaway network. All containers and the network are removed on every exit path.
#
# Usage: test_traefik_dynamic.sh [--record]
#   --record  rewrite the "variant | code" block in dynamic.yml with the observed codes instead of checking it.
#
# Hints:
#   manifest unknown on pull        -> recheck the tag and digest in compose.yaml
#   port in use                     -> nothing is published here; a leftover container from a killed run may be
#                                      holding the network: docker ps -a --filter label=ingress-test
#   positive control failed         -> the dummy backend or Host header is wrong, so the deny results prove nothing
# shellcheck disable=SC1091,SC2015
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
# shellcheck source=yaml-subset.sh
. "$here/yaml-subset.sh"

record=0
case "${1:-}" in
  "") ;;
  --record) record=1 ;;
  *) echo "usage: $0 [--record]" >&2; exit 2 ;;
esac

skip() {
  echo "################################################################"
  echo "## $(basename "$0") SKIPPED: $1"
  echo "## The pre-merge Traefik check did NOT run. Run it on a docker host before merge."
  echo "################################################################"
  exit 0
}

command -v docker >/dev/null 2>&1 || skip "docker is not installed"
docker info >/dev/null 2>&1 || skip "the docker daemon is not reachable by this user"
command -v curl >/dev/null 2>&1 || skip "curl is not installed"

t_init

sock="${INGRESS_TEST_DOCKER_SOCK:-/var/run/docker.sock}"
[ -S "$sock" ] || skip "no Docker socket at $sock (set INGRESS_TEST_DOCKER_SOCK)"
sockgid="$(stat -c %g "$sock")"

rid="ingt-$$"
net="$rid-net"
fake_domain="example.test"
friendly="This app is down or does not exist"
tname="$rid-traefik"
aname="$rid-app"
fname="$rid-fail503"
gname="$rid-gone"
dname="$rid-down"
long_app="a-very-long-application-name-used-to-outrank-small-priorities"
apphost="$long_app.$fake_domain"

cleanup() {
  local ids
  ids="$(docker ps -aq --filter "label=ingress-test=$rid" 2>/dev/null)"
  # shellcheck disable=SC2086
  [ -z "$ids" ] || docker rm -f $ids >/dev/null 2>&1
  docker network rm "$net" >/dev/null 2>&1
  t_cleanup
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---- read the stack definition ----

flat="$T_TMP/compose-flat"
if ! ys_flatten < "$here/compose.yaml" > "$flat"; then
  echo "FAIL: compose.yaml is outside the YAML subset the tests understand"
  exit 1
fi

timage="$(ys_get "$flat" services/traefik/image)"
pimage="$(ys_get "$flat" services/down-page/image)"
tuser="$(ys_get "$flat" services/traefik/user)"
tvol="$(ys_list "$flat" services/traefik/volumes | head -n 1)"
tvol_target="${tvol#*:}"

declare -A envv=()
env_keys=()
while IFS= read -r k; do
  env_keys+=("$k")
  v="$(ys_get "$flat" "services/traefik/environment/$k")"
  # shellcheck disable=SC2016
  envv["$k"]="${v//'${PLATFORM_DOMAIN}'/$fake_domain}"
done < <(ys_children "$flat" services/traefik/environment)

declare -A orig=()
for k in "${env_keys[@]}"; do orig["$k"]="${envv[$k]}"; done

if ys_has "$flat" services/traefik/command; then
  echo "FAIL: the traefik service has command arguments, which make Traefik ignore its TRAEFIK_ environment"
  exit 1
fi

mapfile -t hc < <(ys_list "$flat" services/traefik/healthcheck/test)
hc_cmd="${hc[*]:1}"

# The three entries this run replaces (everything else is verbatim).
envv[TRAEFIK_PROVIDERS_DOCKER_NETWORK]="$net"
envv[TRAEFIK_PROVIDERS_DOCKER_ENDPOINT]="unix:///var/run/docker.sock"
changed=""
for k in "${env_keys[@]}"; do
  [ "${envv[$k]}" = "${orig[$k]}" ] || changed="$changed $k"
done
# The domain substitution is part of `orig` already; the replaced pair is network + endpoint.
# shellcheck disable=SC2086
expect_eq "only the Docker network and endpoint are replaced" "$(printf '%s\n' $changed | sort | tr '\n' ' ')" \
  "TRAEFIK_PROVIDERS_DOCKER_ENDPOINT TRAEFIK_PROVIDERS_DOCKER_NETWORK "

# ---- helpers ----

reasons=()
note() { reasons+=("$1"); }

req_code=""
req_body=""
# req <host> <path> [curl args...]
req() {
  local host="$1" path="$2"
  shift 2
  req_code="$(curl -sg --max-time 15 --path-as-is -o "$T_TMP/body" -w '%{http_code}' -H "Host: $host" "$@" "http://$tip$path")" || true
  req_body="$(cat "$T_TMP/body" 2>/dev/null || true)"
}

backend_hits() { docker logs "$aname" 2>&1 | grep -c 'url:' || true; }

ip_of() { docker inspect -f "{{(index .NetworkSettings.Networks \"$net\").IPAddress}}" "$1"; }

start_traefik() {
  local dyn="$1" k
  shift
  docker rm -f "$tname" >/dev/null 2>&1
  local flags=()
  for k in "${env_keys[@]}"; do flags+=(-e "$k=${envv[$k]}"); done
  docker run -d --name "$tname" --label "ingress-test=$rid" --network "$net" \
    --user "$tuser" --group-add "$sockgid" --cap-drop ALL --security-opt no-new-privileges:true --read-only \
    --health-cmd "$hc_cmd" --health-interval 2s --health-start-period 2s --health-retries 3 \
    -v "$sock:/var/run/docker.sock" -v "$dyn:$tvol_target" "${flags[@]}" "$timage" >"$T_TMP/traefik-id" 2>"$T_TMP/traefik-err" \
    || { cat "$T_TMP/traefik-err"; return 1; }
  tip="$(ip_of "$tname")"
  for _ in $(seq 1 60); do
    req "$apphost" /ok
    [ "$req_code" = 200 ] && return 0
    sleep 0.5
  done
  echo "positive control did not reach the backend: Traefik not routing, check the provider network"
  docker logs "$tname" 2>&1 | tail -n 20
  return 1
}

mutated_dyn() {
  # mutated_dyn <name> <sed-or-awk-kind>: copy dynamic.yml into $T_TMP/dyn-<name>/ with one mutation applied.
  local name="$1" dir="$T_TMP/dyn-$1"
  mkdir -p "$dir"
  case "$name" in
    plain) cp "$here/dynamic.yml" "$dir/dynamic.yml" ;;
    no-deny) awk '/^    jobs-deny:/ { skip = 1; next } /^    catch-all:/ { skip = 0 } !skip' "$here/dynamic.yml" > "$dir/dynamic.yml" ;;
    case-sensitive) sed 's/(?i)//' "$here/dynamic.yml" > "$dir/dynamic.yml" ;;
    low-priority) sed 's/priority: 2147483646/priority: 5/' "$here/dynamic.yml" > "$dir/dynamic.yml" ;;
  esac
  if [ "$name" != plain ] && cmp -s "$here/dynamic.yml" "$dir/dynamic.yml"; then
    echo "mutation $name did not change dynamic.yml" >&2
    return 1
  fi
  printf '%s' "$dir"
}

# check_reach <label> <host> <path> <reach|noreach>: note a reason when the backend log disagrees.
check_reach() {
  local label="$1" host="$2" path="$3" want="$4" before after
  before="$(backend_hits)"
  req "$host" "$path"
  after="$(backend_hits)"
  if [ "$want" = noreach ] && [ "$after" -gt "$before" ]; then
    note "a /_jobs variant reached the backend: $label ($path, status $req_code)"
  elif [ "$want" = reach ] && [ "$after" -eq "$before" ]; then
    note "a path outside /_jobs did not reach the backend: $label ($path, status $req_code)"
  fi
}

table_rows() { grep -vE '^[[:space:]]*(#|$)' "$here/jobs-paths.table"; }

deny_table_check() {
  local kind path
  while read -r kind path; do
    if [ "$kind" = match ]; then check_reach "table" "$apphost" "$path" noreach
    else check_reach "table" "$apphost" "$path" reach; fi
  done < <(table_rows)
}

variants=(
  "exact|/_jobs|norm"
  "sub|/_jobs/x|norm"
  "enc-underscore|/%5Fjobs/x|norm"
  "double-slash|//_jobs/x|norm"
  "dot-segments|/a/../_jobs/x|norm"
  "semicolon|/_jobs/;x|norm"
  "upper|/_JOBS/x|norm"
  "mixed-case|/_Jobs|norm"
  "enc-slash|/_jobs%2Fx|enc"
  "enc-backslash|/_jobs%5Cx|enc"
  "enc-semicolon|/_jobs%3Bx|enc"
  "enc-percent|/_jobs%25x|enc"
  "enc-question|/_jobs%3Fx|enc"
  "enc-hash|/_jobs%23x|enc"
  "enc-null|/_jobs%00x|enc"
)
declare -A observed=()

variant_check() {
  local spec name path class before after
  for spec in "${variants[@]}"; do
    IFS='|' read -r name path class <<<"$spec"
    before="$(backend_hits)"
    req "$apphost" "$path"
    after="$(backend_hits)"
    observed["$name"]="$req_code"
    [ "$after" -gt "$before" ] && note "a /_jobs variant reached the backend: $name ($path, status $req_code)"
    if [ "$class" = norm ]; then
      [ "$req_code" = 503 ] || note "variant $name: status $req_code, want 503"
      [[ "$req_body" == *"$friendly"* ]] || note "variant $name: no friendly body"
    else
      case "$req_code" in
        400) ;;
        503) [[ "$req_body" == *"$friendly"* ]] || note "variant $name: 503 without the friendly body" ;;
        *) note "variant $name: status $req_code, want 400 or 503" ;;
      esac
    fi
  done
}

ping_isolation_check() {
  local out
  out="$(docker run --rm --label "ingress-test=$rid" --network "$net" "$pimage" wget -T 3 -q -O- "http://$tip:8082/ping" 2>&1)" && rc_ok=1 || rc_ok=0
  if [ "$rc_ok" = 1 ] || [[ "$out" != *"Connection refused"* ]]; then
    note "the ping port is reachable from a sibling container (got: ${out:-nothing})"
  fi
}

# expect_mutation_fails <label> <reason-substring>
expect_mutation_fails() {
  local label="$1" want="$2" r
  for r in "${reasons[@]}"; do
    if [[ "$r" == *"$want"* ]]; then _pass; return 0; fi
  done
  _fail "mutation '$label' was not caught" "wanted a reason containing: $want; got: ${reasons[*]:-none}"
}

# ---- images and throwaway network ----

for img in "$timage" "$pimage"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    docker pull -q "$img" >/dev/null 2>"$T_TMP/pull-err" || { echo "FAIL: pull $img"; cat "$T_TMP/pull-err"; exit 1; }
  fi
done
docker network create --label "ingress-test=$rid" "$net" >/dev/null || { echo "FAIL: network create"; exit 1; }

page_dir="$T_TMP/www-down"
mkdir -p "$page_dir"
cp "$here/down-page/index.html" "$page_dir/index.html"
app_dir="$T_TMP/www-app"
mkdir -p "$app_dir"
printf 'app ok\n' > "$app_dir/index.html"
printf 'app ok\n' > "$app_dir/ok"

mapfile -t down_cmd < <(ys_list "$flat" services/down-page/command)
down_user="$(ys_get "$flat" services/down-page/user)"

docker run -d --name "$dname" --label "ingress-test=$rid" --network "$net" --network-alias down-page \
  --user "$down_user" --read-only -v "$page_dir:/www:ro" "$pimage" "${down_cmd[@]}" >/dev/null || { echo "FAIL: start down-page"; exit 1; }
docker run -d --name "$aname" --label "ingress-test=$rid" --label "platform.app=$long_app" --network "$net" --expose 8080 \
  --user 65534:65534 -v "$app_dir:/www:ro" "$pimage" httpd -f -vv -p 8080 -h /www >/dev/null || { echo "FAIL: start app"; exit 1; }
docker run -d --name "$fname" --label "ingress-test=$rid" --label "platform.app=fails" --network "$net" --expose 8080 \
  --user 65534:65534 "$pimage" sh -c 'while true; do printf "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 4\r\nConnection: close\r\n\r\nnope" | nc -l -p 8080; done' >/dev/null \
  || { echo "FAIL: start 503 app"; exit 1; }
docker run -d --name "$gname" --label "ingress-test=$rid" --label "platform.app=gone" --network "$net" --expose 8080 \
  --user 65534:65534 -v "$app_dir:/www:ro" "$pimage" sh -c 'httpd -f -p 8080 -h /www & while :; do sleep 1; done' >/dev/null \
  || { echo "FAIL: start stopped-listener app"; exit 1; }

# ---- main run: unmutated config ----

dyn_plain="$(mutated_dyn plain)"
if ! start_traefik "$dyn_plain"; then
  echo "FAIL: Traefik did not start or route (positive control)"
  exit 1
fi
_pass

reasons=()
deny_table_check
variant_check
expect_eq "deny table and variants: nothing reaches the backend, outcomes as defined" "${reasons[*]:-}" ""
[ "${#reasons[@]}" -eq 0 ] || printf '  reason: %s\n' "${reasons[@]}"

# Recorded per-variant codes in the dynamic.yml header.
block_file="$T_TMP/observed-block"
for spec in "${variants[@]}"; do
  IFS='|' read -r name _ _ <<<"$spec"
  printf '# %s | %s\n' "$name" "${observed[$name]:-none}"
done > "$block_file"
if [ "$record" = 1 ]; then
  awk -v blk="$block_file" '
    /^# variants-begin$/ { print; print "# variant | code"; while ((getline l < blk) > 0) print l; skip = 1; next }
    /^# variants-end$/ { skip = 0 }
    !skip { print }
  ' "$here/dynamic.yml" > "$T_TMP/dynamic-recorded" && cp "$T_TMP/dynamic-recorded" "$here/dynamic.yml"
  echo "recorded the observed variant codes in dynamic.yml"
else
  recorded="$(awk '/^# variants-begin$/ { on = 1; next } /^# variants-end$/ { on = 0 } on && !/^# variant \| code$/' "$here/dynamic.yml")"
  expect_eq "dynamic.yml header records the observed per-variant codes (run with --record to update)" "$recorded" "$(cat "$block_file")"
fi

# Unmatched host: 503 from Traefik with the friendly body, any path and method.
for p in / /x/y /_jobs /api/rawdata; do
  for m in GET POST DELETE; do
    req "nosuch.$fake_domain" "$p" -X "$m"
    expect_eq "unmatched host $m $p: status" "$req_code" 503
    [[ "$req_body" == *"$friendly"* ]] && _pass || _fail "unmatched host $m $p: friendly body missing"
  done
done

# App-originated failures keep their status and get the friendly body.
req "fails.$fake_domain" /
expect_eq "app 503: status preserved" "$req_code" 503
[[ "$req_body" == *"$friendly"* && "$req_body" != *nope* ]] && _pass || _fail "app 503: body not replaced by the friendly page"
docker exec "$gname" pkill -x httpd
sleep 1
req "gone.$fake_domain" /
expect_eq "stopped listener: Traefik 502 preserved" "$req_code" 502
[[ "$req_body" == *"$friendly"* ]] && _pass || _fail "stopped listener: friendly body missing"

# The down-page service answers 200 directly.
dip="$(ip_of "$dname")"
for p in / /index.html; do
  c="$(curl -s --max-time 10 -o "$T_TMP/body" -w '%{http_code}' "http://$dip:8080$p")" || true
  expect_eq "direct hit on down-page $p" "$c" 200
  grep -qF "$friendly" "$T_TMP/body" && _pass || _fail "direct hit on down-page $p: page body missing"
done

# Ping: loopback only, healthcheck works, routes nothing.
for _ in $(seq 1 30); do
  st="$(docker inspect -f '{{.State.Health.Status}}' "$tname" 2>/dev/null)"
  [ "$st" = healthy ] && break
  sleep 1
done
expect_eq "traefik container reaches healthy via the compose healthcheck" "${st:-}" healthy
out="$(docker exec "$tname" wget -q -O- http://127.0.0.1:8082/ping 2>&1)"
expect_eq "ping answers on loopback inside the container" "$out" OK
docker exec "$tname" wget -q -O- http://127.0.0.1:8082/api/rawdata >/dev/null 2>&1 && _fail "ping entrypoint routes /api/rawdata" || _pass
docker exec "$tname" wget -q -O- http://127.0.0.1:8082/ >/dev/null 2>&1 && _fail "ping entrypoint routes /" || _pass
docker exec "$tname" wget -q -O- http://127.0.0.1:8080/api/rawdata >/dev/null 2>&1 && _fail "an API listens on 8080" || _pass
reasons=()
ping_isolation_check
expect_eq "ping port refuses a sibling container" "${reasons[*]:-}" ""

# Access log: no cookie value, no query string, Cf-Connecting-Ip kept.
cookie_val="session$(printf '%s' abc123 | tr '[:lower:]' '[:upper:]')"
query_val="qs$(printf '%s' xyz789)"
client_val="client-$$-marker"
req "$apphost" "/ok?token=$query_val" -H "Cookie: sid=$cookie_val" -H "Cf-Connecting-Ip: $client_val"
sleep 1
docker logs "$tname" > "$T_TMP/traefik-log" 2>&1
grep -qF "$cookie_val" "$T_TMP/traefik-log" && _fail "access log leaks the Cookie value" || _pass
grep -qF "$query_val" "$T_TMP/traefik-log" && _fail "access log leaks the query string" || _pass
grep -qF "$client_val" "$T_TMP/traefik-log" && _pass || _fail "access log lost Cf-Connecting-Ip"

# No recursion: with the page service gone the response is bounded.
docker stop -t 1 "$dname" >/dev/null
start="$(date +%s)"
req "nosuch.$fake_domain" /
elapsed=$(( $(date +%s) - start ))
case "$req_code" in 502|503|504) _pass ;; *) _fail "page service down: status $req_code, want a bounded 502 to 504" ;; esac
[ "$elapsed" -lt 15 ] && _pass || _fail "page service down: response took ${elapsed}s (loop?)"
docker start "$dname" >/dev/null

# ---- mutation pass: each mutated run must fail with a named reason ----

for m in no-deny case-sensitive low-priority; do
  dyn="$(mutated_dyn "$m")" || { _fail "mutation $m could not be built"; continue; }
  if ! start_traefik "$dyn"; then _fail "mutation $m: Traefik did not start"; continue; fi
  reasons=()
  deny_table_check
  expect_mutation_fails "$m" "a /_jobs variant reached the backend"
done

envv[TRAEFIK_ENTRYPOINTS_PING_ADDRESS]="0.0.0.0:8082"
if start_traefik "$dyn_plain"; then
  reasons=()
  ping_isolation_check
  expect_mutation_fails "ping bound to 0.0.0.0" "the ping port is reachable from a sibling container"
else
  _fail "mutation ping-wide: Traefik did not start"
fi

t_finish
