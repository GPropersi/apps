#!/usr/bin/env bash
# install-ingress.sh: install, check and live-test the ingress stack on the app host (run yourself, not Claude).
#
# The stack (cloudflared, Traefik behind a read-only Docker socket proxy, the "app is down" page) is described by
# platform/ingress/compose.yaml and platform/ingress/dynamic.yml. It runs as the Compose project platform-ingress
# from /opt/platform/ingress and joins the `platform` Docker network, which this script creates if absent (bridge,
# IPv6 off, default br- bridge name). No port is published and no firewall rule is touched.
#
# Host-side inputs (you create them; the installer never writes secrets and never edits /etc/group):
#   /etc/platform/cloudflared.token   the tunnel token: regular file, owner root, group gid 64321, mode exactly 0640
#   /etc/platform/ingress.env         PLATFORM_DOMAIN=<your domain>: root-owned, not group/world writable
#   a group with gid 64321 that has no members, is no account's primary group and is not the Docker socket's group
#   (cloudflared gets that gid through group_add in compose.yaml and so can read the token; nobody else can)
# The Docker socket's group id is derived here with stat (never a docker call) and stored in
# /opt/platform/ingress/docker-gid.env, which is passed to Compose as a second --env-file.
#
# The three payload files (compose.yaml, dynamic.yml, down-page/index.html) are embedded below
# (BEGIN-PAYLOAD/END-PAYLOAD) because the host has no checkout: `platform/lint/embed-payloads.sh` regenerates them
# from the tracked sources (`make embed`) and `make lint` fails if they differ.
#
# Usage: install-ingress.sh [install|status|verify] [--host ALIAS]
#        install-ingress.sh verify --live [--hold] --host ALIAS
#   install   checks every precondition first (token file, domain, Docker socket, token group) and runs no docker
#             command until they all pass; then places the files root-owned under /opt/platform/ingress, creates the
#             network, brings the stack up and waits (bounded) for every container to be healthy. Idempotent: a second
#             run with unchanged inputs reports "already:" for every item and makes no mutating docker call.
#   status    report every check (PASS/FAIL), exit 0
#   verify    the same checks, exit 1 on any FAIL
#   verify --live   client-driven end-to-end probe set; nothing is created without this flag. Over ssh (sudo docker)
#             it starts four disposable, hardened containers (a labelled test app, an unlabelled sibling, a curl client,
#             and a hostile app whose own traefik.* labels compete with the /_jobs deny, which must still answer 503),
#             sends every probe straight to traefik:80 from the curl client and ALWAYS removes the containers (EXIT
#             plus INT/TERM/HUP traps). It refuses to run when a container named ingress-livetest* or labelled
#             platform.app=ingress-livetest already exists. The per-variant /_jobs codes are read from the
#             variants block in the embedded dynamic.yml, never retyped here.
#   --hold    with --live: after the automated probes the test app stays up, the script prints its public hostname and
#             waits for Enter (or a bounded timeout) while you complete the browser login through the real tunnel,
#             then reads Traefik's access log (stdout, docker logs --since the hold start) and reports PASS or FAIL for
#             (a) a request that carries Cf-Connecting-Ip (only the real tunnel adds it) and (b) its Host equal to the
#             public test hostname. Only entries for the test host or its page are judged; other apps' traffic is ignored.
#   --host    stream this script over one `ssh <alias> bash -s` call (BatchMode, no tty; passwordless sudo needed).
#             With --live it is the ssh alias used for every docker call.
#
# Exit: 0 ok | 1 failed check, wrong state or unusable input | 2 usage error. ssh failures pass through ssh's status.
#
# Test overrides (env, test-only): INSTALL_INGRESS_ROOT (path prefix for every host file), INSTALL_INGRESS_SUDO (the
# privilege prefix; "sudo -n" by default, none when already root), INSTALL_INGRESS_SOCKET (the Docker socket path),
# INSTALL_INGRESS_HEALTH_TIMEOUT / INSTALL_INGRESS_POLL (seconds), INSTALL_INGRESS_LIVE_LOCAL (run the live docker
# commands locally instead of over ssh), INSTALL_INGRESS_LIVE_SLEEP, INSTALL_INGRESS_HOLD_TTY,
# INSTALL_INGRESS_HOLD_TIMEOUT. The docker, stat and getent commands are the ones on PATH, so a test puts stubs there.
set -euo pipefail

export LC_ALL=C
# groupadd, getent and friends live in /usr/sbin, which a non-root ssh user's PATH lacks
export PATH="$PATH:/usr/sbin:/sbin"

# The dedicated token group. Fixed, chosen without knowledge of the host's group database; it must equal the numeric
# group_add of cloudflared in compose.yaml (the test suite compares the two).
readonly TOKEN_GID=64321
readonly INSTALL_DIR="/opt/platform/ingress"
readonly ENV_FILE="/etc/platform/ingress.env"
readonly TOKEN_FILE="/etc/platform/cloudflared.token"
readonly GID_FILE="/opt/platform/ingress/docker-gid.env"
readonly PROJECT="platform-ingress"
readonly NETWORK="platform"
readonly SERVICES=(cloudflared traefik socket-proxy down-page)
readonly EDGE_NAME="region1.v2.argotunnel.com"
readonly DOMAIN_RE='^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]([a-z0-9-]{0,61}[a-z0-9])?$'
ROOT="${INSTALL_INGRESS_ROOT:-}"
SOCKET="${INSTALL_INGRESS_SOCKET:-/var/run/docker.sock}"
HEALTH_TIMEOUT="${INSTALL_INGRESS_HEALTH_TIMEOUT:-120}"
POLL="${INSTALL_INGRESS_POLL:-2}"

if [ -n "${INSTALL_INGRESS_SUDO+set}" ]; then
  read -r -a SUDO <<<"$INSTALL_INGRESS_SUDO"
elif [ "$EUID" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo -n)
fi

FAILURES=0
CHANGED=0
TMP=""

info() { printf '%s\n' "$1"; }
err() { printf '%s\n' "$1" >&2; }
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
die() { err "install-ingress: $1"; exit "${2:-1}"; }

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

# priv <cmd...>: run with privilege; stdin is never forwarded (this script may itself be read from stdin).
priv() { "${SUDO[@]}" "$@" </dev/null; }
dk() { priv docker "$@"; }

require_privilege() {
  priv true || die "no usable privilege (sudo -n failed). Over --host the account needs passwordless sudo; otherwise copy this script to the host and run it there directly"
}

# ---- embedded payloads (regenerated by platform/lint/embed-payloads.sh; do not edit between the markers) ----

# BEGIN-PAYLOAD platform/ingress/compose.yaml
payload_compose() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# Ingress stack: the single front door of the app host (no published ports; traffic arrives over the tunnel).
#
#   cloudflared  -> traefik -> app containers on the `platform` network
#   traefik      -> socket-proxy (read-only, allowlisted Docker API) on the internal `ingress-proxy` network
#   down-page    -> supplies the friendly "app is down" body that the errors middleware shows
#
# Host-side inputs (never written here): PLATFORM_DOMAIN (the env file), DOCKER_GID (derived by the installer
# from the Docker socket's group), the tunnel token file mounted into cloudflared.
#
# Rules this file keeps (platform/ingress/test_ingress_stack.sh enforces them):
# - It stays inside a small YAML subset (block style only) so the tests can read it without a YAML library.
# - Traefik is configured ONLY through TRAEFIK_* environment variables, and has no `command:`. Traefik ignores
#   its environment as soon as any command-line flag is present, and `traefik healthcheck` (no --ping flag) reads
#   the same environment, so the server and its healthcheck cannot drift apart.
# - Apps carry the single label platform.app=<name> and no traefik.* labels. No service in this file has it.
# - Every service drops all capabilities, cannot gain privileges, has a memory limit and restarts unless stopped.
name: platform-ingress

services:
  cloudflared:
    image: docker.io/cloudflare/cloudflared:2026.10.1@sha256:a15a3b50b8dabd57ac2090e9484c0247dba9dfa1f0df4d298d4317f9d69eb2d5
    command:
      - tunnel
      - --no-autoupdate
      - run
    environment:
      TUNNEL_TOKEN_FILE: /run/cloudflared/token
      TUNNEL_METRICS: 127.0.0.1:20241
    volumes:
      - /etc/platform/cloudflared.token:/run/cloudflared/token:ro
    user: "65532:65532"
    # The dedicated token group (no members; the installer creates it with this fixed gid, token file is
    # root:<gid> mode 0640).
    group_add:
      - "64321"
    networks:
      - platform
    restart: unless-stopped
    mem_limit: 128m
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    healthcheck:
      test:
        - CMD
        - cloudflared
        - tunnel
        - ready
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s

  traefik:
    image: docker.io/library/traefik:v3.7.15@sha256:0f6150202bc1fed72a7bd2107460eaa510e5b8a905f3fdb5b84f2c8619c33368
    environment:
      TRAEFIK_GLOBAL_CHECKNEWVERSION: "false"
      TRAEFIK_GLOBAL_SENDANONYMOUSUSAGE: "false"
      TRAEFIK_LOG_FORMAT: json
      TRAEFIK_LOG_LEVEL: INFO
      # The one routed entrypoint (plain HTTP inside the container; TLS ends at Cloudflare).
      TRAEFIK_ENTRYPOINTS_WEB_ADDRESS: ":80"
      TRAEFIK_ENTRYPOINTS_WEB_ASDEFAULT: "true"
      TRAEFIK_ENTRYPOINTS_WEB_HTTP_MIDDLEWARES: errors@file
      TRAEFIK_ENTRYPOINTS_WEB_HTTP_ALIASHEADERSSTRATEGY: delete
      TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDSLASH: "false"
      TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDBACKSLASH: "false"
      TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDNULLCHARACTER: "false"
      TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDSEMICOLON: "false"
      TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDPERCENT: "false"
      TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDQUESTIONMARK: "false"
      TRAEFIK_ENTRYPOINTS_WEB_HTTP_ENCODEDCHARACTERS_ALLOWENCODEDHASH: "false"
      # Health ping: its own entrypoint, loopback only inside the container, never published, never routed.
      TRAEFIK_PING: "true"
      TRAEFIK_PING_ENTRYPOINT: ping
      TRAEFIK_ENTRYPOINTS_PING_ADDRESS: 127.0.0.1:8082
      # Routing comes from the single platform.app label: only labelled containers become routers.
      TRAEFIK_PROVIDERS_DOCKER_ENDPOINT: tcp://socket-proxy:2375
      TRAEFIK_PROVIDERS_DOCKER_NETWORK: platform
      TRAEFIK_PROVIDERS_DOCKER_EXPOSEDBYDEFAULT: "true"
      TRAEFIK_PROVIDERS_DOCKER_CONSTRAINTS: LabelRegex(`platform.app`, `.+`)
      TRAEFIK_PROVIDERS_DOCKER_DEFAULTRULE: Host(`{{ index .Labels "platform.app" }}.${PLATFORM_DOMAIN}`)
      TRAEFIK_PROVIDERS_FILE_DIRECTORY: /etc/traefik/dynamic
      TRAEFIK_PROVIDERS_FILE_WATCH: "true"
      # Access log: JSON on stdout, no query strings, no headers except the client address Cloudflare sets.
      TRAEFIK_ACCESSLOG: "true"
      TRAEFIK_ACCESSLOG_FORMAT: json
      TRAEFIK_ACCESSLOG_FIELDS_HEADERS_DEFAULTMODE: drop
      TRAEFIK_ACCESSLOG_FIELDS_HEADERS_NAMES_Cf-Connecting-Ip: keep
      TRAEFIK_ACCESSLOG_FIELDS_QUERYPARAMETERS_DEFAULTMODE: drop
    volumes:
      - ./dynamic:/etc/traefik/dynamic:ro
    user: "65532:65532"
    networks:
      - platform
      - ingress-proxy
    restart: unless-stopped
    mem_limit: 256m
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    healthcheck:
      test:
        - CMD
        - traefik
        - healthcheck
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s

  socket-proxy:
    image: docker.io/wollomatic/socket-proxy:1.13.1@sha256:3935b709275e4ec35d6ed5a5c4a1f0d01ed31eec5e7234efc3357ecd47689002
    # GET on /version, /containers/json, /containers/<id>/json and /events, HEAD on /_ping, each with an
    # optional API version prefix (v and a number pair); every other method and path is denied. $$ is a literal $
    # for Compose.
    command:
      - -listenip=0.0.0.0
      - -allowfrom=traefik
      - -allowGET=^(/v[0-9]+\.[0-9]+)?/(version|containers/json|containers/[a-zA-Z0-9]+/json|events)$$
      - -allowHEAD=^(/v[0-9]+\.[0-9]+)?/_ping$$
      - -allowhealthcheck
      - -watchdoginterval=10
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    user: "65534:65534"
    group_add:
      - "${DOCKER_GID}"
    networks:
      - ingress-proxy
    restart: unless-stopped
    mem_limit: 64m
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    healthcheck:
      test:
        - CMD
        - /healthcheck
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 5s

  down-page:
    image: docker.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
    command:
      - httpd
      - -f
      - -p
      - "8080"
      - -h
      - /www
    volumes:
      - ./down-page:/www:ro
    user: "65534:65534"
    networks:
      - platform
    restart: unless-stopped
    mem_limit: 32m
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    healthcheck:
      test:
        - CMD
        - nc
        - -z
        - 127.0.0.1
        - "8080"
      interval: 15s
      timeout: 5s
      retries: 3
      start_period: 5s

networks:
  platform:
    external: true
  ingress-proxy:
    internal: true
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/ingress/compose.yaml

# BEGIN-PAYLOAD platform/ingress/dynamic.yml
payload_dynamic() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# Traefik file-provider configuration (installed in the dynamic/ directory next to compose.yaml).
#
# One chain, one mechanism for "not served":
#   - the /_jobs deny router and the lowest-priority catch-all both send to the `empty` service (no servers),
#     which Traefik answers with 503, so the request never reaches an app;
#   - the `errors` middleware, attached to the web entrypoint in compose.yaml (errors@file), replaces the body of
#     any 502 to 504 (status preserved) with the page fetched from the down-page service;
#   - the down-page service serves that page with 200 and no router targets it.
#
# Primitives: PathRegexp with an inline (?i) flag for the deny rule (a regex, not PathPrefix, because it must be
# case-insensitive and treat a ";" suffix as under the prefix); maximum explicit priority so the deny outranks
# any app router whatever the length of its auto-generated rule; priority 1 for the catch-all.
#
# Per-variant outcome of a request that looks like /_jobs (recorded by test_traefik_dynamic.sh --record, checked
# by the same test and by `verify --live`). Normalised forms answer 503 with the friendly body; variants with an
# encoded reserved character are rejected before routing (400) or denied (503); none reaches an app. The deny
# and the catch-all both get the friendly page as the body: the property is that nothing reaches an app.
# variants-begin
# variant | code
# exact | 503
# sub | 503
# enc-underscore | 503
# double-slash | 503
# dot-segments | 503
# semicolon | 503
# upper | 503
# mixed-case | 503
# enc-slash | 400
# enc-backslash | 400
# enc-semicolon | 400
# enc-percent | 400
# enc-question | 400
# enc-hash | 400
# enc-null | 400
# variants-end
http:
  routers:
    jobs-deny:
      entryPoints:
        - web
      rule: PathRegexp(`(?i)^/_jobs([/;]|$)`)
      priority: 2147483646
      service: empty
    catch-all:
      entryPoints:
        - web
      rule: PathPrefix(`/`)
      priority: 1
      service: empty
  middlewares:
    errors:
      errors:
        status:
          - "502-504"
        service: down-page
        query: /index.html
  services:
    empty:
      loadBalancer:
        passHostHeader: true
    down-page:
      loadBalancer:
        servers:
          - url: http://down-page:8080
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/ingress/dynamic.yml

# BEGIN-PAYLOAD platform/ingress/down-page/index.html
payload_index() {
  cat <<'PLATFORM_PAYLOAD_EOF'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>App unavailable</title>
<style>
  body { font-family: system-ui, sans-serif; margin: 0; min-height: 100vh; display: flex; align-items: center; justify-content: center; background: #f4f4f5; color: #18181b; }
  main { max-width: 28rem; padding: 2rem; text-align: center; }
  h1 { font-size: 1.5rem; margin: 0 0 0.75rem; }
  p { margin: 0; line-height: 1.5; }
  @media (prefers-color-scheme: dark) { body { background: #18181b; color: #f4f4f5; } }
</style>
</head>
<body>
<main>
  <h1>This app is down or does not exist</h1>
  <p>Check the address, or try again in a minute.</p>
</main>
</body>
</html>
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/ingress/down-page/index.html

# ---- host inputs: each chk_* prints one line per problem (never a file's content) and always returns 0 ----

# file_meta <path>: "<uid>:<gid> <octal mode>".
file_meta() { stat -c '%u:%g %a' -- "$1"; }

# socket_gid: the numeric group of the Docker socket, from stat (not a docker call).
socket_gid() { stat -c '%g' -- "$SOCKET"; }

chk_token_file() {
  local p="$ROOT$TOKEN_FILE" meta tok
  if ! priv test -e "$p"; then echo "token file missing: $TOKEN_FILE"; return 0; fi
  if priv test -L "$p"; then echo "token file is a symlink: $TOKEN_FILE"; return 0; fi
  if ! priv test -f "$p"; then echo "token file is not a regular file: $TOKEN_FILE"; return 0; fi
  meta="$(priv stat -c '%u:%g %a' -- "$p")" || { echo "cannot stat the token file"; return 0; }
  [ "$meta" = "0:$TOKEN_GID 640" ] || echo "token file uid:gid/mode is '$meta', want '0:$TOKEN_GID 640' (owner root, group $TOKEN_GID, mode 0640)"
  if ! priv test -s "$p"; then echo "token file is empty"; return 0; fi
  tok="$(priv cat -- "$p")" || { echo "cannot read the token file"; return 0; }
  tok="${tok//[$' \t\r\n']/}"
  [ -n "$tok" ] || echo "token file has no non-blank content"
}

# env_domain: prints the PLATFORM_DOMAIN value of the env file (caller validates it).
env_domain() {
  local lines=()
  mapfile -t lines < <(priv grep '^PLATFORM_DOMAIN=' -- "$ROOT$ENV_FILE" || true)
  [ "${#lines[@]}" -eq 1 ] || return 1
  printf '%s\n' "${lines[0]#PLATFORM_DOMAIN=}"
}

valid_domain() { [ "${#1}" -le 253 ] && [[ "$1" =~ $DOMAIN_RE ]]; }

chk_env_file() {
  local p="$ROOT$ENV_FILE" meta mode g o dom
  if ! priv test -e "$p"; then echo "ingress env file missing: $ENV_FILE"; return 0; fi
  if priv test -L "$p"; then echo "ingress env file is a symlink: $ENV_FILE"; return 0; fi
  if ! priv test -f "$p"; then echo "ingress env file is not a regular file: $ENV_FILE"; return 0; fi
  meta="$(priv stat -c '%u:%g %a' -- "$p")" || { echo "cannot stat the ingress env file"; return 0; }
  mode="${meta##* }"
  if [ "${meta%%:*}" != "0" ]; then echo "ingress env file is not owned by root (uid:gid/mode '$meta')"; fi
  if [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
    g="${mode: -2:1}"
    o="${mode: -1}"
    if [ $((g & 2)) -ne 0 ] || [ $((o & 2)) -ne 0 ]; then echo "ingress env file is group or world writable (mode $mode)"; fi
  else
    echo "ingress env file mode is not octal ('$mode')"
  fi
  if dom="$(env_domain)"; then
    valid_domain "$dom" || echo "PLATFORM_DOMAIN is not a lowercase DNS name (labels of a-z, 0-9, hyphen; at least two labels)"
  else
    echo "ingress env file must hold exactly one PLATFORM_DOMAIN= line"
  fi
}

chk_socket() {
  local gid
  if [ ! -e "$SOCKET" ]; then echo "Docker socket missing: $SOCKET"; return 0; fi
  gid="$(socket_gid)" || { echo "cannot stat the Docker socket"; return 0; }
  [[ "$gid" =~ ^[0-9]+$ ]] || { echo "Docker socket group is not numeric ('$gid')"; return 0; }
  [ "$gid" -ne 0 ] || echo "Docker socket group is root (gid 0); refusing to grant it to the socket proxy"
}

chk_token_group() {
  local entry gid members sgid accounts groups_all dup prim
  entry="$(getent group "$TOKEN_GID" || true)"
  gid=""
  members=""
  [ -z "$entry" ] || IFS=: read -r _ _ gid members <<<"$entry"
  if [ "$gid" != "$TOKEN_GID" ]; then
    echo "no group with gid $TOKEN_GID exists (token group); create it, see the instructions below"
    return 0
  fi
  [ -z "$members" ] || echo "token group (gid $TOKEN_GID) has members; it must have none"
  # getent group <gid> shows only the first entry: a second entry with the same gid and a member must also fail.
  groups_all="$(getent group || true)"
  if [ -n "$groups_all" ]; then
    dup="$(awk -F: -v g="$TOKEN_GID" '$3 == g { n++; if ($4 != "") m++ } END { print (n + 0) " " (m + 0) }' <<<"$groups_all")"
    if [ "${dup%% *}" -gt 1 ] 2>/dev/null; then echo "more than one group entry carries gid $TOKEN_GID (token group must be unique)"; fi
    if [ "${dup##* }" -gt 0 ] 2>/dev/null && [ -z "$members" ]; then echo "a group entry with gid $TOKEN_GID has members; it must have none"; fi
  fi
  accounts="$(getent passwd || true)"
  if [ -z "$accounts" ]; then
    echo "cannot list accounts to check the token group is nobody's primary group"
  else
    prim=0
    awk -F: -v g="$TOKEN_GID" '$4 == g { f = 1 } END { exit f ? 0 : 1 }' <<<"$accounts" || prim=$?
    case "$prim" in
      0) echo "token group (gid $TOKEN_GID) is an account's primary group" ;;
      1) ;;
      *) echo "cannot check the accounts' primary groups (awk failed)" ;;
    esac
  fi
  if sgid="$(socket_gid 2>/dev/null)" && [ "$sgid" = "$TOKEN_GID" ]; then
    echo "token group (gid $TOKEN_GID) is the Docker socket's group"
  fi
}

print_instructions() {
  err ""
  err "Create the host-side inputs yourself (nothing here writes a secret or edits /etc/group):"
  err "  sudo groupadd --gid $TOKEN_GID cloudflared-token       # once; no members, no account may use it as primary group"
  err "  sudo install -d -m 0755 -o root -g root /etc/platform"
  err "  sudo install -m 0640 -o root -g $TOKEN_GID /dev/null $TOKEN_FILE"
  err "  sudo tee $TOKEN_FILE >/dev/null     # paste the tunnel token from the Cloudflare dashboard, Enter, Ctrl-D"
  err "  sudo chown root:$TOKEN_GID $TOKEN_FILE && sudo chmod 0640 $TOKEN_FILE"
  err "  echo 'PLATFORM_DOMAIN=<your-domain>' | sudo tee $ENV_FILE >/dev/null && sudo chmod 0644 $ENV_FILE"
}

# ---- file helpers ----

# place_file <src> <dest> <mode>: copy, own as root, chmod, then atomic rename. Reports already/changed.
place_file() {
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest" && [ "$(file_meta "$dest")" = "0:0 $mode" ]; then
    info "already: $dest"
    return 0
  fi
  priv cp -- "$src" "$dest.new"
  priv chown root:root "$dest.new"
  priv chmod "$mode" "$dest.new"
  priv mv -f -- "$dest.new" "$dest"
  info "changed: $dest"
  CHANGED=1
}

place_dir() {
  local dir="$1" mode="$2"
  if [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(file_meta "$dir")" = "0:0 $mode" ]; then
    info "already: $dir/"
    return 0
  fi
  # A symlink in place of the directory is removed (the link only, never its target) and replaced by a real directory.
  if [ -L "$dir" ]; then priv rm -f -- "$dir"; fi
  priv mkdir -p -- "$dir"
  priv chown root:root "$dir"
  priv chmod "$mode" "$dir"
  info "changed: $dir/"
  CHANGED=1
}

# ---- compose helpers ----

compose() {
  dk compose -p "$PROJECT" -f "$ROOT$INSTALL_DIR/compose.yaml" --env-file "$ROOT$ENV_FILE" --env-file "$ROOT$GID_FILE" "$@"
}

# stack_ps: one "<name>|<service>|<state>|<health>" line per container of the project.
stack_ps() { compose ps --all --format '{{.Name}}|{{.Service}}|{{.State}}|{{.Health}}'; }

# stack_problems <ps text> [run]: one line per service that is absent, not running or (without "run") not healthy.
stack_problems() {
  local ps="$1" only_run="${2:-}" svc found name service state health
  for svc in "${SERVICES[@]}"; do
    found=0
    while IFS='|' read -r name service state health; do
      [ "$service" = "$svc" ] || continue
      found=1
      if [ "$state" != "running" ]; then
        echo "$name is $state"
      elif [ -z "$only_run" ] && [ "$health" != "healthy" ]; then
        echo "$name is ${health:-without a health status}"
      fi
    done <<<"$ps"
    [ "$found" -eq 1 ] || echo "service $svc has no container"
  done
}

ensure_network() {
  local names desc
  names="$(dk network ls --filter "name=^${NETWORK}\$" --format '{{.Name}}')" || die "cannot list docker networks"
  if grep -qxF "$NETWORK" <<<"$names"; then
    desc="$(dk network inspect --format '{{.Driver}} {{.EnableIPv6}}' "$NETWORK")" || die "cannot inspect the $NETWORK network"
    [ "$desc" = "bridge false" ] || die "network $NETWORK exists but is '$desc' (want 'bridge false': a bridge with IPv6 off); fix or remove it and re-run"
    info "already: network $NETWORK"
  else
    dk network create --driver bridge --ipv6=false "$NETWORK" >/dev/null || die "could not create the $NETWORK network"
    info "changed: network $NETWORK created"
    CHANGED=1
  fi
}

wait_healthy() {
  local deadline ps problems
  deadline=$((SECONDS + HEALTH_TIMEOUT))
  while :; do
    ps="$(stack_ps 2>/dev/null)" || ps=""
    problems="$(stack_problems "$ps")"
    if [ -z "$problems" ]; then
      info "healthy: all ${#SERVICES[@]} containers"
      return 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      err "$problems"
      die "the stack is not healthy after ${HEALTH_TIMEOUT}s (unhealthy: $(tr '\n' ';' <<<"$problems"))"
    fi
    sleep "$POLL"
  done
}

# ---- install ----

do_install() {
  local problems line gid ps
  require_privilege
  TMP="$(mktemp -d)"

  problems="$(chk_token_file; chk_env_file; chk_socket; chk_token_group)"
  if [ -n "$problems" ]; then
    while IFS= read -r line; do err "install-ingress: $line"; done <<<"$problems"
    print_instructions
    die "preconditions failed; nothing was installed and no docker command was run"
  fi
  gid="$(socket_gid)"

  payload_compose > "$TMP/compose.yaml"
  payload_dynamic > "$TMP/dynamic.yml"
  payload_index > "$TMP/index.html"
  printf 'DOCKER_GID=%s\n' "$gid" > "$TMP/docker-gid.env"

  place_dir "$ROOT$INSTALL_DIR" 755
  place_dir "$ROOT$INSTALL_DIR/dynamic" 755
  place_dir "$ROOT$INSTALL_DIR/down-page" 755
  place_file "$TMP/compose.yaml" "$ROOT$INSTALL_DIR/compose.yaml" 644
  place_file "$TMP/dynamic.yml" "$ROOT$INSTALL_DIR/dynamic/dynamic.yml" 644
  place_file "$TMP/index.html" "$ROOT$INSTALL_DIR/down-page/index.html" 644
  place_file "$TMP/docker-gid.env" "$ROOT$GID_FILE" 644
  ensure_network

  ps="$(stack_ps 2>/dev/null)" || ps=""
  if [ "$CHANGED" -eq 1 ] || [ -n "$(stack_problems "$ps" run)" ]; then
    compose up -d --remove-orphans || die "docker compose up failed"
    info "changed: stack started"
  else
    info "already: stack running"
  fi
  wait_healthy
  info "install-ingress: done"
}

# ---- status / verify ----

check_owned() {
  local label="$1" path="$2" mode="$3" meta
  if [ ! -e "$path" ]; then fail "$label missing: $path"; return 1; fi
  if [ -L "$path" ]; then fail "$label is a symlink: $path"; return 1; fi
  meta="$(file_meta "$path")"
  if [ "$meta" = "0:0 $mode" ]; then pass "$label owner/mode ($meta)"; else fail "$label uid:gid/mode is '$meta', want '0:0 $mode'"; return 1; fi
}

check_payload() {
  local label="$1" path="$2" fn="$3"
  if [ -f "$path" ] && "$fn" | cmp -s - "$path"; then pass "$label bytes equal the embedded payload"; else fail "$label bytes differ from the embedded payload"; fi
}

# run_check <label> <fn>: PASS when the chk function prints nothing, one FAIL per printed problem otherwise.
run_check() {
  local label="$1" fn="$2" probs line
  probs="$("$fn")"
  if [ -z "$probs" ]; then
    pass "$label"
  else
    while IFS= read -r line; do fail "$label: $line"; done <<<"$probs"
  fi
}

# shellcheck disable=SC2329 # invoked by name through run_check
chk_stored_gid() {
  local cur
  if [ ! -f "$ROOT$GID_FILE" ]; then echo "stored DOCKER_GID file missing: $GID_FILE"; return 0; fi
  cur="$(socket_gid 2>/dev/null)" || { echo "cannot read the Docker socket group"; return 0; }
  [ "$(cat -- "$ROOT$GID_FILE")" = "DOCKER_GID=$cur" ] || echo "stored DOCKER_GID differs from the Docker socket's current group (re-run install)"
}

# shellcheck disable=SC2329 # invoked by name through run_check
chk_network() {
  local desc
  desc="$(dk network inspect --format '{{.Driver}} {{.EnableIPv6}}' "$NETWORK" 2>/dev/null)" || { echo "network $NETWORK is missing"; return 0; }
  [ "$desc" = "bridge false" ] || echo "network $NETWORK is '$desc', want 'bridge false'"
}

# container_checks <ps text>: per-container security properties.
# shellcheck disable=SC2016 # the {{ }} docker templates and the in-container $( ) are literal on purpose
container_checks() {
  local ps="$1" name service state health out tok envcmd
  while IFS='|' read -r name service state health; do
    [ -n "$name" ] || continue
    out="$(dk port "$name" 2>/dev/null || true)"
    if [ -z "$out" ]; then pass "$name publishes no port"; else fail "$name publishes a port"; fi

    out="$(dk inspect --format '{{range $k, $v := .Config.Labels}}{{$k}}{{"\n"}}{{end}}' "$name" 2>/dev/null || echo "inspect-failed")"
    if [ "$out" = "inspect-failed" ]; then fail "cannot inspect the labels of $name"
    elif grep -qxF "platform.app" <<<"$out"; then fail "$name carries the platform.app label"
    else pass "$name carries no platform.app label"; fi

    out="$(dk inspect --format '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "$name" 2>/dev/null || echo "inspect-failed")"
    if [ "$out" = "inspect-failed" ]; then
      fail "cannot inspect the mounts of $name"
    elif [ "$service" = "socket-proxy" ]; then
      if grep -qF "docker.sock" <<<"$out"; then pass "socket-proxy mounts the Docker socket"; else fail "socket-proxy does not mount the Docker socket"; fi
    elif grep -qF "docker.sock" <<<"$out"; then
      fail "$name mounts the Docker socket (only socket-proxy may)"
    else
      pass "$name does not mount the Docker socket"
    fi

    case "$service" in
      traefik)
        out="$(dk inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$name" 2>/dev/null || true)"
        if grep -qxF "$NETWORK" <<<"$out"; then pass "traefik is on the $NETWORK network"; else fail "traefik is not on the $NETWORK network"; fi
        ;;
      cloudflared)
        # The token is compared inside this shell only: never printed, never passed in an argv.
        tok="$(priv cat -- "$ROOT$TOKEN_FILE" 2>/dev/null || true)"
        tok="${tok//[$' \t\r\n']/}"
        envcmd="$(dk inspect --format '{{json .Config.Env}} {{json .Config.Cmd}}' "$name" 2>/dev/null || true)"
        if [ -z "$tok" ] || [ -z "$envcmd" ]; then
          fail "cannot compare the token with the Env and Cmd of $name"
        elif [[ "$envcmd" == *"$tok"* ]]; then
          fail "the tunnel token appears in the Env or Cmd of $name"
        else
          pass "the tunnel token is not in the Env or Cmd of $name"
        fi
        ;;
      down-page)
        if priv timeout 20 docker exec "$name" nslookup "$EDGE_NAME" >/dev/null 2>&1; then
          pass "container DNS resolves the Cloudflare edge name"
        else
          fail "container DNS cannot resolve the Cloudflare edge name (a LAN resolver needs an exception in /etc/platform/egress-allow.cidrs)"
        fi
        ;;
    esac
  done <<<"$ps"
}

do_checks() {
  local ps problems line
  check_owned "install directory" "$ROOT$INSTALL_DIR" 755 || true
  check_owned "dynamic directory" "$ROOT$INSTALL_DIR/dynamic" 755 || true
  check_owned "down-page directory" "$ROOT$INSTALL_DIR/down-page" 755 || true
  check_owned "compose.yaml" "$ROOT$INSTALL_DIR/compose.yaml" 644 || true
  check_payload "compose.yaml" "$ROOT$INSTALL_DIR/compose.yaml" payload_compose
  check_owned "dynamic.yml" "$ROOT$INSTALL_DIR/dynamic/dynamic.yml" 644 || true
  check_payload "dynamic.yml" "$ROOT$INSTALL_DIR/dynamic/dynamic.yml" payload_dynamic
  check_owned "down-page index.html" "$ROOT$INSTALL_DIR/down-page/index.html" 644 || true
  check_payload "down-page index.html" "$ROOT$INSTALL_DIR/down-page/index.html" payload_index
  check_owned "docker-gid.env" "$ROOT$GID_FILE" 644 || true

  run_check "token file" chk_token_file
  run_check "ingress env file" chk_env_file
  run_check "docker socket" chk_socket
  run_check "token group is private" chk_token_group
  run_check "stored DOCKER_GID matches the socket group" chk_stored_gid
  run_check "network $NETWORK" chk_network

  if ps="$(stack_ps 2>/dev/null)"; then
    problems="$(stack_problems "$ps")"
    if [ -z "$problems" ]; then
      pass "the ${#SERVICES[@]} containers are running and healthy"
    else
      while IFS= read -r line; do fail "$line"; done <<<"$problems"
    fi
    container_checks "$ps"
  else
    fail "cannot read the state of the compose project $PROJECT"
  fi
}

do_report() {
  require_privilege
  do_checks
  if [ "$FAILURES" -gt 0 ]; then
    printf 'install-ingress: %d check(s) failed\n' "$FAILURES"
    [ "$1" = "status" ] || exit 1
  else
    printf 'install-ingress: all checks passed\n'
  fi
}

# ---- verify --live (client-driven) ----

readonly LIVE_APP="ingress-livetest"
readonly LIVE_SIBLING="ingress-livetest-sibling"
readonly LIVE_CURL="ingress-livetest-curl"
readonly LIVE_HOSTILE="ingress-livetest-hostile"
readonly LIVE_NAMES="$LIVE_APP $LIVE_SIBLING $LIVE_CURL $LIVE_HOSTILE"
# Every fixture runs as hardened as the stack itself: no capabilities, no new privileges, small limits, non-root, and a
# tmpfs /tmp (the busybox listener writes its page and pid there).
readonly LIVE_HARDEN=(--cap-drop ALL --security-opt no-new-privileges:true --memory 32m --pids-limit 64 --user 65534:65534 --tmpfs /tmp)
# The hostile fixture carries a competing, high-priority traefik.* router for its own host. The deny router outranks
# it, so /_jobs on that host must still answer 503. (2147483647, one above the deny, WOULD win: that is why the deploy
# path must reject every traefik.* label; this probe pins the documented guarantee for a high but lower priority.)
readonly HOSTILE_PRIORITY=2147483645
# Pinned by exact tag and digest (same rule as compose.yaml). The test app image is the one compose.yaml already pins.
readonly LIVE_IMAGE="docker.io/library/busybox:1.37.0@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
readonly CURL_IMAGE="docker.io/curlimages/curl:8.23.0@sha256:11e64e28c5f58c8d93ee95fcf22ac055f48b0bc440e0ce7d8013bbb5ad6aa8ac"
readonly CID_RE='^[0-9a-f]{12,64}$'
# The /_jobs probe set: <variant name>|<request path>. The expected code of each is recorded in dynamic.yml.
readonly LIVE_VARIANTS=(
  "exact|/_jobs"
  "sub|/_jobs/x"
  "enc-underscore|/%5Fjobs/x"
  "double-slash|//_jobs/x"
  "dot-segments|/a/../_jobs/x"
  "semicolon|/_jobs/;x"
  "upper|/_JOBS/x"
  "mixed-case|/_Jobs"
  "enc-slash|/_jobs%2Fx"
  "enc-backslash|/_jobs%5Cx"
  "enc-semicolon|/_jobs%3Bx"
  "enc-percent|/_jobs%25x"
  "enc-question|/_jobs%3Fx"
  "enc-hash|/_jobs%23x"
  "enc-null|/_jobs%00x"
)
# No hung connection may block the cleanup trap from ever running.
readonly LIVE_SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

LIVE_IDS=()
LIVE_WAIT_PID=""
PROBE_CODE=""
PROBE_BODY=""
FRIENDLY=""
PROBE_RC=0
LIVE_SLEEP="${INSTALL_INGRESS_LIVE_SLEEP:-1}"
HOLD_TTY="${INSTALL_INGRESS_HOLD_TTY:-/dev/tty}"
HOLD_TIMEOUT="${INSTALL_INGRESS_HOLD_TIMEOUT:-600}"

# live_run <remote command...>: as the administrator over ssh with sudo (arguments are quoted for the remote shell);
# locally without ssh when INSTALL_INGRESS_LIVE_LOCAL is set (tests).
live_run() {
  if [ -n "${INSTALL_INGRESS_LIVE_LOCAL:-}" ]; then
    "$@" </dev/null
  else
    ssh -o BatchMode=yes "${LIVE_SSH_OPTS[@]}" -- "$HOST" "sudo -n $(printf '%q ' "$@")" </dev/null
  fi
}
ldk() { live_run docker "$@"; }

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
live_cleanup() {
  trap '' INT TERM HUP
  [ -z "$LIVE_WAIT_PID" ] || kill "$LIVE_WAIT_PID" 2>/dev/null || true
  # Only containers this run created (ids captured from docker run) are ever removed, and by id.
  if [ "${#LIVE_IDS[@]}" -gt 0 ]; then
    if ldk rm -f "${LIVE_IDS[@]}" >/dev/null 2>&1; then
      LIVE_IDS=()
    else
      err "install-ingress: could not remove the test containers; remove them by hand: ssh <alias> sudo docker rm -f $LIVE_NAMES"
    fi
  fi
  cleanup
}

live_sleep() { sleep "$LIVE_SLEEP"; }

# recorded_code <variant>: the code recorded for the variant in the variants block of the embedded dynamic.yml.
recorded_code() {
  payload_dynamic | awk -F ' [|] ' -v n="# $1" '/^# variants-begin$/ { on = 1; next } /^# variants-end$/ { on = 0 } on && $1 == n { print $2; exit }'
}

# friendly_text: the heading of the embedded down page (the friendly body marker).
friendly_text() {
  payload_index | sed -n 's#.*<h1>\(.*\)</h1>.*#\1#p' | head -n 1
}

# ping_port: the Traefik ping port, taken from the embedded compose.yaml.
ping_port() {
  payload_compose | sed -n 's#^ *TRAEFIK_ENTRYPOINTS_PING_ADDRESS: *[^:]*:\([0-9][0-9]*\)$#\1#p' | head -n 1
}

# curl_probe <host> <path>: sets PROBE_CODE (000 when curl failed), PROBE_BODY and PROBE_RC. Sent from the curl
# container straight to traefik:80 with the given Host header, path untouched.
curl_probe() {
  local raw
  PROBE_RC=0
  raw="$(ldk exec "$LIVE_CURL" curl -s --path-as-is --max-time 10 -H "Host: $1" -w '\n%{http_code}' "http://traefik:80$2" 2>/dev/null)" || PROBE_RC=$?
  PROBE_CODE="${raw##*$'\n'}"
  PROBE_BODY="${raw%$'\n'*}"
  [[ "$PROBE_CODE" =~ ^[0-9]{3}$ ]] || { PROBE_CODE="000"; PROBE_BODY=""; }
}

# expect_probe <label> <host> <path> <want code> <want friendly body: yes|no> [attempts]: polls (bounded) because the
# Docker provider reloads asynchronously.
expect_probe() {
  local label="$1" host="$2" path="$3" want="$4" body="$5" attempts="${6:-1}" i=1
  while :; do
    curl_probe "$host" "$path"
    if [ "$PROBE_CODE" = "$want" ] && { [ "$body" = "no" ] || [[ "$PROBE_BODY" == *"$FRIENDLY"* ]]; }; then
      pass "$label"
      return 0
    fi
    [ "$i" -lt "$attempts" ] || break
    i=$((i + 1))
    live_sleep
  done
  if [ "$PROBE_CODE" = "$want" ]; then
    fail "$label: status $PROBE_CODE as wanted but the friendly body is missing"
  else
    fail "$label: status $PROBE_CODE, want $want"
  fi
  return 1
}

# app_log_has <container> <ERE>: true when the container's log matches (case-insensitive).
app_log_has() {
  local log
  log="$(ldk logs "$1" 2>&1)" || { fail "cannot read the log of $1"; return 0; }
  grep -qiE -- "$2" <<<"$log"
}

# start_fixture <fixed container name> <docker run command...>: the id is tracked for the cleanup trap. A failed run (or
# an unusable id) may still have left a container behind, so the fixed name is force-removed before giving up.
start_fixture() {
  local name="$1" cid
  shift
  cid="$("$@")" || { ldk rm -f "$name" >/dev/null 2>&1 || true; die "could not create a test container ($*)"; }
  [[ "$cid" =~ $CID_RE ]] || { ldk rm -f "$name" >/dev/null 2>&1 || true; die "docker run returned an unexpected container id; remove by hand: ssh <alias> sudo docker rm -f $LIVE_NAMES"; }
  LIVE_IDS+=("$cid")
}

# listener_cmd: a busybox httpd with request-line logging (-vv) whose process can be killed while the container
# stays up (sleep takes over as the container's main process afterwards).
listener_cmd() {
  printf '%s' 'echo livetest-ok > /tmp/index.html; httpd -f -vv -p 8080 -h /tmp & echo $! > /tmp/httpd.pid; wait $!; exec sleep 3600'
}

do_live() {
  local domain existing app_host sibling_host nohost hostile_host spec name path want port
  { [ -n "$HOST" ] || [ -n "${INSTALL_INGRESS_LIVE_LOCAL:-}" ]; } || die "verify --live needs --host" 2
  TMP="$(mktemp -d)"
  trap live_cleanup EXIT
  # An interrupt must run the EXIT trap (which removes the test containers).
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  FRIENDLY="$(friendly_text)"
  [ -n "$FRIENDLY" ] || die "the embedded down page has no <h1> to use as the friendly body marker"
  port="$(ping_port)"
  [[ "$port" =~ ^[0-9]+$ ]] || die "cannot read the Traefik ping port from the embedded compose.yaml"

  domain="$(live_run cat -- "$ROOT$ENV_FILE" | sed -n 's/^PLATFORM_DOMAIN=//p')" || die "cannot read $ENV_FILE over ssh as the administrator"
  valid_domain "$domain" || die "PLATFORM_DOMAIN on the host is missing or invalid"
  app_host="$LIVE_APP.$domain"
  sibling_host="$LIVE_SIBLING.$domain"
  nohost="ingress-livetest-nohost.$domain"

  existing="$(ldk ps -a -q --filter "label=platform.app=$LIVE_APP")" || die "cannot list containers over ssh as the administrator"
  [ -z "$existing" ] || die "a container labelled platform.app=$LIVE_APP already exists (a leftover is publicly routable behind Access); remove it first: ssh <alias> sudo docker rm -f $LIVE_NAMES"
  existing="$(ldk ps -a -q --filter "name=$LIVE_APP")" || die "cannot list containers over ssh as the administrator"
  [ -z "$existing" ] || die "a container named $LIVE_APP* already exists; remove it first: ssh <alias> sudo docker rm -f $LIVE_NAMES"

  # (1) labelled app with a real listener and exactly one exposed port, (2) unlabelled sibling, (3) curl client,
  # (4) hostile app: platform.app plus a competing high-priority traefik.* router for its own host.
  hostile_host="$LIVE_HOSTILE.$domain"
  start_fixture "$LIVE_APP" ldk run -d --name "$LIVE_APP" --network "$NETWORK" "${LIVE_HARDEN[@]}" --label "platform.app=$LIVE_APP" --expose 8080 "$LIVE_IMAGE" sh -c "$(listener_cmd)"
  start_fixture "$LIVE_SIBLING" ldk run -d --name "$LIVE_SIBLING" --network "$NETWORK" "${LIVE_HARDEN[@]}" --expose 8080 "$LIVE_IMAGE" sh -c "$(listener_cmd)"
  start_fixture "$LIVE_CURL" ldk run -d --name "$LIVE_CURL" --network "$NETWORK" "${LIVE_HARDEN[@]}" --entrypoint sleep "$CURL_IMAGE" 3600
  start_fixture "$LIVE_HOSTILE" ldk run -d --name "$LIVE_HOSTILE" --network "$NETWORK" "${LIVE_HARDEN[@]}" --label "platform.app=$LIVE_HOSTILE" \
    --label "traefik.http.routers.$LIVE_HOSTILE.rule=Host(\`$hostile_host\`)" --label "traefik.http.routers.$LIVE_HOSTILE.priority=$HOSTILE_PRIORITY" \
    --expose 8080 "$LIVE_IMAGE" sh -c "$(listener_cmd)"

  # Positive control: an unreachable Traefik must not pass. Polls while the provider picks the container up.
  if expect_probe "positive control: a normal path reaches the labelled app (200)" "$app_host" "/index.html" 200 no 20; then
    if app_log_has "$LIVE_APP" 'index\.html'; then pass "positive control: the request appears in the app's own log"; else fail "positive control: the request does not appear in the app's log (the log check cannot be trusted)"; fi
  fi

  # Unmatched host and the unlabelled sibling's name: the friendly 503, never the sibling.
  expect_probe "unmatched host answers the friendly 503 on /" "$nohost" "/" 503 yes || true
  expect_probe "unmatched host answers the friendly 503 on a non-root path" "$nohost" "/some/path" 503 yes || true
  expect_probe "unlabelled sibling name answers the friendly 503 on /" "$sibling_host" "/" 503 yes || true
  expect_probe "unlabelled sibling name answers the friendly 503 on a non-root path" "$sibling_host" "/sibling-probe-x" 503 yes || true
  if app_log_has "$LIVE_SIBLING" 'sibling-probe-x'; then fail "the unlabelled sibling received a request (it must not be routed)"; else pass "the unlabelled sibling's log shows no routed request"; fi

  # Every /_jobs variant: the code recorded in dynamic.yml, friendly body for 503, never in the app's log.
  for spec in "${LIVE_VARIANTS[@]}"; do
    name="${spec%%|*}"
    path="${spec#*|}"
    want="$(recorded_code "$name")"
    if ! [[ "$want" =~ ^[0-9]{3}$ ]]; then fail "/_jobs variant $name: no recorded code in the dynamic.yml variants block"; continue; fi
    if [ "$want" = "503" ]; then
      expect_probe "/_jobs variant $name answers the recorded 503 with the friendly body" "$app_host" "$path" 503 yes || true
    else
      expect_probe "/_jobs variant $name answers the recorded $want" "$app_host" "$path" "$want" no || true
    fi
    if app_log_has "$LIVE_APP" 'jobs'; then fail "/_jobs variant $name reached the app (its log mentions the path)"; else pass "/_jobs variant $name is absent from the app's log"; fi
  done

  # A hostile label cannot bypass the deny: the app is reachable through its own competing router (positive control),
  # yet /_jobs on it answers the friendly 503 and never reaches it.
  if expect_probe "hostile-label app: a normal path reaches it through its own router (200)" "$hostile_host" "/index.html" 200 no 20; then
    expect_probe "hostile-label app: /_jobs still answers the friendly 503" "$hostile_host" "/_jobs" 503 yes || true
    expect_probe "hostile-label app: /_jobs/x still answers the friendly 503" "$hostile_host" "/_jobs/x" 503 yes || true
    if app_log_has "$LIVE_HOSTILE" 'jobs'; then fail "hostile-label app: a /_jobs request reached it (its log mentions the path)"; else pass "hostile-label app: /_jobs is absent from its log"; fi
  fi
  # Not needed any more, and it must not stay routable during a hold.
  ldk stop -t 1 "$LIVE_HOSTILE" >/dev/null 2>&1 || fail "could not stop the hostile-label app"

  # The ping port is not reachable from a sibling container (refused, not a response and not a timeout).
  PROBE_RC=0
  ldk exec "$LIVE_CURL" curl -s -o /dev/null --connect-timeout 3 --max-time 5 "http://traefik:$port/ping" >/dev/null 2>&1 || PROBE_RC=$?
  case "$PROBE_RC" in
    7) pass "the Traefik ping port refuses a connection from a sibling container" ;;
    0) fail "the Traefik ping port answered a sibling container (it must be loopback only)" ;;
    28) fail "the Traefik ping port timed out instead of refusing (filtered rather than closed)" ;;
    *) fail "the Traefik ping port probe ended with curl exit $PROBE_RC, want 7 (connection refused)" ;;
  esac

  # Container up, listener dead: 502 with the friendly body (the labelled test container has no healthcheck).
  # shellcheck disable=SC2016 # expanded by the shell inside the container
  if ldk exec "$LIVE_APP" sh -c 'kill "$(cat /tmp/httpd.pid)"' >/dev/null 2>&1; then
    expect_probe "a killed listener in a running container answers the friendly 502" "$app_host" "/index.html" 502 yes 10 || true
  else
    fail "could not kill the test app's listener"
  fi

  # Stopped container: 503 with the friendly body (polled: the provider reloads asynchronously). A persistent 502 fails.
  if ldk stop -t 1 "$LIVE_APP" >/dev/null 2>&1; then
    if expect_probe "a stopped app answers the friendly 503 on /" "$app_host" "/" 503 yes 20; then
      expect_probe "a stopped app answers the friendly 503 on a non-root path" "$app_host" "/some/path" 503 yes || true
    elif [ "$PROBE_CODE" = "502" ]; then
      fail "the stopped app still answers 502 (the router is not gone); the down page is not shown"
    fi
  else
    fail "could not stop the test app"
  fi

  if [ "$HOLD" -eq 1 ] && [ "$FAILURES" -eq 0 ]; then
    live_hold "$app_host" "$domain"
  elif [ "$HOLD" -eq 1 ]; then
    info "hold skipped: automated probes failed"
  fi

  if ldk rm -f "${LIVE_IDS[@]}" >/dev/null; then
    LIVE_IDS=()
    pass "test containers removed"
  else
    fail "could not remove the test containers"
  fi

  if [ "$FAILURES" -gt 0 ]; then
    printf 'install-ingress: %d live check(s) failed\n' "$FAILURES"
    exit 1
  fi
  printf 'install-ingress: all live checks passed\n'
}

# live_hold <app host> <domain>: restart the test app, wait for the user's browser login through the real tunnel, then
# judge Traefik's access log (stdout, docker logs --since a host-clock timestamp taken at the hold start). Only lines
# that carry Cf-Connecting-Ip count (the script's own probes never do), and only those for the test host or its page.
live_hold() {
  local app_host="$1" tid since lines entries ours wrong i
  if ! ldk start "$LIVE_APP" >/dev/null 2>&1; then fail "hold: could not restart the test app"; return 0; fi
  i=1
  while ! { curl_probe "$app_host" "/index.html"; [ "$PROBE_CODE" = "200" ]; }; do
    [ "$i" -lt 20 ] || { fail "hold: the restarted test app is not routed again (last status $PROBE_CODE)"; return 0; }
    i=$((i + 1))
    live_sleep
  done
  tid="$(ldk ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=traefik")" || { fail "hold: cannot find the traefik container"; return 0; }
  [[ "$tid" =~ $CID_RE ]] || { fail "hold: cannot find the traefik container"; return 0; }
  # The window is the host's own clock (epoch seconds with a fraction), which docker logs --since accepts: it does not
  # depend on how stdout and stderr interleave over ssh.
  since="$(live_run date -u +%s.%N)" || { fail "hold: cannot read the host clock"; return 0; }
  [[ "$since" =~ ^[0-9]+\.[0-9]+$ ]] || { fail "hold: the host clock returned an unusable timestamp"; return 0; }
  info ""
  info "HOLD: open https://$app_host in a browser, complete the login, then press Enter (timeout ${HOLD_TIMEOUT}s)"
  if ( : <"$HOLD_TTY" ) 2>/dev/null; then
    read -r -t "$HOLD_TIMEOUT" <"$HOLD_TTY" || true
  else
    sleep "$HOLD_TIMEOUT" &
    LIVE_WAIT_PID=$!
    wait "$LIVE_WAIT_PID" || true
    LIVE_WAIT_PID=""
  fi
  # stdout only: the access log is stdout, stderr carries Traefik's own diagnostics.
  lines="$(ldk logs --since "$since" "$tid" 2>/dev/null)" || { fail "hold: cannot read the traefik log after the hold"; return 0; }
  entries="$(grep -F 'Cf-Connecting-Ip' <<<"$lines" || true)"
  if [ -z "$entries" ]; then
    fail "hold: no request that carries Cf-Connecting-Ip arrived through the real tunnel after the hold began"
    fail "hold: the tunnel entry's Host could not be checked (no entry)"
    return 0
  fi
  # Other apps may receive tunnel traffic during the hold: only entries for the test host, or for the test page under
  # another host (a wrong Host), are judged.
  ours="$(grep -F "\"RequestHost\":\"$app_host\"" <<<"$entries" || true)"
  if [ -n "$ours" ]; then
    pass "hold: a request through the real tunnel (Cf-Connecting-Ip) was seen"
    pass "hold: the tunnel entry's Host equals the public test hostname"
    return 0
  fi
  wrong="$(grep -E '"RequestPath":"(/|/index\.html)"' <<<"$entries" || true)"
  if [ -z "$wrong" ]; then
    fail "hold: tunnel requests arrived but none for the test hostname or its page (other apps' traffic is ignored)"
    fail "hold: the tunnel entry's Host could not be checked (no entry for the test host or page)"
    return 0
  fi
  pass "hold: a request through the real tunnel (Cf-Connecting-Ip) was seen"
  fail "hold: the tunnel entry's Host is not the public test hostname"
}

# ---- main ----

main() {
  local cmd="install" host="" live=0
  HOST=""
  HOLD=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      install | status | verify) cmd="$1"; shift ;;
      --live) live=1; shift ;;
      --hold) HOLD=1; shift ;;
      --host) { [ "$#" -ge 2 ] && [ -n "$2" ]; } || die "missing value for --host" 2; host="$2"; shift 2 ;;
      -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  case "$host" in -*) die "refusing option-looking --host: $host" 2 ;; esac
  if [ "$live" -eq 1 ] && [ "$cmd" != "verify" ]; then die "--live is only valid with verify" 2; fi
  if [ "$HOLD" -eq 1 ] && [ "$live" -ne 1 ]; then die "--hold is only valid with verify --live" 2; fi
  [[ "$HEALTH_TIMEOUT" =~ ^[0-9]+$ ]] || die "INSTALL_INGRESS_HEALTH_TIMEOUT must be a whole number of seconds" 2

  if [ "$live" -eq 1 ]; then
    HOST="$host"
    do_live
    exit 0
  fi

  if [ -n "$host" ]; then
    exec ssh -o BatchMode=yes -- "$host" "bash -s -- $cmd" < "${BASH_SOURCE[0]}"
  fi

  case "$cmd" in
    install) do_install ;;
    status | verify) do_report "$cmd" ;;
  esac
}

main "$@"
exit 0
