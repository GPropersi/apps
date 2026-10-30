#!/usr/bin/env bash
# Static checks for the ingress stack (compose.yaml, dynamic.yml, down-page/, jobs-paths.table, env.example).
# Offline and fast: no docker. Each security property has a mutation case: a mutated copy of the stack must fail
# with a named reason, and the unmutated tree must pass.
#
# compose.yaml and dynamic.yml are read with yaml-subset.sh, which refuses anything outside a small regular YAML
# subset, so a file that drifts out of what the tests understand fails here instead of being misread.
#
# Dialect translation for the offline deny-regex table: Traefik matches PathRegexp with Go RE2. The offline
# matcher is grep -E. The only RE2 construct the rule may use beyond plain ERE is a leading inline (?i) flag,
# translated to grep -i. Any other "(?" construct, backslash escape or character outside the allowed set makes the
# check fail closed (cannot translate). test_traefik_dynamic.sh drives the same table through the real Traefik.
# shellcheck disable=SC1091,SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
# shellcheck source=../lib/yaml-subset.sh
. "$here/../lib/yaml-subset.sh"

t_init
host_readme="$(cd "$here/../host" && pwd)/README.md"

services="cloudflared down-page socket-proxy traefik"
declare -A svc_nets=(
  [cloudflared]="platform"
  [traefik]="platform ingress-proxy"
  [down-page]="platform"
  [socket-proxy]="ingress-proxy"
)

# The exact Traefik settings, all in the traefik service's environment (never in command).
declare -A want=(
  [TRAEFIK_GLOBAL_CHECKNEWVERSION]=false
  [TRAEFIK_GLOBAL_SENDANONYMOUSUSAGE]=false
  [TRAEFIK_LOG_FORMAT]=json
  [TRAEFIK_LOG_LEVEL]=INFO
  [TRAEFIK_ENTRYPOINTS_WEB_ADDRESS]=:80
  [TRAEFIK_ENTRYPOINTS_WEB_ASDEFAULT]=true
  [TRAEFIK_ENTRYPOINTS_WEB_HTTP_MIDDLEWARES]=errors@file
  [TRAEFIK_ENTRYPOINTS_WEB_HTTP_ALIASHEADERSSTRATEGY]=delete
  [TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDSLASH]=false
  [TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDBACKSLASH]=false
  [TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDNULLCHARACTER]=false
  [TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDSEMICOLON]=false
  [TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDPERCENT]=false
  [TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDQUESTIONMARK]=false
  [TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDHASH]=false
  [TRAEFIK_PING]=true
  [TRAEFIK_PING_ENTRYPOINT]=ping
  [TRAEFIK_ENTRYPOINTS_PING_ADDRESS]=127.0.0.1:8082
  [TRAEFIK_PROVIDERS_DOCKER_ENDPOINT]=tcp://socket-proxy:2375
  [TRAEFIK_PROVIDERS_DOCKER_NETWORK]=platform
  [TRAEFIK_PROVIDERS_DOCKER_EXPOSEDBYDEFAULT]=true
  [TRAEFIK_PROVIDERS_DOCKER_CONSTRAINTS]='LabelRegex(`platform.app`, `.+`)'
  [TRAEFIK_PROVIDERS_DOCKER_DEFAULTRULE]='Host(`{{ index .Labels "platform.app" }}.${PLATFORM_DOMAIN}`)'
  [TRAEFIK_PROVIDERS_FILE_DIRECTORY]=/etc/traefik/dynamic
  [TRAEFIK_PROVIDERS_FILE_WATCH]=true
  [TRAEFIK_ACCESSLOG]=true
  [TRAEFIK_ACCESSLOG_FORMAT]=json
  [TRAEFIK_ACCESSLOG_FIELDS_HEADERS_DEFAULTMODE]=drop
  [TRAEFIK_ACCESSLOG_FIELDS_HEADERS_NAMES_Cf-Connecting-Ip]=keep
  [TRAEFIK_ACCESSLOG_FIELDS_QUERYPARAMETERS_DEFAULTMODE]=drop
)

# What each Traefik option means, for the failure reason.
traefik_option_name() {
  case "$1" in
    TRAEFIK_API*) echo "API/dashboard must stay off" ;;
    *SANITIZEPATH*) echo "sanitizePath must stay on" ;;
    *ENCODEDCHARACTERS*) echo "every encodedCharacters option must be explicitly false" ;;
    *PING*) echo "ping setting" ;;
    *FORWARDEDHEADERS*) echo "forwardedHeaders must stay untrusted" ;;
    TRAEFIK_ACCESSLOG_FIELDS_HEADERS_NAMES_*) echo "access log keeps a header other than Cf-Connecting-Ip" ;;
    *ACCESSLOG*) echo "access-log privacy option" ;;
    *CONSTRAINTS*) echo "provider constraint" ;;
    *DEFAULTRULE*) echo "defaultRule" ;;
    *EXPOSEDBYDEFAULT*) echo "exposedByDefault" ;;
    *MIDDLEWARES*) echo "errors@file must be in the web entrypoint middlewares" ;;
    *ENTRYPOINTS*) echo "entrypoint (only web is routed, plus the loopback ping)" ;;
    *) echo "traefik option" ;;
  esac
}

# Exact request-path regexes for the socket proxy ($$ is Compose's escape for a literal $).
re_get='^(/v[0-9]+\.[0-9]+)?/(version|containers/json|containers/[a-zA-Z0-9]+/json|events)$'
re_head='^(/v[0-9]+\.[0-9]+)?/_ping$'
# Characters the deny rule may use after the optional leading (?i) (everything else fails closed).
re_ok='^[]A-Za-z0-9_/;^$()|*+?.[-]*$'

# ---- no-secrets scan ----

# Explicit exclusions for the hostname shape (a dotted name whose last label is letters only). Nothing else is
# excused: the registry host of an image reference, the label name, the fake example domain, and file names.
host_registry="docker.io"
host_label="platform.app"
host_fake="example.test"
host_files=" env.example lib.sh yaml-subset.sh test_ingress_stack.sh test_traefik_dynamic.sh test_lib.sh README.md "
# File names that platform/host/README.md mentions.
host_files="$host_files platform.sh login-shell.sh install-deploy-user.sh claude-access.sh claude-helper.sh install-claude-access.sh install-ingress.sh "
host_files="$host_files install-backup.sh restore.sh backup.sh platform-backup.service platform-backup.timer RUNBOOK.md "
host_files="$host_files install-data.sh install-jobs.sh jobs-redis.password new-db.sh pg_hba.conf redis-entrypoint.sh postgres-admin.password redis-admin.password "
host_files="$host_files verify-egress.sh verify-ingress.sh server-host-base.sh authorized_keys.d egress-deny.cidrs egress-allow.cidrs "
host_files="$host_files docker-user.rules.bak docker-user.rules docker-user-firewall.service "
# Docker inspect template fields used by test_traefik_dynamic.sh.
host_files="$host_files NetworkSettings.Networks State.Health.Status "
host_exts=" yml yaml html table env token sock json txt tsv "

hostname_ok() {
  local t="$1" last="${1##*.}"
  [[ "$last" =~ ^[A-Za-z]+$ ]] || return 0
  [ "$t" = "$host_registry" ] && return 0
  [ "$t" = "$host_label" ] && return 0
  [ "$t" = "$host_fake" ] && return 0
  [[ "$t" == *".$host_fake" ]] && return 0
  [[ "$host_files" == *" $t "* ]] && return 0
  [[ "$host_exts" == *" $last "* ]] && return 0
  return 1
}

# scan_file <file>: print the shape name for each kind of secret-shaped value found.
scan_file() {
  local f="$1" content t
  content="$(sed -E 's/sha256:[0-9a-f]{64}/sha256:DIGEST/g' "$f")"
  grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' <<<"$content" && echo "email shape"
  grep -qE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' <<<"$content" && echo "UUID shape"
  grep -qE 'eyJ[A-Za-z0-9_-]{3,}' <<<"$content" && echo "eyJ token prefix"
  grep -qE '[0-9a-fA-F]{32,}' <<<"$content" && echo "32+ hex run"
  local ln
  while IFS=: read -r ln t; do
    hostname_ok "$t" || echo "hostname shape (not allow-listed) at line $ln"
  done < <(grep -noE '[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+' <<<"$content")
}

# ---- the checks ----

REASONS=()
r() { REASONS+=("$*"); }

contains_word() { [[ " $2 " == *" $1 "* ]]; }

# run_checks <stack-dir> <extra-scan-file>: fill REASONS (empty means the stack passes).
run_checks() {
  local dir="$1" extra="$2" cf df s k v i got got_nets want_nets
  REASONS=()
  cf="$T_TMP/c-flat"
  df="$T_TMP/d-flat"
  local err
  err="$(ys_flatten < "$dir/compose.yaml" 2>&1 > "$cf")" || { r "compose.yaml is outside the YAML subset the test understands: $err"; : > "$cf"; }
  err="$(ys_flatten < "$dir/dynamic.yml" 2>&1 > "$df")" || { r "dynamic.yml is outside the YAML subset the test understands: $err"; : > "$df"; }

  # -- service set
  got="$(ys_children "$cf" services | sort | tr '\n' ' ')"
  [ "$got" = "$services " ] || r "service set is not exactly: $services (got: $got)"

  # -- per service: pinned image, no published ports or privilege, hardening, no platform.app label
  for s in $services; do
    contains_word "$s" "$got" || continue
    v="$(ys_get "$cf" "services/$s/image")"
    if ! [[ "$v" =~ ^[a-z0-9.-]+/[a-z0-9._/-]+:v?[0-9]+\.[0-9]+(\.[0-9]+)?@sha256:[0-9a-f]{64}$ ]]; then
      r "$s: image '$v' is not fully qualified with an exact tag and a sha256 digest (floating or unpinned)"
    fi
    for k in ports privileged network_mode cap_add; do
      ys_has "$cf" "services/$s/$k" && r "$s: $k is not allowed"
    done
    ys_list "$cf" "services/$s/cap_drop" | grep -qxF ALL || r "$s: cap_drop must contain ALL"
    [ -n "$(ys_get "$cf" "services/$s/mem_limit")" ] || r "$s: mem_limit must be set"
    [ "$(ys_get "$cf" "services/$s/restart")" = unless-stopped ] || r "$s: restart must be unless-stopped"
    ys_list "$cf" "services/$s/security_opt" | grep -qxF no-new-privileges:true || r "$s: security_opt must contain no-new-privileges:true"
    [ "$(ys_get "$cf" "services/$s/read_only")" = true ] || r "$s: read_only must be true"
    ys_list "$cf" "services/$s/healthcheck/test" | grep -q . || r "$s: a healthcheck is required"
    if grep -F "services/$s/labels" "$cf" | grep -qF 'platform.app'; then
      r "$s: carries a platform.app label (no service in the ingress stack may)"
    fi
    if [ "$s" != socket-proxy ] && ys_list "$cf" "services/$s/volumes" | grep -qF docker.sock; then
      r "$s: the Docker socket is mounted on a service other than socket-proxy"
    fi
    got_nets="$(ys_list "$cf" "services/$s/networks" | sort | tr '\n' ' ')"
    want_nets="$(tr ' ' '\n' <<<"${svc_nets[$s]}" | sort | tr '\n' ' ')"
    [ "$got_nets" = "$want_nets" ] || r "$s: networks are '$got_nets', want '$want_nets'"
    if awk -F '\t' -v pre="services/$s/" 'index($1, pre) == 1 && ($2 ~ /eyJ/ || ($1 ~ /\/command\[\]$/ && $2 ~ /^(--token|-t)(=|$)/)) { f = 1 } END { exit f ? 0 : 1 }' "$cf"; then
      r "$s: an inline token (environment value or command argument)"
    fi
  done
  ys_has "$cf" services/cloudflared/environment/TUNNEL_TOKEN && r "cloudflared: an inline token (TUNNEL_TOKEN must come from the token file)"

  # -- networks
  [ "$(ys_get "$cf" networks/platform/external)" = true ] || r "network platform must be external: true"
  [ "$(ys_get "$cf" networks/ingress-proxy/internal)" = true ] || r "ingress-proxy must be internal: true"
  [ "$(ys_children "$cf" networks | sort | tr '\n' ' ')" = "ingress-proxy platform " ] || r "unexpected network set"
  for k in ipam enable_ipv6 driver_opts; do
    { ys_has "$cf" "networks/platform/$k" || ys_has "$cf" "networks/ingress-proxy/$k"; } && r "networks: $k is not allowed (no subnet or address literals, IPv6 off)"
  done

  # -- cloudflared
  v="$(ys_get "$cf" services/cloudflared/user)"
  if ! [[ "$v" =~ ^[1-9][0-9]*:[0-9]+$ ]]; then r "cloudflared user '$v' must be a fixed non-root uid:gid"; fi
  ys_list "$cf" services/cloudflared/group_add | grep -qE '^[0-9]+$' || r "cloudflared group_add must hold the token group's numeric gid"
  [ -n "$(ys_get "$cf" services/cloudflared/environment/TUNNEL_TOKEN_FILE)" ] || r "cloudflared must read its token from TUNNEL_TOKEN_FILE"
  ys_list "$cf" services/cloudflared/command | grep -qxF -- --no-autoupdate || r "cloudflared must run with --no-autoupdate"
  [[ "$(ys_get "$cf" services/cloudflared/environment/TUNNEL_METRICS)" == 127.0.0.1:* ]] || r "cloudflared metrics address must be set in its environment on loopback"
  ys_list "$cf" services/cloudflared/volumes | grep -qE '^/etc/platform/cloudflared\.token:[^:]+:ro$' || r "cloudflared must mount the host token file read-only"
  ys_list "$cf" services/cloudflared/healthcheck/test | grep -qxF ready || r "cloudflared healthcheck must be the ready check"

  # -- socket-proxy
  ys_list "$cf" services/socket-proxy/volumes | grep -qxF '/var/run/docker.sock:/var/run/docker.sock:ro' || r "socket-proxy must mount the Docker socket read-only"
  ys_list "$cf" services/socket-proxy/group_add | grep -qxF '${DOCKER_GID}' || r "socket-proxy group_add must be the installer-derived DOCKER_GID"
  ys_list "$cf" services/socket-proxy/command > "$T_TMP/sp-args"
  grep -qxF -- '-allowfrom=traefik' "$T_TMP/sp-args" || r "socket-proxy allowfrom must be the traefik service only"
  grep -qxF -- '-allowhealthcheck' "$T_TMP/sp-args" || r "socket-proxy must run with -allowhealthcheck (its /healthcheck probe needs it)"
  grep -qxF -- "-allowGET=${re_get//\$/\$\$}" "$T_TMP/sp-args" || r "socket-proxy GET allowlist is not the exact expected regex"
  grep -qxF -- "-allowHEAD=${re_head//\$/\$\$}" "$T_TMP/sp-args" || r "socket-proxy HEAD allowlist is not the exact expected regex"
  grep -iE '^-allow(CONNECT|DELETE|OPTIONS|PATCH|POST|PUT|TRACE)' "$T_TMP/sp-args" | grep -q . && r "socket-proxy allows a method other than GET and HEAD"
  while IFS= read -r i; do
    case "$i" in
      -listenip=0.0.0.0|-allowfrom=traefik|-allowhealthcheck|-watchdoginterval=*) ;;
      -allowGET=*|-allowHEAD=*) ;;
      *) r "socket-proxy: unexpected argument '$i'" ;;
    esac
  done < "$T_TMP/sp-args"
  local pth get_re head_re
  get_re="$(grep -m1 -- '^-allowGET=' "$T_TMP/sp-args" | sed -e 's/^-allowGET=//' -e 's/\$\$/$/')"
  head_re="$(grep -m1 -- '^-allowHEAD=' "$T_TMP/sp-args" | sed -e 's/^-allowHEAD=//' -e 's/\$\$/$/')"
  for pth in /version /v1.43/version /containers/json /v1.43/containers/json /containers/abc123/json /v1.43/containers/abc123/json /events /v1.43/events; do
    grep -qE -e "$get_re" <<<"$pth" || r "socket-proxy GET regex rejects $pth"
  done
  for pth in /containers/abc123/exec /containers/abc123/logs /containers/abc123/json/x /containers/abc123/json/ /images/json /containers/create /info /_ping /v1.43/containers/abc123/archive; do
    grep -qE -e "$get_re" <<<"$pth" && r "socket-proxy GET regex allows $pth"
  done
  grep -qE -e "$head_re" <<<"/v1.43/_ping" || r "socket-proxy HEAD regex rejects /_ping"
  grep -qE -e "$head_re" <<<"/version" && r "socket-proxy HEAD regex allows /version"
  [[ "$(ys_get "$cf" services/socket-proxy/user)" =~ ^[1-9][0-9]*:[0-9]+$ ]] || r "socket-proxy must run as a fixed non-root user"

  # -- down-page
  ys_list "$cf" services/down-page/healthcheck/test | tr '\n' ' ' | grep -qE '(^| )nc -z ' || r "down-page healthcheck must be the TCP-connect form (nc -z)"
  [[ "$(ys_get "$cf" services/down-page/user)" =~ ^[1-9][0-9]*:[0-9]+$ ]] || r "down-page must run as a fixed non-root user"

  # -- traefik: no socket, no command, every option exact and in the environment
  ys_list "$cf" services/traefik/volumes | grep -qE 'docker\.sock|^/var/run' && r "traefik: the Docker socket must not be mounted on traefik"
  [[ "$(ys_get "$cf" services/traefik/user)" =~ ^[1-9][0-9]*:[0-9]+$ ]] || r "traefik must run as a fixed non-root user"
  if ys_has "$cf" services/traefik/command; then
    r "traefik has command arguments: any flag makes Traefik ignore its TRAEFIK_ environment"
    ys_list "$cf" services/traefik/command | grep -qiE -- '--(ping|entrypoints\.ping)' && r "ping setting in command (it must be a TRAEFIK_ environment variable shared with the healthcheck)"
  fi
  ys_list "$cf" services/traefik/healthcheck/test | tr '\n' ' ' | grep -qxF 'CMD traefik healthcheck ' \
    || r "traefik healthcheck must be exactly: traefik healthcheck (the --ping flag would ignore the environment)"
  local -a keys
  mapfile -t keys < <(ys_children "$cf" services/traefik/environment)
  for k in "${!want[@]}"; do
    if ! ys_has "$cf" "services/traefik/environment/$k"; then
      r "traefik option $k is missing ($(traefik_option_name "$k"))"
      continue
    fi
    v="$(ys_get "$cf" "services/traefik/environment/$k")"
    [ "$v" = "${want[$k]}" ] || r "traefik option $k is '$v', want '${want[$k]}' ($(traefik_option_name "$k"))"
  done
  for k in "${keys[@]}"; do
    [[ "$k" == TRAEFIK_* ]] || { r "traefik: unexpected environment variable $k"; continue; }
    if [ -z "${want[$k]+x}" ]; then
      v="$(ys_get "$cf" "services/traefik/environment/$k")"
      if [[ "$k" == *SANITIZEPATH ]] && [ "$v" = true ]; then continue; fi
      r "traefik: unexpected option $k=$v ($(traefik_option_name "$k"))"
    fi
  done
  [[ "$(ys_get "$cf" services/traefik/environment/TRAEFIK_ENTRYPOINTS_PING_ADDRESS)" == 127.0.0.1:* ]] \
    || r "ping entrypoint must bind 127.0.0.1 (loopback only, never published)"
  local -a eps
  mapfile -t eps < <(printf '%s\n' "${keys[@]}" | grep -E '^TRAEFIK_ENTRYPOINTS_[A-Z0-9]+_ADDRESS$' | sort)
  [ "${eps[*]:-}" = "TRAEFIK_ENTRYPOINTS_PING_ADDRESS TRAEFIK_ENTRYPOINTS_WEB_ADDRESS" ] \
    || r "entrypoints must be exactly web (routed) and ping (loopback health): got ${eps[*]:-none}"

  # -- dynamic.yml: one chain
  local deny="" catch="" rtr rule prio svc eps_r
  for rtr in $(ys_children "$df" http/routers); do
    rule="$(ys_get "$df" "http/routers/$rtr/rule")"
    svc="$(ys_get "$df" "http/routers/$rtr/service")"
    [ "$svc" != down-page ] || r "router $rtr points at down-page (no router may)"
    [ "$svc" = empty ] || r "router $rtr points at '$svc', want the empty service"
    eps_r="$(ys_list "$df" "http/routers/$rtr/entryPoints" | tr '\n' ' ')"
    [ "$eps_r" = "web " ] || r "router $rtr must attach to the web entrypoint only (got: ${eps_r:-none})"
    [[ "$rule" == PathRegexp\(* && "$rule" == *_jobs* ]] && deny="$rtr"
    [ "$rule" = 'PathPrefix(`/`)' ] && catch="$rtr"
  done
  if [ -z "$deny" ]; then
    r "missing /_jobs deny router (PathRegexp on _jobs)"
  else
    [ "$(ys_get "$df" "http/routers/$deny/priority")" = 2147483646 ] || r "deny router must carry the maximum explicit priority"
  fi
  if [ -z "$catch" ]; then
    r "missing catch-all router (lowest priority, sends to the empty service)"
  else
    prio="$(ys_get "$df" "http/routers/$catch/priority")"
    [ "$prio" = 1 ] || r "catch-all router must carry priority 1 (lowest)"
  fi
  ys_has "$df" http/services/empty || r "dynamic.yml lacks the shared empty service"
  ys_children "$df" http/services/empty/loadBalancer | grep -qx servers && r "the empty service must have no servers"
  [ "$(ys_get "$df" 'http/services/down-page/loadBalancer/servers[0]/url')" = http://down-page:8080 ] || r "dynamic.yml lacks the down-page service (static page service)"
  [ "$(ys_get "$df" http/middlewares/errors/errors/service)" = down-page ] || r "errors middleware must use the down-page service"
  [ "$(ys_list "$df" http/middlewares/errors/errors/status | tr '\n' ' ')" = "502-504 " ] || r "errors middleware must cover exactly 502-504"
  [ "$(ys_get "$df" http/middlewares/errors/errors/query)" = /index.html ] || r "errors middleware query path must be the static page"

  # -- deny rule against the shared table (offline matcher)
  local re="" flags="" kind path matched
  if [ -n "$deny" ]; then
    rule="$(ys_get "$df" "http/routers/$deny/rule")"
    if [[ "$rule" =~ ^PathRegexp\(\`(.*)\`\)$ ]]; then
      re="${BASH_REMATCH[1]}"
      if [[ "$re" == '(?i)'* ]]; then re="${re#'(?i)'}"; flags="-i"; fi
      if [[ "$re" == *'(?'* ]] || ! [[ "$re" =~ $re_ok ]]; then
        r "deny rule uses syntax the offline matcher cannot translate (fails closed): $re"
        re=""
      fi
    else
      r "deny rule is not a single PathRegexp(...)"
    fi
  fi
  local have_rows=""
  while read -r kind path; do
    have_rows="$have_rows|$kind $path"
    [ -n "$re" ] || continue
    if printf '%s\n' "$path" | grep -qE $flags -e "$re"; then matched=match; else matched=nomatch; fi
    [ "$matched" = "$kind" ] || r "deny rule fails the offline regex table: $path should be $kind, is $matched"
  done < <(grep -vE '^[[:space:]]*(#|$)' "$dir/jobs-paths.table")
  for i in "match /_jobs" "match /_jobs/x" "match /_JOBS/x" "match /_Jobs" "match /_jobs/;x" "nomatch /_jobs-anything" "nomatch /_jobsx" "nomatch /x/_jobs"; do
    [[ "$have_rows|" == *"|$i|"* ]] || r "jobs-paths.table lacks the required row: $i"
  done

  # -- recorded per-variant outcomes in the dynamic.yml header
  local name code known=" exact sub enc-underscore double-slash dot-segments semicolon upper mixed-case enc-slash enc-backslash enc-semicolon enc-percent enc-question enc-hash enc-null " seen=" "
  while IFS=' ' read -r name _ code; do
    [ -n "$name" ] || continue
    seen="$seen$name "
    [[ "$known" == *" $name "* ]] || { r "variant block: unknown variant $name"; continue; }
    case "$name" in
      enc-*) [[ "$code" == 400 || "$code" == 503 ]] || r "variant $name must be recorded as 400 or 503, got '$code'" ;;
      *) [ "$code" = 503 ] || r "variant $name must be recorded as 503, got '$code'" ;;
    esac
  done < <(awk '/^# variants-begin$/ { on = 1; next } /^# variants-end$/ { on = 0 } on && !/^# variant \| code$/ { sub(/^# /, ""); print }' "$dir/dynamic.yml")
  for name in $known; do
    [[ "$seen" == *" $name "* ]] || r "variant block lacks $name (run test_traefik_dynamic.sh --record)"
  done

  # -- down page
  [ -s "$dir/down-page/index.html" ] || r "down-page/index.html is missing"
  grep -qiE 'src=|href=|url\(|@import' "$dir/down-page/index.html" 2>/dev/null && r "down-page/index.html must not load external assets"
  grep -qE '^PLATFORM_DOMAIN=' "$dir/env.example" || r "env.example must carry the PLATFORM_DOMAIN placeholder"

  # -- no-secrets scan over everything under the ingress dir plus the host README
  local f shape
  while IFS= read -r -d '' f; do
    while IFS= read -r shape; do
      [ -n "$shape" ] && r "no-secrets scan: $shape in ${f#"$dir"/}"
    done < <(scan_file "$f")
  done < <(find "$dir" -type f -print0)
  if [ -n "$extra" ]; then
    while IFS= read -r shape; do
      [ -n "$shape" ] && r "no-secrets scan: $shape in $(basename "$extra")"
    done < <(scan_file "$extra")
  fi
}

# ---- mutation helpers (awk, with patterns passed through the environment) ----
# Scope: M_SVC limits a helper to one block whose header line is "<M_SVC>:" at indent M_IND (default 2).

m_edit() {
  # m_edit <file> <mode> <regex> [text]: mode replace|delete|after|before|dropkey
  local file="$1" mode="$2" re="$3" text="${4:-}"
  M_MODE="$mode" M_RE="$re" M_TEXT="$text" awk -v ind="${M_IND:-2}" '
    function indent_of(s) { match(s, /^ */); return RLENGTH }
    BEGIN { mode = ENVIRON["M_MODE"]; re = ENVIRON["M_RE"]; text = ENVIRON["M_TEXT"]; svc = ENVIRON["M_SVC"]
            gsub(/\\n/, "\n", text); inscope = (svc == ""); dropping = 0 }
    {
      ind_now = indent_of($0)
      if (svc != "" && $0 !~ /^ *#/ && $0 !~ /^ *$/ && ind_now == ind && $0 ~ /^ *[A-Za-z0-9_-]+:/) {
        inscope = ($0 ~ ("^ *" svc ":"))
      } else if (svc != "" && $0 !~ /^ *$/ && ind_now < ind) { inscope = 0 }
      if (dropping) { if ($0 ~ /^ *$/ || ind_now > dropind) next; dropping = 0 }
      if (inscope && $0 ~ re) {
        if (mode == "replace") { print text; next }
        if (mode == "delete") next
        if (mode == "after") { print; print text; next }
        if (mode == "before") { print text; print; next }
        if (mode == "dropkey") { dropping = 1; dropind = ind_now; next }
      }
      print
    }
  ' "$file" > "${file}-new" && mv "${file}-new" "$file"
}

mutn=0
# mutate <label> <expected reason substring> <file> <svc|-> <ind|-> <mode> <regex> [text]
mutate() {
  local label="$1" wantr="$2" which="$3" svc="$4" ind="$5" mode="$6" re="$7" text="${8:-}" dir target hit
  mutn=$((mutn + 1))
  dir="$T_TMP/mut-$mutn"
  cp -R "$here" "$dir"
  case "$which" in
    compose) target="$dir/compose.yaml" ;;
    dynamic) target="$dir/dynamic.yml" ;;
    table) target="$dir/jobs-paths.table" ;;
    env) target="$dir/env.example" ;;
    page) target="$dir/down-page/index.html" ;;
  esac
  cp "$target" "$T_TMP/before-mut"
  M_SVC=; M_IND=2
  [ "$svc" = - ] || M_SVC="$svc"
  [ "$ind" = - ] || M_IND="$ind"
  export M_SVC M_IND
  m_edit "$target" "$mode" "$re" "$text"
  unset M_SVC M_IND
  if cmp -s "$T_TMP/before-mut" "$target"; then
    _fail "mutation '$label' did not change the file" "regex: $re"
    return
  fi
  run_checks "$dir" "$host_readme"
  hit=0
  for r_ in "${REASONS[@]}"; do [[ "$r_" == *"$wantr"* ]] && hit=1; done
  if [ "$hit" = 1 ]; then _pass; else _fail "mutation '$label' was not caught with a reason containing '$wantr'" "got: ${REASONS[*]:-no failure at all}"; fi
}

# plant <label> <expected shape> <value-assembled-at-run-time>: append the value to env.example and scan.
plant() {
  local label="$1" wantr="$2" value="$3" dir
  mutn=$((mutn + 1))
  dir="$T_TMP/mut-$mutn"
  cp -R "$here" "$dir"
  printf '# %s\n' "$value" >> "$dir/env.example"
  run_checks "$dir" "$host_readme"
  local hit=0 r_
  for r_ in "${REASONS[@]}"; do [[ "$r_" == *"$wantr"* ]] && hit=1; done
  if [ "$hit" = 1 ]; then _pass; else _fail "planted $label was not caught with '$wantr'" "got: ${REASONS[*]:-no failure at all}"; fi
}

# ---- unmutated tree passes ----

run_checks "$here" "$host_readme"
if [ "${#REASONS[@]}" -eq 0 ]; then _pass; else
  _fail "the unmutated ingress stack must pass every check"
  printf '  reason: %s\n' "${REASONS[@]}"
fi

# ---- mutation cases: compose.yaml ----

mutate "published port" "ports is not allowed" compose cloudflared 2 after '^  cloudflared:' '    ports:\n      - "80:80"'
mutate "privileged" "privileged is not allowed" compose traefik 2 after '^  traefik:' '    privileged: true'
mutate "network_mode host" "network_mode is not allowed" compose traefik 2 after '^  traefik:' '    network_mode: host'
mutate "cap_add" "cap_add is not allowed" compose traefik 2 after '^  traefik:' '    cap_add:\n      - NET_ADMIN'
mutate "a second service" "service set is not exactly" compose - - before '^networks:' '  extra:\n    image: docker.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e\n'
mutate "floating image tag" "floating or unpinned" compose traefik 2 replace '^    image:' '    image: docker.io/library/traefik:latest'
mutate "tag without digest" "floating or unpinned" compose cloudflared 2 replace '^    image:' '    image: docker.io/cloudflare/cloudflared:2026.10.1'
mutate "unqualified image" "fully qualified" compose down-page 2 replace '^    image:' '    image: busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e'
mutate "docker socket on traefik" "Docker socket" compose traefik 2 after '^    volumes:' '      - /var/run/docker.sock:/var/run/docker.sock:ro'
mutate "read-write socket" "must mount the Docker socket read-only" compose socket-proxy 2 replace '^      - /var/run/docker.sock' '      - /var/run/docker.sock:/var/run/docker.sock'
mutate "platform.app label on cloudflared" "platform.app label" compose cloudflared 2 after '^  cloudflared:' '    labels:\n      platform.app: cloudflared'
mutate "platform.app label list form on down-page" "platform.app label" compose down-page 2 after '^  down-page:' '    labels:\n      - platform.app=down'
mutate "proxy network not internal" "ingress-proxy must be internal" compose - - replace '^    internal: true' '    internal: false'
mutate "platform network not external" "platform must be external" compose - - replace '^    external: true' '    external: false'
mutate "inline token" "inline token" compose cloudflared 2 after '^    environment:' '      TUNNEL_TOKEN: placeholder'
mutate "token as command argument" "inline token" compose cloudflared 2 after '^      - tunnel' '      - --token=placeholder'
mutate "root cloudflared" "non-root" compose cloudflared 2 replace '^    user:' '    user: "0:0"'
mutate "cloudflared without group_add" "group_add" compose cloudflared 2 dropkey '^    group_add:'
mutate "cloudflared token file not read-only" "read-only" compose cloudflared 2 replace '^      - /etc/platform/cloudflared.token' '      - /etc/platform/cloudflared.token:/run/cloudflared/token'
mutate "cloudflared without metrics address" "metrics address" compose cloudflared 2 delete '^      TUNNEL_METRICS:'
mutate "cloudflared without --no-autoupdate" "no-autoupdate" compose cloudflared 2 delete '^      - --no-autoupdate'
mutate "API on" "API/dashboard" compose traefik 2 after '^    environment:' '      TRAEFIK_API_INSECURE: "true"'
mutate "dashboard on" "API/dashboard" compose traefik 2 after '^    environment:' '      TRAEFIK_API_DASHBOARD: "true"'
mutate "sanitizePath off" "sanitizePath" compose traefik 2 after '^    environment:' '      TRAEFIK_ENTRYPOINTS_WEB_HTTP_SANITIZEPATH: "false"'
mutate "encoded slash allowed" "encodedCharacters" compose traefik 2 replace '^      TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDSLASH:' '      TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDSLASH: "true"'
mutate "encoded hash unset" "encodedCharacters" compose traefik 2 delete '^      TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDHASH:'
mutate "ping bound wide" "ping entrypoint must bind 127.0.0.1" compose traefik 2 replace '^      TRAEFIK_ENTRYPOINTS_PING_ADDRESS:' '      TRAEFIK_ENTRYPOINTS_PING_ADDRESS: 0.0.0.0:8082'
mutate "ping setting moved into command" "ping setting in command" compose traefik 2 after '^  traefik:' '    command:\n      - --ping=true'
mutate "ping enabled flag removed from environment" "TRAEFIK_PING is missing" compose traefik 2 delete '^      TRAEFIK_PING:'
mutate "flag in command disables the environment" "command arguments" compose traefik 2 after '^  traefik:' '    command:\n      - --log-level=DEBUG'
mutate "healthcheck with --ping flag" "traefik healthcheck must be exactly" compose traefik 2 after '^        - healthcheck' '        - --ping'
mutate "second routed entrypoint" "entrypoints must be exactly" compose traefik 2 after '^    environment:' '      TRAEFIK_ENTRYPOINTS_EXTRA_ADDRESS: ":81"'
mutate "errors middleware missing from the entrypoint" "errors@file" compose traefik 2 replace '^      TRAEFIK_ENTRYPOINTS_WEB_HTTP_MIDDLEWARES:' '      TRAEFIK_ENTRYPOINTS_WEB_HTTP_MIDDLEWARES: ""'
mutate "provider constraint dropped" "provider constraint" compose traefik 2 delete '^      TRAEFIK_PROVIDERS_DOCKER_CONSTRAINTS:'
mutate "constraint weakened" "provider constraint" compose traefik 2 replace '^      TRAEFIK_PROVIDERS_DOCKER_CONSTRAINTS:' '      TRAEFIK_PROVIDERS_DOCKER_CONSTRAINTS: LabelRegex(`platform.app`, `.*`)'
mutate "defaultRule changed" "defaultRule" compose traefik 2 replace '^      TRAEFIK_PROVIDERS_DOCKER_DEFAULTRULE:' '      TRAEFIK_PROVIDERS_DOCKER_DEFAULTRULE: Host(`{{ normalize .Name }}`)'
mutate "domain literal in defaultRule" "hostname shape" compose traefik 2 replace '^      TRAEFIK_PROVIDERS_DOCKER_DEFAULTRULE:' '      TRAEFIK_PROVIDERS_DOCKER_DEFAULTRULE: Host(`{{ index .Labels "platform.app" }}.'"$(printf '%s.%s' real-home example)"'.org`)'
mutate "access log not JSON" "access-log" compose traefik 2 replace '^      TRAEFIK_ACCESSLOG_FORMAT:' '      TRAEFIK_ACCESSLOG_FORMAT: common'
mutate "query string logged" "access-log" compose traefik 2 replace '^      TRAEFIK_ACCESSLOG_FIELDS_QUERYPARAMETERS_DEFAULTMODE:' '      TRAEFIK_ACCESSLOG_FIELDS_QUERYPARAMETERS_DEFAULTMODE: keep'
mutate "headers kept by default" "access-log" compose traefik 2 replace '^      TRAEFIK_ACCESSLOG_FIELDS_HEADERS_DEFAULTMODE:' '      TRAEFIK_ACCESSLOG_FIELDS_HEADERS_DEFAULTMODE: keep'
mutate "cookie header kept" "other than Cf-Connecting-Ip" compose traefik 2 after '^    environment:' '      TRAEFIK_ACCESSLOG_FIELDS_HEADERS_NAMES_Cookie: keep'
mutate "forwarded headers trusted" "forwardedHeaders" compose traefik 2 after '^    environment:' '      TRAEFIK_ENTRYPOINTS_WEB_FORWARDEDHEADERS_INSECURE: "true"'
mutate "trusted ips set" "forwardedHeaders" compose traefik 2 after '^    environment:' "      TRAEFIK_ENTRYPOINTS_WEB_FORWARDEDHEADERS_TRUSTEDIPS: $(t_ip4 10 0 0 0)/8"
mutate "socket-proxy allows POST" "allows a method other than GET and HEAD" compose socket-proxy 2 after '^      - -allowfrom' '      - -allowPOST=.*'
mutate "socket-proxy GET too wide" "GET allowlist" compose socket-proxy 2 replace '^      - -allowGET' '      - -allowGET=.*'
mutate "socket-proxy allowfrom widened" "allowfrom" compose socket-proxy 2 replace '^      - -allowfrom' '      - -allowfrom=0.0.0.0/0'
mutate "socket-proxy hardcoded gid" "DOCKER_GID" compose socket-proxy 2 replace '^      - "\$\{DOCKER_GID\}"' '      - "999"'
mutate "down-page healthcheck not TCP-connect" "TCP-connect form" compose down-page 2 replace '^        - nc$' '        - wget'
mutate "proxy on the platform network" "networks are" compose socket-proxy 2 after '^      - ingress-proxy' '      - platform'
mutate "compose leaves the YAML subset" "outside the YAML subset" compose cloudflared 2 replace '^    cap_drop:' '    cap_drop: [ALL]'

for svc in cloudflared down-page socket-proxy traefik; do
  mutate "$svc without cap_drop" "$svc: cap_drop must contain ALL" compose "$svc" 2 dropkey '^    cap_drop:'
  mutate "$svc without mem_limit" "$svc: mem_limit must be set" compose "$svc" 2 delete '^    mem_limit:'
  mutate "$svc without restart policy" "$svc: restart must be unless-stopped" compose "$svc" 2 delete '^    restart:'
  mutate "$svc without no-new-privileges" "$svc: security_opt must contain no-new-privileges:true" compose "$svc" 2 dropkey '^    security_opt:'
  mutate "$svc without healthcheck" "$svc: a healthcheck is required" compose "$svc" 2 dropkey '^    healthcheck:'
done

# ---- mutation cases: the remaining static checks ----

mutate "cloudflared healthcheck not the ready check" "healthcheck must be the ready check" compose cloudflared 2 replace '^        - ready' '        - version'
mutate "root traefik" "traefik must run as a fixed non-root user" compose traefik 2 replace '^    user:' '    user: "0:0"'
mutate "root socket-proxy" "socket-proxy must run as a fixed non-root user" compose socket-proxy 2 replace '^    user:' '    user: "0:0"'
mutate "root down-page" "down-page must run as a fixed non-root user" compose down-page 2 replace '^    user:' '    user: "0:0"'
mutate "ipam on the platform network" "ipam is not allowed" compose platform 2 after '^  platform:' '    ipam: x'
mutate "ipv6 on the platform network" "enable_ipv6 is not allowed" compose platform 2 after '^  platform:' '    enable_ipv6: true'
mutate "driver_opts on the platform network" "driver_opts is not allowed" compose platform 2 after '^  platform:' '    driver_opts: x'
mutate "ipam on the ingress-proxy network" "ipam is not allowed" compose ingress-proxy 2 after '^  ingress-proxy:' '    ipam: x'
mutate "ipv6 on the ingress-proxy network" "enable_ipv6 is not allowed" compose ingress-proxy 2 after '^  ingress-proxy:' '    enable_ipv6: true'
mutate "driver_opts on the ingress-proxy network" "driver_opts is not allowed" compose ingress-proxy 2 after '^  ingress-proxy:' '    driver_opts: x'
mutate "docker socket on down-page" "mounted on a service other than socket-proxy" compose down-page 2 after '^    volumes:' '      - /var/run/docker.sock:/var/run/docker.sock:ro'
mutate "docker socket on cloudflared" "mounted on a service other than socket-proxy" compose cloudflared 2 after '^    volumes:' '      - /var/run/docker.sock:/var/run/docker.sock:ro'
mutate "non-TRAEFIK_ variable on traefik" "unexpected environment variable EXTRA_VAR" compose traefik 2 after '^    environment:' '      EXTRA_VAR: x'
mutate "unexpected socket-proxy argument" "socket-proxy: unexpected argument" compose socket-proxy 2 after '^      - -allowfrom' '      - -logjson'
mutate "socket-proxy without -allowhealthcheck" "-allowhealthcheck" compose socket-proxy 2 delete '^      - -allowhealthcheck'
mutate "socket-proxy HEAD allowlist widened" "HEAD allowlist" compose socket-proxy 2 replace '^      - -allowHEAD' '      - -allowHEAD=.*'
mutate "catch-all priority raised" "priority 1 (lowest)" dynamic catch-all 4 replace '^      priority:' '      priority: 100'
mutate "empty service removed" "lacks the shared empty service" dynamic - - dropkey '^    empty:'
mutate "down-page service URL changed" "lacks the down-page service" dynamic - - replace '^          - url:' '          - url: http://other:8080'
mutate "errors middleware uses another service" "errors middleware must use the down-page service" dynamic - - replace '^        service: down-page' '        service: empty'
mutate "errors middleware query path changed" "query path must be the static page" dynamic - - replace '^        query:' '        query: /other.html'
mutate "env.example without PLATFORM_DOMAIN" "PLATFORM_DOMAIN placeholder" env - - delete '^PLATFORM_DOMAIN='
mutate "down-page page emptied" "index.html is missing" page - - delete '.'
for row in '^match /_jobs$' '^match /_jobs/x$' '^match /_JOBS/x$' '^match /_Jobs$' '^match /_jobs/;x$' '^nomatch /_jobs-anything$' '^nomatch /x/_jobs$'; do
  mutate "table lacks row $row" "lacks the required row" table - - delete "$row"
done

# ---- mutation cases: dynamic.yml, table, page ----

mutate "router pointing at down-page" "points at down-page" dynamic catch-all 4 replace '^      service: empty' '      service: down-page'
mutate "deny router deleted" "missing /_jobs deny router" dynamic jobs-deny 4 dropkey '^    jobs-deny:'
mutate "catch-all deleted" "missing catch-all router" dynamic catch-all 4 dropkey '^    catch-all:'
mutate "deny priority lowered" "maximum explicit priority" dynamic jobs-deny 4 replace '^      priority:' '      priority: 5'
mutate "deny rule case-sensitive" "fails the offline regex table" dynamic - - replace '^      rule: PathRegexp' '      rule: PathRegexp(`^/_jobs([/;]|$)`)'
mutate "deny rule loosened to a prefix" "fails the offline regex table" dynamic - - replace '^      rule: PathRegexp' '      rule: PathRegexp(`(?i)^/_jobs`)'
mutate "deny rule narrowed to the exact path" "fails the offline regex table" dynamic - - replace '^      rule: PathRegexp' '      rule: PathRegexp(`(?i)^/_jobs$`)'
mutate "deny rule uses untranslatable syntax" "cannot translate" dynamic - - replace '^      rule: PathRegexp' '      rule: PathRegexp(`(?i)^/_jobs(?:[/;]|$)`)'
mutate "deny not on web entrypoint" "web entrypoint only" dynamic jobs-deny 4 replace '^        - web' '        - websecure'
mutate "empty service gets a server" "no servers" dynamic empty 4 after '^      loadBalancer:' '        servers:\n          - url: http://down-page:8080'
mutate "errors middleware status widened" "exactly 502-504" dynamic - - replace '^          - "502-504"' '          - "400-599"'
mutate "recorded variant code wrong" "must be recorded as 503" dynamic - - replace '^# exact \|' '# exact | 200'
mutate "recorded variant missing" "lacks upper" dynamic - - delete '^# upper \|'
mutate "table lacks a lookalike row" "lacks the required row" table - - delete '^nomatch /_jobsx'
mutate "page loads an external asset" "external assets" page - - after '^<title>' '<link rel="stylesheet" href="x">'

# ---- no-secrets scan: one planted value per shape (assembled at run time) ----

plant "email" "email shape" "$(printf '%s@%s.%s' someone mail example)"
plant "UUID" "UUID shape" "$(printf '%s-%s-%s-%s-%s' 0123abcd 4567 89ab cdef 0123456789ab)"
plant "eyJ token prefix" "eyJ token prefix" "$(printf '%s%s' ey JhbGciOiJIUzI1NiJ9)"
plant "32+ hex run" "32+ hex run" "$(printf '%s%s%s%s' 0123456789ab cdef0123 456789ab cdef0123)"
plant "hostname" "hostname shape" "$(printf '%s.%s.%s' tunnel corp net)"
plant "hostname with the fake domain suffix lookalike" "hostname shape" "$(printf '%s.%s' notexample test)"

t_finish
