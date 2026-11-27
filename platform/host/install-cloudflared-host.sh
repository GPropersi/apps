#!/usr/bin/env bash
# install-cloudflared-host.sh: lay down the host-network cloudflared compose on a host that is not the app host (run
# yourself, not Claude).
#
# The compose (platform/ingress/compose.host-network.yaml) holds only the self-updating blue and green cloudflared
# supervisor containers on the host network, as the Compose project platform-cloudflared from /opt/platform/cloudflared.
# This installer only PLACES FILES AND CHECKS INPUTS: it never starts, stops or pulls a container, never creates a Docker
# network and never touches a systemd unit (the existing cloudflared.service keeps running). Starting a colour is a
# manual step, printed at the end of `install`.
#
# Host-side inputs (you create them; the installer never writes secrets and never edits /etc/group):
#   /etc/platform/cloudflared.token   the tunnel token: regular file, owner root, group gid 64321, mode exactly 0640,
#                                     non-blank (read only to test that; never printed)
#   /etc/platform/cloudflared.webhook the supervisor's alert webhook: regular file, owner 65532:65532, mode exactly 0600,
#                                     non-empty; only checked (never read, written or printed). On every non-Pi host it
#                                     is a copy of the same webhook the Pi uses (the stronghold drift-check webhook),
#                                     copied by you over a trusted channel, never pasted into chat or git
#   a group with gid 64321 that has no members, is no account's primary group and is not the Docker socket's group
#   (cloudflared gets that gid through group_add in the compose and so can read the token; nobody else can)
# The installer creates /opt/platform/cloudflared (root:root 0755) with compose.yaml (root:root 0644) and the state
# directories /var/lib/cloudflared-supervisor-{blue,green} (65532:65532, 0755; content is never deleted).
#
# The payload file is embedded below (BEGIN-PAYLOAD/END-PAYLOAD) because the host has no checkout:
# `platform/lint/embed-payloads.sh` regenerates it from the tracked source (`make embed`) and `make lint` fails if they
# differ. This installer carries no INSTALLER_STAMP: it is not part of the deploy gate.
#
# Usage: install-cloudflared-host.sh [install|status|verify]        (default: status)
#   install   checks every input first (token, token group, webhook, Docker socket present, no symlinked target
#             directory) and writes nothing until they all pass; then places the compose and the two state directories
#             (prints "already:" or "changed:" per item) and ends with the manual start command. Idempotent.
#   status    report every check (PASS/FAIL), exit 1 on any FAIL; also reports (never fails on) which colour runs,
#             Docker's default logging driver and listeners on 127.0.0.1 ports 20251-20254 that are not ours
#   verify    the same, and additionally `docker compose config -q` on the placed file; a host without Docker
#             (socket missing or docker CLI missing) fails verify but not status; a missing compose plugin fails verify
#
# Exit: 0 ok | 1 failed check, wrong state or unusable privilege | 2 usage error.
#
# Test overrides (env, test-only): INSTALL_CLOUDFLARED_ROOT (path prefix for every host file),
# INSTALL_CLOUDFLARED_SUDO (the privilege prefix; "sudo -n" by default, none when already root),
# INSTALL_CLOUDFLARED_SOCKET (the Docker socket path), INSTALL_CLOUDFLARED_DOCKER (the docker command, default docker).
# The stat, getent, ss, ps and docker commands are the ones on PATH, so a test puts stubs there.
set -euo pipefail

export LC_ALL=C
# groupadd, getent and friends live in /usr/sbin, which a non-root ssh user's PATH lacks
export PATH="$PATH:/usr/sbin:/sbin"

# The dedicated token group. Fixed; it must equal the numeric group_add of the cloudflared services in the compose.
readonly TOKEN_GID=64321
readonly INSTALL_DIR="/opt/platform/cloudflared"
readonly COMPOSE_NAME="compose.yaml"
readonly TOKEN_FILE="/etc/platform/cloudflared.token"
readonly WEBHOOK_FILE="/etc/platform/cloudflared.webhook"
readonly STATE_DIRS=(/var/lib/cloudflared-supervisor-blue /var/lib/cloudflared-supervisor-green)
readonly PROJECT="platform-cloudflared"
readonly COLOURS=(cloudflared-blue cloudflared-green)
readonly PORT_RE='^127\.0\.0\.1:(2025[1-4])$'
ROOT="${INSTALL_CLOUDFLARED_ROOT:-}"
SOCKET="${INSTALL_CLOUDFLARED_SOCKET:-/var/run/docker.sock}"
DOCKER_BIN="${INSTALL_CLOUDFLARED_DOCKER:-docker}"

if [ -n "${INSTALL_CLOUDFLARED_SUDO+set}" ]; then
  read -r -a SUDO <<<"$INSTALL_CLOUDFLARED_SUDO"
elif [ "$EUID" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo -n)
fi

FAILURES=0
TMP=""
DOCKER_STATE=""
DOCKER_WHY=""
LOGGING_DRIVER=""
RUN_PIDS=()
RUN_NAMES=()

info() { printf '%s\n' "$1"; }
err() { printf '%s\n' "$1" >&2; }
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
die() { err "install-cloudflared-host: $1"; exit "${2:-1}"; }

# shellcheck disable=SC2329,SC2317 # invoked through the EXIT trap
cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

# priv <cmd...>: run with privilege; stdin is never forwarded.
priv() { "${SUDO[@]}" "$@" </dev/null; }
dk() { priv "$DOCKER_BIN" "$@"; }

require_privilege() {
  priv true || die "no usable privilege (sudo -n failed): run this as root or with passwordless sudo"
}

# ---- embedded payloads (regenerated by platform/lint/embed-payloads.sh; do not edit between the markers) ----

# BEGIN-PAYLOAD platform/ingress/compose.host-network.yaml
payload_compose_host_network_yaml() {
  cat <<'PLATFORM_PAYLOAD_EOF'
# Cloudflared connectors for hosts that are not the app host: the same self-updating blue/green supervisor pair
# the app host runs (compose.yaml), and nothing else (no Traefik, no down page, no legacy `cloudflared`).
#
# Host network because every origin these tunnels serve is a localhost listener, and the metrics listeners
# (CF_METRICS_A / CF_METRICS_B) are host-loopback addresses. There is no `networks:`, no `ports:` and no `logging:`
# (the journald default applies).
#
# Every command names its colour (never a bare `up`); only one colour runs outside an overlap, and a pin bump
# repins the idle colour only. Both colours start on the regular pin because these hosts start fresh.
#
# Each service must stay identical to the same colour in compose.yaml apart from networking and the image pin:
# platform/ingress/test_cloudflared_host_stack.sh enforces it (the YAML subset forbids anchors and merge keys, so
# the two files cannot share a fragment). Host-side inputs (never written here): the token file, the webhook file
# and the two state directories, laid down by the host-network installer.
name: platform-cloudflared

services:
  cloudflared-blue:
    image: ghcr.io/gpropersi/cloudflared-supervisor:45838827422@sha256:54a6d9c047024919011b9cbf477475085b9bc3a761702ac27b13554f4508d471
    environment:
      TUNNEL_TOKEN_FILE: /run/cloudflared/token
      CF_WEBHOOK_FILE: /run/secrets/cloudflared-webhook
      CF_METRICS_A: 127.0.0.1:20251
      CF_METRICS_B: 127.0.0.1:20252
    volumes:
      - /etc/platform/cloudflared.token:/run/cloudflared/token:ro
      - /etc/platform/cloudflared.webhook:/run/secrets/cloudflared-webhook:ro
      - /var/lib/cloudflared-supervisor-blue:/var/lib/cloudflared-supervisor
    user: "65532:65532"
    group_add:
      - "64321"
    network_mode: host
    restart: unless-stopped
    mem_limit: 192m
    stop_grace_period: 45s
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
    healthcheck:
      test:
        - CMD
        - /usr/local/bin/cloudflared-supervisor.sh
        - --health
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 120s

  cloudflared-green:
    image: ghcr.io/gpropersi/cloudflared-supervisor:45838827422@sha256:54a6d9c047024919011b9cbf477475085b9bc3a761702ac27b13554f4508d471
    environment:
      TUNNEL_TOKEN_FILE: /run/cloudflared/token
      CF_WEBHOOK_FILE: /run/secrets/cloudflared-webhook
      CF_METRICS_A: 127.0.0.1:20253
      CF_METRICS_B: 127.0.0.1:20254
    volumes:
      - /etc/platform/cloudflared.token:/run/cloudflared/token:ro
      - /etc/platform/cloudflared.webhook:/run/secrets/cloudflared-webhook:ro
      - /var/lib/cloudflared-supervisor-green:/var/lib/cloudflared-supervisor
    user: "65532:65532"
    group_add:
      - "64321"
    network_mode: host
    restart: unless-stopped
    mem_limit: 192m
    stop_grace_period: 45s
    cap_drop:
      - ALL
    security_opt:
      - no-new-privileges:true
    read_only: true
    tmpfs:
      - /tmp
    healthcheck:
      test:
        - CMD
        - /usr/local/bin/cloudflared-supervisor.sh
        - --health
      interval: 60s
      timeout: 10s
      retries: 3
      start_period: 120s
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/ingress/compose.host-network.yaml

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

# chk_webhook_file: checked by type, owner, mode and size only; its content is never read.
chk_webhook_file() {
  local p="$ROOT$WEBHOOK_FILE" meta
  if ! priv test -e "$p"; then echo "webhook file missing: $WEBHOOK_FILE"; return 0; fi
  if priv test -L "$p"; then echo "webhook file is a symlink: $WEBHOOK_FILE"; return 0; fi
  if ! priv test -f "$p"; then echo "webhook file is not a regular file: $WEBHOOK_FILE"; return 0; fi
  meta="$(priv stat -c '%u:%g %a' -- "$p")" || { echo "cannot stat the webhook file"; return 0; }
  [ "$meta" = "65532:65532 600" ] || echo "webhook file uid:gid/mode is '$meta', want '65532:65532 600' (owner 65532:65532, mode 0600)"
  if ! priv test -s "$p"; then echo "webhook file is empty"; return 0; fi
}

# chk_token_group: gid 64321 exists, has no members, is nobody's primary group; the socket-group sub-check runs unless
# SKIP_SOCKET_GROUP=1 (Docker absent).
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
  if [ "${SKIP_SOCKET_GROUP:-0}" -ne 1 ] && sgid="$(socket_gid 2>/dev/null)" && [ "$sgid" = "$TOKEN_GID" ]; then
    echo "token group (gid $TOKEN_GID) is the Docker socket's group"
  fi
}

# chk_symlinks: the install and state directories and their parents must not be symlinks.
chk_symlinks() {
  local p
  for p in /opt/platform "$INSTALL_DIR" /var/lib "${STATE_DIRS[@]}"; do
    if priv test -L "$ROOT$p"; then echo "path is a symlink: $p (refusing to place files through it)"; fi
  done
}

print_instructions() {
  err ""
  err "Create the host-side inputs yourself (nothing here writes a secret or edits /etc/group):"
  err "  sudo groupadd --gid $TOKEN_GID cloudflared-token       # once; no members, no account may use it as primary group"
  err "  sudo install -d -m 0755 -o root -g root /etc/platform"
  err "  sudo install -m 0640 -o root -g $TOKEN_GID /dev/null $TOKEN_FILE"
  err "  sudo tee $TOKEN_FILE >/dev/null     # fill it from this host's existing connector token, Enter, Ctrl-D"
  err "  sudo install -m 0600 -o 65532 -g 65532 /dev/null $WEBHOOK_FILE"
  err "  sudo tee $WEBHOOK_FILE >/dev/null   # fill it, then Ctrl-D"
  err "The webhook on every non-Pi host is a copy of the same webhook the Pi uses (the stronghold drift-check webhook):"
  err "copy it yourself over a trusted channel; never paste it into chat or git."
}

# ---- file helpers ----

# place_file <src> <dest> <mode>: copy, own as root, chmod, then atomic rename. Reports already/changed.
place_file() {
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest" && [ "$(file_meta "$dest")" = "0:0 $mode" ]; then
    info "already: $dest"
    return 0
  fi
  priv rm -f -- "$dest.new"
  priv cp -- "$src" "$dest.new"
  priv chown root:root "$dest.new"
  priv chmod "$mode" "$dest.new"
  priv mv -f -- "$dest.new" "$dest"
  info "changed: $dest"
}

# place_dir <dir> <mode>: a root-owned directory. A symlink is refused (the pre-check already failed on it).
place_dir() {
  local dir="$1" mode="$2"
  if [ -L "$dir" ]; then die "directory is a symlink: $dir (nothing further was installed)"; fi
  if [ -d "$dir" ] && [ "$(file_meta "$dir")" = "0:0 $mode" ]; then
    info "already: $dir/"
    return 0
  fi
  # a parent this call creates must not inherit a restrictive umask
  local parent
  parent="$(dirname -- "$dir")"
  if [ ! -d "$parent" ]; then
    priv mkdir -p -- "$parent"
    priv chmod 0755 "$parent"
  fi
  priv mkdir -p -- "$dir"
  priv chown root:root "$dir"
  priv chmod "$mode" "$dir"
  info "changed: $dir/"
}

# place_state_dir <dir>: a supervisor state directory owned by the container user (65532:65532, 0755). A symlink (the
# directory or its parent) is refused; an existing directory is repaired, never deleted or emptied.
place_state_dir() {
  local dir="$1" parent
  parent="$(dirname -- "$dir")"
  if [ -L "$parent" ]; then die "state directory parent is a symlink: $parent (nothing further was installed)"; fi
  if [ -L "$dir" ]; then die "state directory is a symlink: $dir (nothing further was installed)"; fi
  if [ -d "$dir" ] && [ "$(file_meta "$dir")" = "65532:65532 755" ]; then
    info "already: $dir/"
    return 0
  fi
  priv mkdir -p -- "$dir"
  priv chown 65532:65532 "$dir"
  priv chmod 0755 "$dir"
  info "changed: $dir/"
}

# ---- Docker probing (read-only) ----

# docker_probe: sets DOCKER_STATE to absent (no socket or no CLI), unreachable (socket present, daemon not answering) or
# ok, plus DOCKER_WHY and LOGGING_DRIVER.
docker_probe() {
  DOCKER_STATE="ok"
  DOCKER_WHY=""
  LOGGING_DRIVER=""
  if [ ! -e "$SOCKET" ]; then
    DOCKER_STATE="absent"
    DOCKER_WHY="the Docker socket $SOCKET does not exist"
    return 0
  fi
  if ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then
    DOCKER_STATE="absent"
    DOCKER_WHY="the docker CLI is not installed"
    return 0
  fi
  if LOGGING_DRIVER="$(dk info --format '{{.LoggingDriver}}' 2>/dev/null)"; then
    [ -n "$LOGGING_DRIVER" ] || LOGGING_DRIVER="unknown"
  else
    DOCKER_STATE="unreachable"
    DOCKER_WHY="the Docker daemon does not answer"
    LOGGING_DRIVER=""
  fi
}

# container_pids: fills RUN_NAMES and RUN_PIDS with the running colours of the project; returns 1 when docker ps or
# inspect fails.
container_pids() {
  local svc id ids pid
  RUN_NAMES=()
  RUN_PIDS=()
  for svc in "${COLOURS[@]}"; do
    ids="$(dk ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter "label=com.docker.compose.service=$svc" 2>/dev/null)" || return 1
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      pid="$(dk inspect --format '{{.State.Pid}}' "$id" 2>/dev/null)" || return 1
      [[ "$pid" =~ ^[0-9]+$ ]] || return 1
      RUN_NAMES+=("$svc")
      RUN_PIDS+=("$pid")
    done <<<"$ids"
  done
  return 0
}

# owned_by_container <pid>: the pid or one of its ancestors (ps -o ppid=, up to pid 1) is a running container's pid.
owned_by_container() {
  local cur="$1" p hops=0 parent
  [[ "$cur" =~ ^[0-9]+$ ]] || return 1
  while [ "$cur" -ge 1 ] && [ "$hops" -lt 64 ]; do
    for p in "${RUN_PIDS[@]}"; do [ "$p" != "$cur" ] || return 0; done
    [ "$cur" -ne 1 ] || return 1
    parent="$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d '[:space:]')" || return 1
    [[ "$parent" =~ ^[0-9]+$ ]] || return 1
    cur="$parent"
    hops=$((hops + 1))
  done
  return 1
}

# check_listeners <known|unknown>: warn (never fail) about a listener on 127.0.0.1:20251-20254 that is not ours.
check_listeners() {
  local known="$1" lines line laddr port pid=""
  local -a f
  if ! command -v ss >/dev/null 2>&1; then info "note: ss not found; the listener check was skipped"; return 0; fi
  if ! lines="$(priv ss -ltnpH 2>/dev/null)"; then info "note: ss failed; the listener check was skipped"; return 0; fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r -a f <<<"$line"
    laddr="${f[3]:-}"
    [[ "$laddr" =~ $PORT_RE ]] || continue
    port="${BASH_REMATCH[1]}"
    pid=""
    if [[ "$line" =~ pid=([0-9]+) ]]; then pid="${BASH_REMATCH[1]}"; fi
    if [ "$known" = "known" ]; then
      if [ -n "$pid" ] && owned_by_container "$pid"; then continue; fi
      info "warning: port $port on 127.0.0.1 is held by something that is not a $PROJECT container (pid ${pid:-unknown})"
    else
      info "warning: port $port on 127.0.0.1 has a listener, owner unknown (docker: unavailable)"
    fi
  done <<<"$lines"
}

# ---- install ----

do_install() {
  local problems="" line sd tmpc
  SKIP_SOCKET_GROUP=0
  problems="$(chk_token_file)"$'\n'"$(chk_token_group)"$'\n'"$(chk_webhook_file)"$'\n'"$(chk_symlinks)"
  if [ ! -e "$SOCKET" ]; then problems+=$'\n'"Docker must be installed first: the Docker socket $SOCKET does not exist"; fi
  problems="$(sed '/^$/d' <<<"$problems")"
  if [ -n "$problems" ]; then
    while IFS= read -r line; do err "problem: $line"; done <<<"$problems"
    print_instructions
    err "install-cloudflared-host: inputs are not ready; nothing was written"
    exit 1
  fi

  TMP="$(mktemp -d)"
  tmpc="$TMP/$COMPOSE_NAME"
  payload_compose_host_network_yaml >"$tmpc"
  place_dir "$ROOT$INSTALL_DIR" 755
  place_file "$tmpc" "$ROOT$INSTALL_DIR/$COMPOSE_NAME" 644
  for sd in "${STATE_DIRS[@]}"; do place_state_dir "$ROOT$sd"; done
  info "not started: start a colour by hand with docker compose -p $PROJECT -f $INSTALL_DIR/$COMPOSE_NAME up -d cloudflared-blue"
}

# ---- status / verify ----

# run_check <label> <fn>: PASS when the function prints nothing, else one FAIL per printed line.
run_check() {
  local label="$1" fn="$2" msgs line
  msgs="$("$fn")"
  if [ -z "$msgs" ]; then
    pass "$label"
  else
    while IFS= read -r line; do fail "$label: $line"; done <<<"$msgs"
  fi
}

check_state_dir() {
  local path="$ROOT$1" meta
  if [ ! -e "$path" ]; then fail "state directory missing: $1"; return 0; fi
  if [ -L "$path" ]; then fail "state directory is a symlink: $1"; return 0; fi
  meta="$(file_meta "$path")"
  if [ "$meta" = "65532:65532 755" ]; then pass "state directory $1 owner/mode ($meta)"; else fail "state directory $1 uid:gid/mode is '$meta', want '65532:65532 755'"; fi
}

check_compose_file() {
  local path="$ROOT$INSTALL_DIR/$COMPOSE_NAME" meta
  COMPOSE_PLACED=0
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then fail "compose file missing: $INSTALL_DIR/$COMPOSE_NAME (run install)"; return 0; fi
  if [ -L "$path" ] || [ ! -f "$path" ]; then fail "compose file is not a regular file: $INSTALL_DIR/$COMPOSE_NAME"; return 0; fi
  meta="$(file_meta "$path")"
  if [ "$meta" = "0:0 644" ]; then pass "compose file owner/mode ($meta)"; else fail "compose file uid:gid/mode is '$meta', want '0:0 644'"; fi
  if payload_compose_host_network_yaml | cmp -s - "$path"; then
    pass "compose file equals the embedded payload"
    COMPOSE_PLACED=1
  else
    fail "compose file differs from the embedded payload (run install)"
  fi
}

check_docker() {
  local cmd="$1" plugin=1
  docker_probe
  case "$DOCKER_STATE" in
    absent)
      info "docker: unavailable (container state)"
      info "docker: unavailable (logging driver)"
      info "note: $DOCKER_WHY; the token group's socket check was skipped"
      if [ "$cmd" = "verify" ]; then fail "Docker is not installed ($DOCKER_WHY); a host without Docker cannot be verified"; fi
      check_listeners unknown
      return 0 ;;
    unreachable)
      info "docker: unavailable (container state)"
      info "docker: unavailable (logging driver)"
      if [ "$cmd" = "verify" ]; then info "compose config: skipped (docker: unavailable)"; fi
      check_listeners unknown
      return 0 ;;
  esac
  info "docker default logging driver: $LOGGING_DRIVER"
  if dk compose version >/dev/null 2>&1; then
    pass "docker compose plugin present"
  else
    plugin=0
    if [ "$cmd" = "verify" ]; then fail "docker compose plugin missing"; else info "note: docker compose plugin missing"; fi
  fi
  if [ "$cmd" = "verify" ] && [ "$plugin" -eq 1 ] && [ "${COMPOSE_PLACED:-0}" -eq 1 ]; then
    if dk compose -p "$PROJECT" -f "$ROOT$INSTALL_DIR/$COMPOSE_NAME" config -q >/dev/null 2>&1; then
      pass "compose config -q on the placed file"
    else
      fail "compose config -q failed on the placed file"
    fi
  fi
  if container_pids; then
    if [ "${#RUN_NAMES[@]}" -eq 0 ]; then
      info "containers: no $PROJECT colour is running"
    else
      info "containers running: ${RUN_NAMES[*]}"
    fi
    check_listeners known
  else
    info "note: cannot read the state of the $PROJECT containers"
    check_listeners unknown
  fi
}

do_report() {
  local cmd="$1" sd
  require_privilege
  SKIP_SOCKET_GROUP=0
  if [ ! -e "$SOCKET" ] || ! command -v "$DOCKER_BIN" >/dev/null 2>&1; then SKIP_SOCKET_GROUP=1; fi
  run_check "token file" chk_token_file
  run_check "webhook file" chk_webhook_file
  run_check "token group is private" chk_token_group
  check_compose_file
  for sd in "${STATE_DIRS[@]}"; do check_state_dir "$sd"; done
  check_docker "$cmd"
  if [ "$FAILURES" -gt 0 ]; then
    printf 'install-cloudflared-host: %d check(s) failed\n' "$FAILURES"
    exit 1
  fi
  printf 'install-cloudflared-host: all checks passed\n'
}

# ---- main ----

usage() { err "usage: install-cloudflared-host.sh [install|status|verify]"; }

main() {
  local cmd="status"
  if [ "$#" -gt 1 ]; then usage; exit 2; fi
  if [ "$#" -eq 1 ]; then
    case "$1" in
      install | status | verify) cmd="$1" ;;
      -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) usage; exit 2 ;;
    esac
  fi
  require_privilege
  case "$cmd" in
    install) do_install ;;
    status | verify) do_report "$cmd" ;;
  esac
}

main "$@"
exit 0
