#!/usr/bin/env bash
# install-ingress.sh: install, check and live-test the ingress stack on the app host (run yourself, not Claude).
#
# The stack (cloudflared, Traefik routing from files only, the "app is down" page) is described by
# platform/ingress/compose.yaml and platform/ingress/dynamic.yml. It runs as the Compose project platform-ingress
# from /opt/platform/ingress and joins the `platform` Docker network, which this script creates if absent (bridge,
# IPv6 off, default br- bridge name). No port is published and no firewall rule is touched.
#
# Host-side inputs (you create them; the installer never writes secrets and never edits /etc/group):
#   /etc/platform/cloudflared.token   the tunnel token: regular file, owner root, group gid 64321, mode exactly 0640
#   /etc/platform/ingress.env         PLATFORM_DOMAIN=<your domain>: root-owned, not group/world writable
#   /etc/platform/access.env          ACCESS_TEAM_DOMAIN= and ACCESS_AUD= (read by platform deploy): checked by status/verify
#   the `deploy` group (install-deploy-user.sh creates it): the dynamic/ directory is root:deploy 1775 so the deploy user
#   can write its own app-<app>.yml route files but cannot replace or delete root's dynamic.yml
#   a group with gid 64321 that has no members, is no account's primary group and is not the Docker socket's group
#   (cloudflared gets that gid through group_add in compose.yaml and so can read the token; nobody else can)
# Traefik has no Docker provider and no Docker socket: routes come only from files in the dynamic/ directory. The
# Docker socket's group id is still read with stat (never a docker call), only to refuse a token group that equals it.
#
# The three payload files (compose.yaml, dynamic.yml, down-page/index.html) are embedded below
# (BEGIN-PAYLOAD/END-PAYLOAD) because the host has no checkout: `platform/lint/embed-payloads.sh` regenerates them
# from the tracked sources (`make embed`) and `make lint` fails if they differ.
#
# Usage: install-ingress.sh [install|status|verify] [--host ALIAS]
#        install-ingress.sh verify --live [--hold] --host ALIAS
#   install   checks every precondition first (token file, domain, token group) and runs no docker
#             command until they all pass; then places the files root-owned under /opt/platform/ingress, removes the
#             retired ingress-proxy network and docker-gid.env if present, creates the network, brings the stack up
#             (--remove-orphans drops a live socket-proxy container) and waits (bounded) for every container to be
#             healthy. Idempotent: a second run with unchanged inputs reports "already:" for every item and makes no
#             mutating docker call.
#   status    report every check (PASS/FAIL), exit 0
#   verify    the same checks, exit 1 on any FAIL
#   verify --live   client-driven end-to-end probe set; nothing is created without this flag. Over ssh (sudo docker)
#             it starts four disposable, hardened containers (a test app with a route file, an unrouted sibling, a curl
#             client, and a hostile app that carries traefik.* labels but no route file and so must not be routed),
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
# INSTALL_INGRESS_HOLD_TIMEOUT, INSTALL_INGRESS_AS_DEPLOY (the prefix that runs a command as the deploy user). The docker, stat and getent commands are the ones on PATH, so a test puts stubs there.
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
readonly ACCESS_FILE="/etc/platform/access.env"
readonly GID_FILE="/opt/platform/ingress/docker-gid.env"
# The old compose file declared the network without a name:, so compose created it as <project>_<key>.
readonly OLD_NETWORK_BARE="ingress-proxy"
readonly OLD_NETWORK="platform-ingress_ingress-proxy"
readonly DEPLOY_GROUP="deploy"
readonly TEAM_RE='^[a-z0-9-]+\.cloudflareaccess\.com$'
readonly AUD_RE='^[0-9a-f]{64}$'
readonly PROJECT="platform-ingress"
readonly NETWORK="platform"
readonly SERVICES=(cloudflared traefik down-page)
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

# The prefix that runs a command as the deploy user (tests substitute a stub through INSTALL_INGRESS_AS_DEPLOY).
if [ -n "${INSTALL_INGRESS_AS_DEPLOY+set}" ]; then
  read -r -a AS_DEPLOY <<<"$INSTALL_INGRESS_AS_DEPLOY"
else
  AS_DEPLOY=(sudo -n -u "$DEPLOY_GROUP")
fi

PERM_CTX=local
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
payload_compose_yaml() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# Ingress stack: the single front door of the app host (no published ports; traffic arrives over the tunnel).
#
#   cloudflared  -> traefik -> app containers on the `platform` network
#   traefik      -> reads routes from files only (no Docker access of any kind)
#   down-page    -> supplies the friendly "app is down" body that the errors middleware shows
#
# Host-side inputs (never written here): PLATFORM_DOMAIN (the env file), the tunnel token file mounted into
# cloudflared.
#
# Rules this file keeps (platform/ingress/test_ingress_stack.sh enforces them):
# - It stays inside a small YAML subset (block style only) so the tests can read it without a YAML library.
# - Traefik is configured ONLY through TRAEFIK_* environment variables, and has no `command:`. Traefik ignores
#   its environment as soon as any command-line flag is present, and `traefik healthcheck` (no --ping flag) reads
#   the same environment, so the server and its healthcheck cannot drift apart.
# - Apps carry the single label platform.app=<name> (for `platform ls` and scoping, not routing). No service in this
#   file has it. Routes live in app-<app>.yml files in the dynamic directory.
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
      # Routing comes only from files: dynamic.yml plus one app-<app>.yml per app, written by platform deploy.
      # There is no Docker provider, so Traefik has no Docker API access and cannot read any container's environment.
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
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/ingress/compose.yaml

# BEGIN-PAYLOAD platform/ingress/dynamic.yml
payload_dynamic_yml() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# Traefik file-provider configuration (installed in the dynamic/ directory next to compose.yaml).
#
# One chain, one mechanism for "not served":
#   - the /_jobs deny router and the lowest-priority catch-all both send to the `empty` service (no servers),
#     which Traefik answers with 503, so the request never reaches an app;
#   - the `errors` middleware, attached to the web entrypoint in compose.yaml (errors@file), replaces the body of
#     any 502 to 504 (status preserved) with the page fetched from the down-page service;
#   - the down-page service serves that page with 200 and no router targets it;
#   - a stopped app answers 503 (not 502, which Cloudflare replaces with its own page) only because its route file
#     carries a health check, rendered by platform/deploy/deploy.sh from the app's health_path.
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
payload_index_html() {
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

# access_value <key>: the lines KEY=VALUE of the access env file, values only, one per line.
# shellcheck disable=SC2329 # invoked by name
access_values() {
  priv grep "^$1=" -- "$ROOT$ACCESS_FILE" | sed "s/^$1=//" || true
}

# chk_access_file: the same file rules as chk_env_file, plus exactly one valid ACCESS_TEAM_DOMAIN and ACCESS_AUD. Never
# prints a value.
# shellcheck disable=SC2329 # invoked by name through run_check
chk_access_file() {
  local p="$ROOT$ACCESS_FILE" meta mode g o vals
  if ! priv test -e "$p"; then echo "access env file missing: $ACCESS_FILE (run make host-access-env HOST=<alias>, or create it by hand, see platform/ingress/README.md)"; return 0; fi
  if priv test -L "$p"; then echo "access env file is a symlink: $ACCESS_FILE"; return 0; fi
  if ! priv test -f "$p"; then echo "access env file is not a regular file: $ACCESS_FILE"; return 0; fi
  meta="$(priv stat -c '%u:%g %a' -- "$p")" || { echo "cannot stat the access env file"; return 0; }
  mode="${meta##* }"
  if [ "${meta%%:*}" != "0" ]; then echo "access env file is not owned by root (uid:gid/mode '$meta')"; fi
  if [[ "$mode" =~ ^[0-7]{3,4}$ ]]; then
    g="${mode: -2:1}"
    o="${mode: -1}"
    if [ $((g & 2)) -ne 0 ] || [ $((o & 2)) -ne 0 ]; then echo "access env file is group or world writable (mode $mode)"; fi
  else
    echo "access env file mode is not octal ('$mode')"
  fi
  vals="$(access_values ACCESS_TEAM_DOMAIN)"
  if [ -z "$vals" ] || [ "$(wc -l <<<"$vals")" -ne 1 ] || ! [[ "$vals" =~ $TEAM_RE ]]; then
    echo "access env file must hold exactly one valid ACCESS_TEAM_DOMAIN= line (<team>.cloudflareaccess.com)"
  fi
  vals="$(access_values ACCESS_AUD)"
  if [ -z "$vals" ] || [ "$(wc -l <<<"$vals")" -ne 1 ] || ! [[ "$vals" =~ $AUD_RE ]]; then
    echo "access env file must hold exactly one valid ACCESS_AUD= line (64 lowercase hex characters)"
  fi
}

# deploy_gid: prints the numeric gid of the deploy group; returns 1 when it does not exist.
deploy_gid() {
  local entry gid
  entry="$(getent group "$DEPLOY_GROUP" || true)"
  [ -n "$entry" ] || return 1
  IFS=: read -r _ _ gid _ <<<"$entry"
  [[ "$gid" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$gid"
}

# perm_run <root|deploy> <cmd...>: run a command for the dynamic-directory probe, as root or as the deploy user, locally
# (PERM_CTX=local) or on the host over ssh (PERM_CTX=live).
# shellcheck disable=SC2329 # invoked by name
perm_run() {
  local who="$1"
  shift
  if [ "$who" = deploy ]; then set -- "${AS_DEPLOY[@]}" "$@"; fi
  if [ "$PERM_CTX" = live ]; then live_run "$@"; else priv "$@"; fi
}

# chk_deploy_dir: the sticky-directory property, proved as the deploy user (a second uid; mocks cannot): it creates and
# deletes its own app-<probe>.yml, and cannot replace or delete root's dynamic.yml, which must be unchanged afterwards.
# shellcheck disable=SC2329 # invoked by name through run_check
chk_deploy_dir() {
  local d="$ROOT$INSTALL_DIR/dynamic" probe before after meta
  probe="$d/app-zz-perm-probe-$$.yml"
  before="$(perm_run root cat -- "$d/dynamic.yml" 2>/dev/null)" || { echo "cannot read $d/dynamic.yml to probe the deploy user's permissions"; return 0; }
  if ! perm_run deploy touch -- "$probe" >/dev/null 2>&1; then
    echo "the deploy user cannot create a route file in $d (operation: create)"
    return 0
  fi
  # The replace/delete attempts touch the live dynamic.yml, so they run only when the directory is already root-owned
  # and sticky (1775); a misconfigured directory is reported by check_owned, never risked here.
  meta="$(perm_run root stat -c '%u:%g %a' -- "$d" 2>/dev/null)" || meta=""
  if [ "${meta%%:*}" = "0" ] && [ "${meta##* }" = "1775" ]; then
    if perm_run deploy mv -f -- "$probe" "$d/dynamic.yml" >/dev/null 2>&1; then
      echo "the deploy user could replace dynamic.yml (operation: mv over it succeeded)"
    fi
    if perm_run deploy rm -f -- "$d/dynamic.yml" >/dev/null 2>&1; then
      echo "the deploy user could delete dynamic.yml (operation: rm succeeded)"
    fi
  else
    echo "skipped the replace/delete probes of dynamic.yml: the dynamic directory is not root-owned and sticky (1775)"
  fi
  if ! perm_run deploy rm -f -- "$probe" >/dev/null 2>&1; then
    echo "the deploy user cannot delete its own route file (operation: delete)"
    perm_run root rm -f -- "$probe" >/dev/null 2>&1 || true
  fi
  after="$(perm_run root cat -- "$d/dynamic.yml" 2>/dev/null)" || after="<unreadable>"
  if [ "$after" != "$before" ]; then
    echo "dynamic.yml changed while probing as the deploy user"
    # Restore as root from the captured content: temp file, then rename, mode 0644 root:root.
    # shellcheck disable=SC2016 # the $1..$3 expand in the inner sh, by design
    if perm_run root sh -c 'printf "%s\n" "$1" > "$2" && chmod 644 "$2" && chown root:root "$2" && mv -f "$2" "$3"' _ "$before" "$d/.zz-perm-restore-$$" "$d/dynamic.yml" >/dev/null 2>&1; then
      echo "dynamic.yml was restored from its content before the probe"
    else
      perm_run root rm -f -- "$d/.zz-perm-restore-$$" >/dev/null 2>&1 || true
      echo "dynamic.yml could NOT be restored; reinstall it with install-ingress install"
    fi
  fi
}

# chk_dynamic_files: the deploy login can create any file in dynamic/, so every file but root's dynamic.yml must be named
# app-<valid-name>.yml and have exactly the shape platform/deploy/deploy.sh renders (render_route): no priority, middlewares
# or other key, only that app's own router and service. Prints one line per problem; never a file's content.
# The check is deliberately a per-line allowlist, insensitive to order and count: a duplicated or misplaced key is
# refused by Traefik's own parser, not by this guard.
# shellcheck disable=SC2329 # invoked by name through run_check
chk_dynamic_files() {
  local d="$ROOT$INSTALL_DIR/dynamic" names f app body line ln
  local name_re='^app-([a-z][a-z0-9-]{1,30})\.yml$'
  local dom='[a-z0-9-]+(\.[a-z0-9-]+)+'
  names="$(perm_run root find "$d" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null)" || { echo "cannot list $d"; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] && [ "$f" != "dynamic.yml" ] || continue
    if ! [[ "$f" =~ $name_re ]]; then
      echo "unexpected file in the dynamic directory: '$f' is not dynamic.yml or app-<valid-name>.yml"
      continue
    fi
    app="${BASH_REMATCH[1]}"
    body="$(perm_run root cat -- "$d/$f" 2>/dev/null)" || { echo "cannot read $f in the dynamic directory"; continue; }
    ln=0
    while IFS= read -r line || [ -n "$line" ]; do
      ln=$((ln + 1))
      case "$line" in
        "# Generated by platform deploy for $app. Do not edit; removed by platform rm-db.") [ "$ln" -eq 1 ] && continue ;;
        "http:" | "  routers:" | "    app-$app:" | "      entryPoints: [web]" | "      service: app-$app" | \
          "  services:" | "      loadBalancer:" | "        servers:" | \
          "        healthCheck:" | "          interval: 5s" | "          timeout: 3s") continue ;;
      esac
      # The health path is the charset validate-app-yaml.sh allows for health_path (leading / then letters, digits . _ ~ / % -).
      # shellcheck disable=SC2016 # the backticks are literal Traefik rule quoting
      if [[ "$line" =~ ^\ \ \ \ \ \ rule:\ Host\(\`$app\.$dom\`\)$ || "$line" =~ ^\ \ \ \ \ \ \ \ \ \ -\ url:\ http://$app:[0-9]{1,5}$ \
        || "$line" =~ ^\ \ \ \ \ \ \ \ \ \ path:\ /[A-Za-z0-9._~/%-]*$ ]]; then
        continue
      fi
      echo "$f line $ln is not part of the shape platform deploy renders (a route file may only hold the app's own router and service)"
      break
    done <<<"$body"
  done <<<"$names"
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

# place_dir <dir> <mode> [gid]: a root-owned directory; the group is gid (default 0).
place_dir() {
  local dir="$1" mode="$2" gid="${3:-0}"
  if [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(file_meta "$dir")" = "0:$gid $mode" ]; then
    info "already: $dir/"
    return 0
  fi
  # A symlink in place of the directory is removed (the link only, never its target) and replaced by a real directory.
  if [ -L "$dir" ]; then priv rm -f -- "$dir"; fi
  priv mkdir -p -- "$dir"
  priv chown "root:$gid" "$dir"
  priv chmod "$mode" "$dir"
  info "changed: $dir/"
  CHANGED=1
}

# ---- compose helpers ----

compose() {
  dk compose -p "$PROJECT" -f "$ROOT$INSTALL_DIR/compose.yaml" --env-file "$ROOT$ENV_FILE" "$@"
}

# legacy_containers: ids of any leftover socket-proxy container of this project (retired in favour of file routes).
legacy_containers() {
  dk ps -a -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=socket-proxy"
}

# legacy_network_exists: true when the retired ingress-proxy network is still present.
legacy_networks() {
  local names
  names="$(dk network ls --filter "name=${OLD_NETWORK_BARE}" --format '{{.Name}}')" || return 2
  grep -xF -e "$OLD_NETWORK" -e "$OLD_NETWORK_BARE" <<<"$names" || true
}

# retire_gid_file: remove the retired docker-gid.env (idempotent, logged).
retire_gid_file() {
  if [ -e "$ROOT$GID_FILE" ] || [ -L "$ROOT$GID_FILE" ]; then
    priv rm -f -- "$ROOT$GID_FILE"
    info "changed: removed retired $GID_FILE"
    CHANGED=1
  else
    info "already: no $GID_FILE"
  fi
}

# retire_old_network: remove the retired ingress-proxy network once the socket-proxy container is gone.
retire_old_network() {
  local found n
  found="$(legacy_networks)" || die "cannot list docker networks to look for the retired $OLD_NETWORK network"
  if [ -n "$found" ]; then
    while IFS= read -r n; do
      dk network rm "$n" >/dev/null || die "could not remove the retired $n network (is a container still attached?)"
      info "changed: removed retired network $n"
    done <<<"$found"
    CHANGED=1
  else
    info "already: no $OLD_NETWORK network"
  fi
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
  local problems line ps dgid legacy
  require_privilege
  TMP="$(mktemp -d)"

  problems="$(chk_token_file; chk_env_file; chk_token_group)"
  if [ -n "$problems" ]; then
    while IFS= read -r line; do err "install-ingress: $line"; done <<<"$problems"
    print_instructions
    die "preconditions failed; nothing was installed and no docker command was run"
  fi
  dgid="$(deploy_gid)" || die "the $DEPLOY_GROUP group does not exist; run \`make host-deploy-user HOST=<alias> ARGS=\"install --pubkey-file PATH\"\` first. Nothing was installed and no docker command was run"

  payload_compose_yaml > "$TMP/compose.yaml"
  payload_dynamic_yml > "$TMP/dynamic.yml"
  payload_index_html > "$TMP/index.html"

  place_dir "$ROOT$INSTALL_DIR" 755
  place_dir "$ROOT$INSTALL_DIR/dynamic" 1775 "$dgid"
  place_dir "$ROOT$INSTALL_DIR/down-page" 755
  place_file "$TMP/compose.yaml" "$ROOT$INSTALL_DIR/compose.yaml" 644
  place_file "$TMP/dynamic.yml" "$ROOT$INSTALL_DIR/dynamic/dynamic.yml" 644
  place_file "$TMP/index.html" "$ROOT$INSTALL_DIR/down-page/index.html" 644
  retire_gid_file
  ensure_network

  ps="$(stack_ps 2>/dev/null)" || ps=""
  legacy="$(legacy_containers)" || die "cannot list docker containers to look for a retired socket-proxy container"
  if [ "$CHANGED" -eq 1 ] || [ -n "$legacy" ] || [ -n "$(stack_problems "$ps" run)" ]; then
    compose up -d --remove-orphans || die "docker compose up failed"
    info "changed: stack started"
  else
    info "already: stack running"
  fi
  legacy="$(legacy_containers)" || die "cannot list docker containers to look for a retired socket-proxy container"
  [ -z "$legacy" ] || die "a socket-proxy container still exists after compose up --remove-orphans: remove it by hand (docker rm -f $legacy)"
  retire_old_network
  wait_healthy
  info "install-ingress: done"
}

# ---- status / verify ----

# check_owned <label> <path> <mode> [gid]: root-owned, group gid (default 0), exactly this mode.
check_owned() {
  local label="$1" path="$2" mode="$3" gid="${4:-0}" meta
  if [ ! -e "$path" ]; then fail "$label missing: $path"; return 1; fi
  if [ -L "$path" ]; then fail "$label is a symlink: $path"; return 1; fi
  meta="$(file_meta "$path")"
  if [ "$meta" = "0:$gid $mode" ]; then pass "$label owner/mode ($meta)"; else fail "$label uid:gid/mode is '$meta', want '0:$gid $mode'"; return 1; fi
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
chk_no_legacy() {
  local ids nets
  if [ -e "$ROOT$GID_FILE" ] || [ -L "$ROOT$GID_FILE" ]; then echo "retired file still present: $GID_FILE (re-run install)"; fi
  if nets="$(legacy_networks)"; then
    if [ -n "$nets" ]; then echo "retired network still present: ${nets//$'\n'/, } (re-run install)"; fi
  else
    echo "cannot list docker networks to check for the retired network"
  fi
  if ids="$(legacy_containers 2>/dev/null)"; then
    if [ -n "$ids" ]; then echo "a socket-proxy container still exists (re-run install)"; fi
  else
    echo "cannot list docker containers to check for a socket-proxy container"
  fi
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
    elif grep -qF "docker.sock" <<<"$out"; then
      fail "$name mounts the Docker socket (no stack container may)"
    else
      pass "$name does not mount the Docker socket"
    fi

    case "$service" in
      traefik)
        out="$(dk inspect --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' "$name" 2>/dev/null || true)"
        if grep -qxF "$NETWORK" <<<"$out"; then pass "traefik is on the $NETWORK network"; else fail "traefik is not on the $NETWORK network"; fi
        # No Docker provider: no TRAEFIK_PROVIDERS_DOCKER_* variable may exist in the running container.
        envcmd="$(dk inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "$name" 2>/dev/null || echo "inspect-failed")"
        if [ "$envcmd" = "inspect-failed" ]; then fail "cannot inspect the environment of $name"
        elif grep -q '^TRAEFIK_PROVIDERS_DOCKER' <<<"$envcmd"; then fail "$name has a TRAEFIK_PROVIDERS_DOCKER_* variable"
        else pass "$name has no Docker provider variable"; fi
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
  local ps problems line dgid
  check_owned "install directory" "$ROOT$INSTALL_DIR" 755 || true
  if dgid="$(deploy_gid)"; then
    check_owned "dynamic directory" "$ROOT$INSTALL_DIR/dynamic" 1775 "$dgid" || true
    if [ -d "$ROOT$INSTALL_DIR/dynamic" ] && [ -f "$ROOT$INSTALL_DIR/dynamic/dynamic.yml" ]; then
      PERM_CTX=local
      run_check "deploy user permissions on the dynamic directory" chk_deploy_dir
      run_check "dynamic directory holds only rendered route files" chk_dynamic_files
    fi
  else
    fail "the $DEPLOY_GROUP group does not exist (run install-deploy-user first)"
  fi
  check_owned "down-page directory" "$ROOT$INSTALL_DIR/down-page" 755 || true
  check_owned "compose.yaml" "$ROOT$INSTALL_DIR/compose.yaml" 644 || true
  check_payload "compose.yaml" "$ROOT$INSTALL_DIR/compose.yaml" payload_compose_yaml
  check_owned "dynamic.yml" "$ROOT$INSTALL_DIR/dynamic/dynamic.yml" 644 || true
  check_payload "dynamic.yml" "$ROOT$INSTALL_DIR/dynamic/dynamic.yml" payload_dynamic_yml
  check_owned "down-page index.html" "$ROOT$INSTALL_DIR/down-page/index.html" 644 || true
  check_payload "down-page index.html" "$ROOT$INSTALL_DIR/down-page/index.html" payload_index_html

  run_check "token file" chk_token_file
  run_check "ingress env file" chk_env_file
  run_check "access env file" chk_access_file
  run_check "token group is private" chk_token_group
  run_check "no retired socket-proxy pieces" chk_no_legacy
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
# The hostile fixture carries a competing, high-priority traefik.* router label for its own host but no route file.
# With no Docker provider the labels are inert, so it must get no route at all (the deploy path still refuses
# traefik.* labels as defence in depth if a Docker provider ever returns).
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
LIVE_ROUTES=()
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
  # Route files this run wrote go first, so nothing stays publicly routed.
  if [ "${#LIVE_ROUTES[@]}" -gt 0 ]; then
    if live_run rm -f -- "${LIVE_ROUTES[@]}" >/dev/null 2>&1; then
      LIVE_ROUTES=()
    else
      err "install-ingress: could not remove the test route files; remove them by hand: ssh <alias> sudo rm -f $ROOT$INSTALL_DIR/dynamic/app-ingress-livetest*.yml"
    fi
  fi
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
  payload_dynamic_yml | awk -F ' [|] ' -v n="# $1" '/^# variants-begin$/ { on = 1; next } /^# variants-end$/ { on = 0 } on && $1 == n { print $2; exit }'
}

# friendly_text: the heading of the embedded down page (the friendly body marker).
friendly_text() {
  payload_index_html | sed -n 's#.*<h1>\(.*\)</h1>.*#\1#p' | head -n 1
}

# ping_port: the Traefik ping port, taken from the embedded compose.yaml.
ping_port() {
  payload_compose_yaml | sed -n 's#^ *TRAEFIK_ENTRYPOINTS_PING_ADDRESS: *[^:]*:\([0-9][0-9]*\)$#\1#p' | head -n 1
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
# file provider reloads asynchronously.
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

# write_route <fixture container name> <public host>: a route file in the shape platform deploy writes (app-<name>.yml),
# placed atomically (temp file + rename) and tracked for cleanup. The body travels base64-encoded so no quoting layer
# (ssh, sudo, remote shell) can alter it.
write_route() {
  local name="$1" host="$2" file body
  file="$ROOT$INSTALL_DIR/dynamic/app-$name.yml"
  # shellcheck disable=SC2016 # the backticks are Traefik rule syntax, not a command substitution
  body="$(printf 'http:\n  routers:\n    app-%s:\n      rule: Host(`%s`)\n      entryPoints: [web]\n      service: app-%s\n  services:\n    app-%s:\n      loadBalancer:\n        servers:\n          - url: http://%s:8080\n' "$name" "$host" "$name" "$name" "$name" | base64 -w0)"
  LIVE_ROUTES+=("$file")
  # shellcheck disable=SC2016 # expanded by the remote shell
  live_run sh -c 'printf %s "$1" | base64 -d > "$2.new" && chmod 644 "$2.new" && mv -f "$2.new" "$2"' _ "$body" "$file" \
    || die "could not write the test route file $file"
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

  # The deploy user's rights on the installed dynamic directory (a second uid): create/delete its own route file, and
  # no replace or delete of root's dynamic.yml.
  PERM_CTX=live
  run_check "deploy user permissions on the dynamic directory" chk_deploy_dir

  existing="$(ldk ps -a -q --filter "label=platform.app=$LIVE_APP")" || die "cannot list containers over ssh as the administrator"
  [ -z "$existing" ] || die "a container labelled platform.app=$LIVE_APP already exists (a leftover is publicly routable behind Access); remove it first: ssh <alias> sudo docker rm -f $LIVE_NAMES"
  existing="$(ldk ps -a -q --filter "name=$LIVE_APP")" || die "cannot list containers over ssh as the administrator"
  [ -z "$existing" ] || die "a container named $LIVE_APP* already exists; remove it first: ssh <alias> sudo docker rm -f $LIVE_NAMES"
  existing="$(live_run sh -c "ls -- $ROOT$INSTALL_DIR/dynamic/app-$LIVE_APP*.yml 2>/dev/null || true")" || die "cannot list the route files over ssh as the administrator"
  [ -z "$existing" ] || die "a leftover route file exists (it would be publicly routed); remove it first: ssh <alias> sudo rm -f $ROOT$INSTALL_DIR/dynamic/app-$LIVE_APP*.yml"

  # (1) platform.app app with a real listener, one exposed port and (below) a route file, (2) unrouted sibling, (3) curl
  # client, (4) hostile app: platform.app plus a competing high-priority traefik.* router, but NO route file.
  hostile_host="$LIVE_HOSTILE.$domain"
  start_fixture "$LIVE_APP" ldk run -d --name "$LIVE_APP" --network "$NETWORK" "${LIVE_HARDEN[@]}" --label "platform.app=$LIVE_APP" --expose 8080 "$LIVE_IMAGE" sh -c "$(listener_cmd)"
  start_fixture "$LIVE_SIBLING" ldk run -d --name "$LIVE_SIBLING" --network "$NETWORK" "${LIVE_HARDEN[@]}" --expose 8080 "$LIVE_IMAGE" sh -c "$(listener_cmd)"
  start_fixture "$LIVE_CURL" ldk run -d --name "$LIVE_CURL" --network "$NETWORK" "${LIVE_HARDEN[@]}" --entrypoint sleep "$CURL_IMAGE" 3600
  start_fixture "$LIVE_HOSTILE" ldk run -d --name "$LIVE_HOSTILE" --network "$NETWORK" "${LIVE_HARDEN[@]}" --label "platform.app=$LIVE_HOSTILE" \
    --label "traefik.http.routers.$LIVE_HOSTILE.rule=Host(\`$hostile_host\`)" --label "traefik.http.routers.$LIVE_HOSTILE.priority=$HOSTILE_PRIORITY" \
    --expose 8080 "$LIVE_IMAGE" sh -c "$(listener_cmd)"

  # The route file appears after Traefik is already running: the file provider must pick it up without a restart.
  write_route "$LIVE_APP" "$app_host"

  # Positive control: an unreachable Traefik must not pass. Polls while the provider picks the route file up.
  if expect_probe "positive control: a normal path reaches the labelled app (200)" "$app_host" "/index.html" 200 no 20; then
    if app_log_has "$LIVE_APP" 'index\.html'; then pass "positive control: the request appears in the app's own log"; else fail "positive control: the request does not appear in the app's log (the log check cannot be trusted)"; fi
  fi

  # Unmatched host and the unrouted sibling's name: the friendly 503, never the sibling.
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

  # Labels route nothing: the hostile app carries a high-priority traefik.* router but no route file, so it has no
  # route at all (friendly 503 on every path) and never receives a request.
  expect_probe "hostile-label app without a route file is not routed on /index.html" "$hostile_host" "/index.html" 503 yes || true
  expect_probe "hostile-label app without a route file is not routed on /_jobs" "$hostile_host" "/_jobs" 503 yes || true
  if app_log_has "$LIVE_HOSTILE" 'index\.html|jobs'; then fail "hostile-label app: a request reached it (its log shows a request path)"; else pass "hostile-label app: its log shows no routed request"; fi
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

  # Stopped container with its route file still present: the backend name no longer resolves, so 502 with the friendly body.
  if ldk stop -t 1 "$LIVE_APP" >/dev/null 2>&1; then
    if expect_probe "a stopped app with a route answers the friendly 502 on /" "$app_host" "/" 502 yes 20; then
      expect_probe "a stopped app with a route answers the friendly 502 on a non-root path" "$app_host" "/some/path" 502 yes || true
    fi
  else
    fail "could not stop the test app"
  fi

  if [ "$HOLD" -eq 1 ] && [ "$FAILURES" -eq 0 ]; then
    live_hold "$app_host" "$domain"
  elif [ "$HOLD" -eq 1 ]; then
    info "hold skipped: automated probes failed"
  fi

  if live_run rm -f -- "${LIVE_ROUTES[@]}" >/dev/null; then
    LIVE_ROUTES=()
    pass "test route files removed"
  else
    fail "could not remove the test route files"
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
