#!/usr/bin/env bash
# install-claude-access.sh: create the restricted `claude` debugging SSH identity on the app host (run yourself, not Claude).
#
# `claude` is a read-mostly debugging login with one scoped action (restart of a labelled app). It is reachable over
# LAN OpenSSH only (Tailscale SSH bypasses authorized_keys, so `claude` stays out of every tailnet ssh rule). Layers:
#   1. its authorized_keys line is `restrict,command="/usr/local/bin/claude-access" <key>` (an optional from="<pattern>"
#      comes first), read from a root-owned file in a root-owned directory via a `Match User claude` sshd drop-in
#      (no TTY, no forwarding);
#   2. its login shell is that same root-owned validating file, which accepts only `-c <command>`, validates the command
#      and calls one root helper through sudo. No interactive shell, no fallback;
#   3. the helper (/usr/local/lib/platform/claude-helper) re-validates the app name and the platform.app label itself.
# The user is in no extra group (not docker, not sudo) and has a locked password. The one sudoers line is printed, not
# installed: it is validated with visudo -cf and you install it yourself.
#
# The wrapper and the helper are embedded below (BEGIN-PAYLOAD/END-PAYLOAD) because the Pi has no checkout:
# `platform/lint/embed-payloads.sh` regenerates them from the tracked sources (`make embed`), and `make lint` fails if
# they differ.
#
# Usage: install-claude-access.sh [install|status|verify] [--host ALIAS] [--pubkey-file PATH] [--from PATTERN]
#                                 [--admin-user NAME]
#        install-claude-access.sh verify --live --identity PRIVATE-KEY-FILE --host ALIAS [--admin-user NAME]
#   install   needs --pubkey-file (the public key to authorize; never committed). Idempotent: a second run reports
#             "already" for every item and makes no mutating call. The sudoers fragment is validated first (a visudo -cf
#             failure installs nothing) and printed at the end with the command to install it. An sshd -t failure
#             restores the previous drop-in (or removes a new one), never reloads, and exits 1: keep a second SSH
#             session open while installing.
#   status    report every check (PASS/FAIL), exit 0
#   verify    the same checks, exit 1 on any FAIL (including a missing sudoers fragment)
#   verify --live   client-driven end-to-end check; nothing is created without this flag. The administrator account
#             (via `ssh <alias>` and `sudo docker`) creates a disposable pinned busybox container carrying the reserved
#             label platform.app=platform-livetest and ALWAYS removes it (trap on every path); the `claude` commands run
#             through `ssh -i <private-key-file> -o IdentitiesOnly=yes`. The private key stays on this client. Run once
#             by you in Step 8. Env LIVE_TEST_IMAGE overrides the image (default busybox:1.37.0; image-reference
#             characters only, validated). The container is removed by the id `docker run` printed, only after that id
#             was captured; an unlabelled container already named platform-livetest stops the run. ssh calls carry
#             ConnectTimeout/ServerAlive options and INT/TERM/HUP run the removal before exiting.
#   --host    stream this script over one `ssh <alias> bash -s` call (BatchMode, no tty). The local --pubkey-file is
#             read and validated here and its content is forwarded as a quoted argument (--key); the remote
#             re-validates it. The remote account needs passwordless sudo (NOPASSWD): a `sudo -v` in another terminal
#             does not carry over, because sudo timestamps are tty-scoped. Without NOPASSWD, copy the script to the
#             host and run it there directly instead of using --host.
#   --from    optional from="..." pattern/CIDR list for the key (pattern characters only)
#   --admin-user  the administrator account whose effective sshd config must stay unchanged (default: the caller);
#             must match ^[a-z_][a-z0-9_-]{0,31}$
#
# Limits of status/verify (they run after the fact, so they cannot compare before and after): the administrator's and
# deploy's effective sshd config is checked only for not referencing the claude key file; the real "unchanged"
# comparison (before/after the drop-in) happens at install time, and an install that finds the identical drop-in
# already in place skips it (later global overrides are then caught by verify's effective-directive checks).
#
# Exit: 0 ok | 1 failed check, sshd -t or visudo failure or missing prerequisite | 2 usage error or invalid key/from
#       input (nothing is written). ssh failures pass through ssh's own status (255).
#
# Test overrides (env, test-only): INSTALL_CLAUDE_ROOT (path prefix for every file this script writes),
# INSTALL_CLAUDE_SUDO (the privilege prefix; "sudo -n" by default, none when already root), INSTALL_CLAUDE_VISUDO
# (the visudo command name; "visudo" by default).
set -euo pipefail

export LC_ALL=C
# sshd, useradd, visudo and friends live in /usr/sbin, which a non-root ssh user's PATH lacks
export PATH="$PATH:/usr/sbin:/sbin"

readonly CLAUDE_USER="claude"
readonly ACCESS_PATH="/usr/local/bin/claude-access"
readonly HELPER_DIR="/usr/local/lib/platform"
readonly HELPER_PATH="/usr/local/lib/platform/claude-helper"
readonly KEYS_DIR="/etc/ssh/authorized_keys.d"
readonly KEY_FILE="/etc/ssh/authorized_keys.d/claude"
readonly DROPIN="/etc/ssh/sshd_config.d/30-claude.conf"
readonly SUDOERS_FILE="/etc/sudoers.d/platform-claude"
readonly DEPLOY_USER="deploy"
readonly LIVE_APP="platform-livetest"
ROOT="${INSTALL_CLAUDE_ROOT:-}"
VISUDO="${INSTALL_CLAUDE_VISUDO:-visudo}"

# <keytype> <base64> [comment]: no option prefix, no quote, no backslash, no control character.
readonly KEY_RE='(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com) [A-Za-z0-9+/]+={0,3}( [A-Za-z0-9@._:+=,/()# -]*)?'
readonly FROM_RE='[A-Za-z0-9.*?:/!,_-]+'

if [ -n "${INSTALL_CLAUDE_SUDO+set}" ]; then
  read -r -a SUDO <<<"$INSTALL_CLAUDE_SUDO"
elif [ "$EUID" -eq 0 ]; then
  SUDO=()
else
  SUDO=(sudo -n)
fi

FAILURES=0
TMP=""

info() { printf '%s\n' "$1"; }
err() { printf '%s\n' "$1" >&2; }
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
die() { err "install-claude-access: $1"; exit "${2:-1}"; }

# shellcheck disable=SC2329 # invoked through the EXIT trap
cleanup() {
  [ -z "$TMP" ] || rm -rf "$TMP"
  return 0
}
trap cleanup EXIT

# priv <cmd...>: run with privilege; stdin is never forwarded (this script may itself be read from stdin).
priv() { "${SUDO[@]}" "$@" </dev/null; }

# require_privilege: fail early and clearly, before anything is written, when privileged calls cannot work.
require_privilege() {
  priv true || die "no usable privilege (sudo -n failed). Over --host the account needs passwordless sudo; otherwise copy this script to the host and run it there directly"
}

# ---- embedded payloads (regenerated by platform/lint/embed-payloads.sh; do not edit between the markers) ----

# BEGIN-PAYLOAD platform/host/claude-access.sh
payload_claude_access() {
  cat <<'PLATFORM_PAYLOAD_EOF'
#!/bin/bash -p
# claude-access: the forced command AND the validating login shell of the `claude` debugging identity, installed
# root-owned as /usr/local/bin/claude-access. It never starts a shell. Its input contract is the one of
# login-shell.sh (the deploy identity's wrapper); the dispatch below replaces that wrapper's exec of the dispatcher.
#
# Input contract (sshd runs `<login shell> -c <command>`; here the forced-command path and the login shell are this
# same file, so the OpenSSH shape is `claude-access -c <this file>`):
#   -c <exact path of this file>  the OpenSSH forced-command shape: the real client command is in
#                                 SSH_ORIGINAL_COMMAND, which must be set and not blank (else exit 2, nothing runs,
#                                 no fallback to argv).
#   -c <any other string>         the Tailscale SSH shape (no forced command): the string is the client command.
#   anything else                 (no -c, -c without an argument, extra arguments, flags) is rejected, exit 2.
# A blank command (empty or whitespace only) is rejected with exit 2 in both shapes.
#
# Accepted commands (validated as one unsplit string, split once with read, never eval'd):
#   ps | stats | status | logs <app> [lines] | restart <app>
# Each is passed, as separate argv words, to the root helper through one fixed sudo call; the helper re-validates
# everything and is the one that checks the platform.app label.
#
# Fail closed: every path that is not explicitly accepted exits 2 before sudo is reached.
# Exit codes: 2 rejected; otherwise the helper's own exit code (it is exec'd).
set -euo pipefail

# ASCII-only classes and byte semantics, whatever locale the caller has.
export LC_ALL=C

readonly SELF=/usr/local/bin/claude-access
readonly HELPER=/usr/local/lib/platform/claude-helper
readonly SUDO=/usr/bin/sudo
readonly LOGGER=/usr/bin/logger
readonly MAX_LEN=256
readonly MAX_LINES=1000
readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
readonly LINES_RE='^[1-9][0-9]{0,3}$'

usage() {
  cat >&2 <<'EOF'
usage: ps | stats | status | logs <app> [lines] | restart <app>
EOF
}

# reject <reason-code> <input-length>: fixed message, log reason and length only, exit 2.
reject() {
  usage || true
  "$LOGGER" -t platform-claude "rejected reason=$1 len=$2" || true
  exit 2
}

[ "$#" -eq 2 ] || reject bad-arguments 0
[ "$1" = "-c" ] || reject bad-arguments 0

if [ "$2" = "$SELF" ]; then
  # OpenSSH shape: the command comes only from SSH_ORIGINAL_COMMAND.
  [ "${SSH_ORIGINAL_COMMAND+set}" = "set" ] || reject no-original-command 0
  cmd="$SSH_ORIGINAL_COMMAND"
else
  # Tailscale SSH shape: the client command is the argument.
  cmd="$2"
fi
len=${#cmd}

# Blank (empty or whitespace only) is never a command.
if [[ "$cmd" =~ ^[[:space:]]*$ ]]; then
  reject blank-command "$len"
fi

# Checks on the unsplit string, before any splitting.
case "$cmd" in *$'\n'* | *$'\r'*) reject newline "$len" ;; esac
[ "$len" -le "$MAX_LEN" ] || reject too-long "$len"

# Split on single spaces only (a tab stays inside a word and fails the regexes below).
IFS=' ' read -r -a words <<<"$cmd"
[ "${#words[@]}" -gt 0 ] || reject empty "$len"

# Canonical form: leading, trailing or repeated spaces are rejected, not normalized.
joined="${words[*]}"
[ "$joined" = "$cmd" ] || reject non-canonical "$len"

sub="${words[0]}"
nargs=$((${#words[@]} - 1))

valid_app() {
  [[ "${words[1]}" =~ $APP_RE ]] || reject bad-app "$len"
}

case "$sub" in
  ps | stats | status)
    [ "$nargs" -eq 0 ] || reject arg-count "$len"
    ;;
  logs)
    [ "$nargs" -ge 1 ] && [ "$nargs" -le 2 ] || reject arg-count "$len"
    valid_app
    if [ "$nargs" -eq 2 ]; then
      [[ "${words[2]}" =~ $LINES_RE ]] || reject bad-lines "$len"
      [ "${words[2]}" -le "$MAX_LINES" ] || reject bad-lines "$len"
    fi
    ;;
  restart)
    [ "$nargs" -eq 1 ] || reject arg-count "$len"
    valid_app
    ;;
  *)
    reject unknown-command "$len"
    ;;
esac

"$LOGGER" -t platform-claude "accepted sub=$sub len=$len" || true
exec "$SUDO" -n "$HELPER" "${words[@]}"
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/host/claude-access.sh

# BEGIN-PAYLOAD platform/host/claude-helper.sh
payload_claude_helper() {
  cat <<'PLATFORM_PAYLOAD_EOF'
#!/bin/bash -p
# claude-helper: the root helper behind the `claude` debugging identity, installed root:root 0755 as
# /usr/local/lib/platform/claude-helper and reachable only through one literal sudoers command (a sudoers line cannot
# constrain arguments, so this script re-validates every argument itself).
#
# Subcommands: ps | stats | status | logs <app> [lines] | restart <app>
# An app is a container set carrying exactly the label platform.app=<name>. Infrastructure containers (Traefik,
# cloudflared, Postgres, Redis) are never labelled, so they are never listed, logged or restarted. Matching includes
# stopped containers (docker ps -a semantics) so a crashed app can be restarted. Zero matching containers fails
# closed: exit 1 and no docker mutation.
#
# Exit codes: 0 done | 1 no matching labelled container or a docker failure | 2 invalid arguments.
set -euo pipefail

# ASCII-only classes and byte semantics, whatever locale the caller has.
export LC_ALL=C

# Root runs docker here, so nothing from the caller's environment may steer it: drop every DOCKER_* variable and pin
# HOME, DOCKER_CONFIG and PATH to root's own.
unset "${!DOCKER_@}"
export HOME=/root
export DOCKER_CONFIG=/root/.docker
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

readonly DOCKER=/usr/bin/docker
readonly SYSTEMCTL=/usr/bin/systemctl
readonly FREE=/usr/bin/free
readonly LOGGER=/usr/bin/logger
readonly LABEL_KEY="platform.app"
readonly MAX_LINES=1000
readonly DEFAULT_LINES=100
readonly APP_RE='^[a-z][a-z0-9-]{1,30}$'
readonly LINES_RE='^[1-9][0-9]{0,3}$'
readonly ID_RE='^[0-9a-f]{12,64}$'
readonly STATUS_UNITS=(docker docker-user-firewall ssh tailscaled)

reject() {
  echo "claude-helper: rejected ($1)" >&2
  "$LOGGER" -t platform-claude-helper "rejected reason=$1" || true
  exit 2
}

[ "$#" -ge 1 ] || reject no-command
sub="$1"
shift

valid_app() {
  [[ "$1" =~ $APP_RE ]] || reject bad-app
}

# find_app <app>: sets IDS and NAMES to every container (running or not) labelled platform.app=<app>.
find_app() {
  local line id name
  IDS=()
  NAMES=()
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    id="${line%% *}"
    name="${line#* }"
    [[ "$id" =~ $ID_RE ]] || { echo "claude-helper: unexpected container id from docker" >&2; exit 1; }
    IDS+=("$id")
    NAMES+=("$name")
  done < <("$DOCKER" ps -a --filter "label=${LABEL_KEY}=$1" --format '{{.ID}} {{.Names}}')
  if [ "${#IDS[@]}" -eq 0 ]; then
    echo "claude-helper: no container carries the label ${LABEL_KEY}=$1" >&2
    "$LOGGER" -t platform-claude-helper "no-match sub=$sub" || true
    exit 1
  fi
}

case "$sub" in
  ps)
    [ "$#" -eq 0 ] || reject arg-count
    "$LOGGER" -t platform-claude-helper "ps" || true
    printf 'APP\tNAME\tSTATUS\n'
    "$DOCKER" ps -a --filter "label=${LABEL_KEY}" --format "{{.Label \"${LABEL_KEY}\"}}\\t{{.Names}}\\t{{.Status}}"
    ;;
  stats)
    [ "$#" -eq 0 ] || reject arg-count
    "$LOGGER" -t platform-claude-helper "stats" || true
    running=()
    while IFS= read -r id; do
      [ -n "$id" ] || continue
      [[ "$id" =~ $ID_RE ]] || { echo "claude-helper: unexpected container id from docker" >&2; exit 1; }
      running+=("$id")
    done < <("$DOCKER" ps -q --filter "label=${LABEL_KEY}")
    if [ "${#running[@]}" -eq 0 ]; then
      echo "no running app containers"
      exit 0
    fi
    "$DOCKER" stats --no-stream "${running[@]}"
    ;;
  status)
    [ "$#" -eq 0 ] || reject arg-count
    "$LOGGER" -t platform-claude-helper "status" || true
    for unit in "${STATUS_UNITS[@]}"; do
      state="$("$SYSTEMCTL" is-active "$unit" 2>/dev/null || true)"
      printf '%s: %s\n' "$unit" "${state:-unknown}"
    done
    "$FREE" -m
    ;;
  logs)
    [ "$#" -ge 1 ] && [ "$#" -le 2 ] || reject arg-count
    valid_app "$1"
    lines="$DEFAULT_LINES"
    if [ "$#" -eq 2 ]; then
      [[ "$2" =~ $LINES_RE ]] || reject bad-lines
      [ "$2" -le "$MAX_LINES" ] || reject bad-lines
      lines="$2"
    fi
    "$LOGGER" -t platform-claude-helper "logs lines=$lines" || true
    find_app "$1"
    for i in "${!IDS[@]}"; do
      printf '==> %s <==\n' "${NAMES[$i]}"
      "$DOCKER" logs --tail "$lines" --timestamps "${IDS[$i]}" 2>&1
    done
    ;;
  restart)
    [ "$#" -eq 1 ] || reject arg-count
    valid_app "$1"
    "$LOGGER" -t platform-claude-helper "restart" || true
    find_app "$1"
    "$DOCKER" restart "${IDS[@]}" >/dev/null
    printf 'restarted %s container(s) of %s\n' "${#IDS[@]}" "$1"
    ;;
  *)
    reject unknown-command
    ;;
esac
PLATFORM_PAYLOAD_EOF
}
# END-PAYLOAD platform/host/claude-helper.sh

# ---- input validation (shared by the local and the remote side) ----

# check_key <line>: exactly one bare public-key line; exits 2 otherwise.
check_key() {
  local key="$1"
  [ -n "$key" ] || die "empty public key" 2
  case "$key" in
    *$'\n'* | *$'\r'* | *'"'* | *"'"* | *\\* | *'`'* | *'$'*) die "public key must be one line without quotes, backslashes or newlines" 2 ;;
  esac
  [[ "$key" =~ ^${KEY_RE}$ ]] || die "not a bare one-line public key (<keytype> <base64> [comment], no option prefix)" 2
}

# check_from <pattern>: pattern/CIDR characters only; exits 2 otherwise.
check_from() {
  [[ "$1" =~ ^${FROM_RE}$ ]] || die "--from may contain only pattern/CIDR characters" 2
}

# read_key_file <path>: prints the validated key line.
read_key_file() {
  local file="$1" lines=()
  [ -f "$file" ] && [ -r "$file" ] || die "cannot read public key file: $file" 2
  mapfile -t lines < "$file"
  [ "${#lines[@]}" -eq 1 ] || die "public key file must hold exactly one line" 2
  check_key "${lines[0]}"
  printf '%s\n' "${lines[0]}"
}

# ---- rendered contents ----

# key_line <key> <from>: the authorized_keys line.
key_line() {
  local prefix=""
  [ -z "$2" ] || prefix="from=\"$2\","
  printf '%srestrict,command="%s" %s\n' "$prefix" "$ACCESS_PATH" "$1"
}

render_dropin() {
  cat <<EOF
# Managed by platform/host/install-claude-access.sh. Do not edit by hand; re-run the installer.
# The Match block ends at this file's end, so it cannot swallow later directives or other drop-ins.
Match User $CLAUDE_USER
    AuthorizedKeysFile $KEY_FILE
    PermitTTY no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    GatewayPorts no
    PermitUserRC no
    PermitUserEnvironment no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    AuthorizedKeysCommand none
EOF
}

# The one sudoers line: a single literal command, no wildcard, no ALL in the command list.
render_sudoers() {
  cat <<EOF
# Managed by platform/host/install-claude-access.sh. One literal command, no wildcard; the helper re-validates its arguments.
$CLAUDE_USER ALL=(root) NOPASSWD: $HELPER_PATH
EOF
}

# The effective sshd settings the claude user must have: one list, used by install (before the reload) and verify.
claude_directives() {
  printf '%s\n' \
    "authorizedkeysfile $KEY_FILE" \
    "permittty no" \
    "allowtcpforwarding no" \
    "allowagentforwarding no" \
    "allowstreamlocalforwarding no" \
    "x11forwarding no" \
    "permittunnel no" \
    "gatewayports no" \
    "permituserrc no" \
    "permituserenvironment no" \
    "passwordauthentication no" \
    "kbdinteractiveauthentication no" \
    "authenticationmethods publickey" \
    "authorizedkeyscommand none"
}

# ---- file helpers ----

# file_meta <path>: "<owner>:<group> <octal mode>".
file_meta() { stat -c '%U:%G %a' -- "$1"; }

# place_file <src> <dest> <mode>: copy, own as root, chmod, then atomic rename. Reports already/changed.
place_file() {
  local src="$1" dest="$2" mode="$3"
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$src" "$dest" && [ "$(file_meta "$dest")" = "root:root $mode" ]; then
    info "already: $dest"
    return 0
  fi
  priv cp -- "$src" "$dest.new"
  priv chown root:root "$dest.new"
  priv chmod "$mode" "$dest.new"
  priv mv -f -- "$dest.new" "$dest"
  info "changed: $dest"
}

# place_dir <path> <mode>
place_dir() {
  local dir="$1" mode="$2"
  if [ -d "$dir" ] && [ ! -L "$dir" ] && [ "$(file_meta "$dir")" = "root:root $mode" ]; then
    info "already: $dir/"
    return 0
  fi
  priv mkdir -p -- "$dir"
  priv chown root:root "$dir"
  priv chmod "$mode" "$dir"
  info "changed: $dir/"
}

# sshd_effective <user>: the effective sshd config for the user, sorted.
sshd_effective() {
  priv sshd -T -C "user=$1,host=localhost,addr=127.0.0.1" | sort
}

# ---- install ----

# validate_sudoers: visudo -cf on the rendered fragment. A failure aborts before anything is installed; an absent
# visudo is reported as a skip, never as a pass.
validate_sudoers() {
  render_sudoers > "$TMP/sudoers"
  if command -v "$VISUDO" >/dev/null 2>&1; then
    if ! priv "$VISUDO" -cf "$TMP/sudoers" >"$TMP/visudo.out" 2>&1; then
      err "$(cat "$TMP/visudo.out")"
      die "visudo -cf rejected the sudoers fragment; nothing was installed"
    fi
    info "validated: sudoers fragment (visudo -cf)"
  else
    info "SKIP: visudo not found, the sudoers fragment was not validated"
  fi
}

ensure_user() {
  local entry shell groups uid changed=0 status
  entry="$(getent passwd "$CLAUDE_USER" || true)"
  if [ -z "$entry" ]; then
    priv useradd --create-home --shell "$ACCESS_PATH" --comment "platform claude debug" "$CLAUDE_USER"
    priv passwd -l "$CLAUDE_USER"
    info "changed: user $CLAUDE_USER created (locked password, no extra groups, login shell $ACCESS_PATH)"
    return 0
  fi
  groups="$(id -nG "$CLAUDE_USER")"
  case " $groups " in
    *" sudo "*) die "$CLAUDE_USER is in the sudo group; remove it (gpasswd -d $CLAUDE_USER sudo) and re-run" ;;
    *" docker "*) die "$CLAUDE_USER is in the docker group; remove it (gpasswd -d $CLAUDE_USER docker) and re-run" ;;
  esac
  # Fail closed: the primary group is the only one allowed, whatever else the account might belong to.
  [ "$groups" = "$CLAUDE_USER" ] || die "$CLAUDE_USER is in groups other than its own ($groups); remove the extra groups and re-run"
  uid="$(id -u "$CLAUDE_USER")"
  { [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ne 0 ]; } || die "$CLAUDE_USER uid is not a nonzero number ('$uid'); fix the account and re-run"
  shell="${entry##*:}"
  if [ "$shell" != "$ACCESS_PATH" ]; then
    priv usermod --shell "$ACCESS_PATH" "$CLAUDE_USER"
    changed=1
  fi
  status="$(priv passwd -S "$CLAUDE_USER" | awk '{print $2}')"
  case "$status" in
    L | LK) ;;
    *) priv passwd -l "$CLAUDE_USER"; changed=1 ;;
  esac
  if [ "$changed" -eq 1 ]; then info "changed: user $CLAUDE_USER"; else info "already: user $CLAUDE_USER"; fi
}

reload_sshd() {
  priv systemctl reload ssh || priv systemctl reload sshd || die "sshd reload failed; the drop-in is in place but not active: reload sshd by hand"
}

# claude_missing: prints each required directive the claude user's effective sshd config lacks (global settings that
# come first in the config win over a Match block, so the drop-in alone proves nothing).
claude_missing() {
  local eff d
  eff="$(sshd_effective "$CLAUDE_USER")" || { echo "(cannot read the effective sshd config for $CLAUDE_USER)"; return 0; }
  while IFS= read -r d; do
    grep -qxF "$d" <<<"$eff" || printf '%s\n' "$d"
  done < <(claude_directives)
}

install_dropin() {
  local dest="$ROOT$DROPIN" new backup="" admin_before admin_after deploy_before deploy_after missing syntax_ok had=0
  new="$TMP/dropin.new"
  render_dropin > "$new"
  if [ -f "$dest" ] && [ ! -L "$dest" ] && cmp -s "$new" "$dest" && [ "$(file_meta "$dest")" = "root:root 644" ]; then
    info "already: $dest"
    return 0
  fi
  admin_before="$(sshd_effective "$ADMIN")" || die "cannot read the effective sshd config for $ADMIN (is sshd installed?)"
  deploy_before="$(sshd_effective "$DEPLOY_USER" || true)"
  [ -d "$(dirname "$dest")" ] || priv mkdir -p -- "$(dirname "$dest")"
  if [ -e "$dest" ]; then
    had=1
    backup="$TMP/dropin.backup"
    priv cat -- "$dest" > "$backup"
  fi
  place_file "$new" "$dest" 644
  admin_after="$(sshd_effective "$ADMIN" || true)"
  deploy_after="$(sshd_effective "$DEPLOY_USER" || true)"
  missing=""
  syntax_ok=1
  priv sshd -t || syntax_ok=0
  if [ "$syntax_ok" -eq 1 ]; then missing="$(claude_missing)"; fi
  if [ "$syntax_ok" -eq 0 ] || [ "$admin_after" != "$admin_before" ] || [ "$deploy_after" != "$deploy_before" ] || [ -n "$missing" ]; then
    if [ "$had" -eq 1 ]; then
      place_file "$backup" "$dest" 644 >/dev/null
    else
      priv rm -f -- "$dest"
    fi
    [ -z "$missing" ] || err "install-claude-access: the claude user's effective sshd config lacks (an earlier global setting wins?): $(tr '\n' ';' <<<"$missing")"
    die "sshd -t failed, the administrator's or deploy's effective sshd config changed, or the claude user's effective config is not restricted; the previous drop-in state is restored and sshd was not reloaded"
  fi
  reload_sshd
  info "changed: sshd reloaded"
}

print_sudoers_instructions() {
  info ""
  info "Sudoers: install this fragment yourself (it is not installed by this script; claude cannot restart anything without it):"
  info "  sudo install -m 0440 -o root -g root /dev/stdin $SUDOERS_FILE <<'SUDOERS_EOF'"
  render_sudoers
  info "SUDOERS_EOF"
}

do_install() {
  [ -n "$KEY" ] || die "install needs --pubkey-file" 2
  check_key "$KEY"
  [ -z "$FROM" ] || check_from "$FROM"
  require_privilege
  TMP="$(mktemp -d)"

  validate_sudoers

  payload_claude_access > "$TMP/claude-access"
  payload_claude_helper > "$TMP/claude-helper"
  key_line "$KEY" "$FROM" > "$TMP/key"

  # The install directories belong to the system (/usr/local/bin, /usr/local/lib): created only if absent.
  [ -d "$(dirname "$ROOT$ACCESS_PATH")" ] || priv mkdir -p -- "$(dirname "$ROOT$ACCESS_PATH")"
  place_file "$TMP/claude-access" "$ROOT$ACCESS_PATH" 755
  [ -d "$(dirname "$ROOT$HELPER_DIR")" ] || priv mkdir -p -- "$(dirname "$ROOT$HELPER_DIR")"
  place_dir "$ROOT$HELPER_DIR" 755
  place_file "$TMP/claude-helper" "$ROOT$HELPER_PATH" 755
  ensure_user
  place_dir "$ROOT$KEYS_DIR" 755
  place_file "$TMP/key" "$ROOT$KEY_FILE" 644
  install_dropin
  info "install-claude-access: done"
  print_sudoers_instructions
}

# ---- status / verify ----

# check_owned <label> <path> <mode>: exists as a regular non-symlink root:root file/dir with exactly this mode.
check_owned() {
  local label="$1" path="$2" mode="$3" meta
  if [ ! -e "$path" ]; then fail "$label missing: $path"; return 1; fi
  if [ -L "$path" ]; then fail "$label is a symlink: $path"; return 1; fi
  meta="$(file_meta "$path")"
  if [ "$meta" = "root:root $mode" ]; then pass "$label owner/mode ($meta)"; else fail "$label owner/mode is '$meta', want 'root:root $mode'"; return 1; fi
}

check_payload() {
  local label="$1" path="$2" fn="$3"
  if [ -f "$path" ] && "$fn" | cmp -s - "$path"; then pass "$label bytes equal the embedded payload"; else fail "$label bytes differ from the embedded payload"; fi
}

# check_sudoers: the fragment is installed root:root 0440 with exactly the intended content (read through privilege:
# /etc/sudoers.d is not readable by an ordinary user).
check_sudoers() {
  local path="$ROOT$SUDOERS_FILE" meta
  if ! priv test -f "$path"; then
    fail "sudoers fragment missing: $path (install it with the command printed by 'install')"
    return 0
  fi
  if priv test -L "$path"; then fail "sudoers fragment is a symlink: $path"; return 0; fi
  meta="$(priv stat -c '%U:%G %a' -- "$path")"
  if [ "$meta" = "root:root 440" ]; then pass "sudoers fragment owner/mode ($meta)"; else fail "sudoers fragment owner/mode is '$meta', want 'root:root 440'"; fi
  if priv cat -- "$path" | cmp -s - <(render_sudoers); then pass "sudoers fragment content is the intended single command"; else fail "sudoers fragment content differs from the intended single command"; fi
}

do_checks() {
  local path entry shell groups uid status eff

  check_owned "access wrapper" "$ROOT$ACCESS_PATH" 755 || true
  check_payload "access wrapper" "$ROOT$ACCESS_PATH" payload_claude_access
  check_owned "helper directory" "$ROOT$HELPER_DIR" 755 || true
  check_owned "helper" "$ROOT$HELPER_PATH" 755 || true
  check_payload "helper" "$ROOT$HELPER_PATH" payload_claude_helper
  check_owned "keys directory" "$ROOT$KEYS_DIR" 755 || true
  check_owned "key file" "$ROOT$KEY_FILE" 644 || true

  path="$ROOT$KEY_FILE"
  if [ -f "$path" ]; then
    local lines=()
    mapfile -t lines < "$path"
    if [ "${#lines[@]}" -eq 1 ] && [[ "${lines[0]}" =~ ^(from=\"${FROM_RE}\",)?restrict,command=\"${ACCESS_PATH}\"\ ${KEY_RE}$ ]]; then
      pass "key file is exactly one restrict,command line"
    else
      fail "key file is not exactly one 'restrict,command=\"$ACCESS_PATH\" <key>' line"
    fi
  fi

  path="$ROOT$DROPIN"
  check_owned "sshd drop-in" "$path" 644 || true
  if [ -f "$path" ] && render_dropin | cmp -s - "$path"; then pass "sshd drop-in content is the intended directive set"; else fail "sshd drop-in content differs from the intended directive set"; fi

  entry="$(getent passwd "$CLAUDE_USER" || true)"
  if [ -z "$entry" ]; then
    fail "user $CLAUDE_USER does not exist"
  else
    shell="${entry##*:}"
    if [ "$shell" = "$ACCESS_PATH" ]; then pass "login shell is $ACCESS_PATH"; else fail "login shell is '$shell', want $ACCESS_PATH"; fi
    groups="$(id -nG "$CLAUDE_USER")"
    case " $groups " in *" docker "*) fail "$CLAUDE_USER is in the docker group" ;; *) pass "$CLAUDE_USER is not in the docker group" ;; esac
    case " $groups " in *" sudo "*) fail "$CLAUDE_USER is in the sudo group" ;; *) pass "$CLAUDE_USER is not in the sudo group" ;; esac
    if [ "$groups" = "$CLAUDE_USER" ]; then pass "$CLAUDE_USER has no group but its own"; else fail "$CLAUDE_USER is in groups other than its own ($groups)"; fi
    uid="$(id -u "$CLAUDE_USER" 2>/dev/null || true)"
    if [[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ne 0 ]; then pass "$CLAUDE_USER uid is nonzero"; else fail "$CLAUDE_USER uid is not a nonzero number ('$uid')"; fi
    status="$(priv passwd -S "$CLAUDE_USER" 2>/dev/null | awk '{print $2}' || true)"
    case "$status" in L | LK) pass "password is locked" ;; *) fail "password is not locked (status '$status')" ;; esac
  fi

  check_sudoers

  if eff="$(sshd_effective "$CLAUDE_USER" 2>/dev/null)"; then
    local d
    while IFS= read -r d; do
      if grep -qxF "$d" <<<"$eff"; then pass "effective '$d' for $CLAUDE_USER"; else fail "effective '$d' is not set for $CLAUDE_USER"; fi
    done < <(claude_directives)
  else
    fail "cannot read the effective sshd config for $CLAUDE_USER"
  fi
  if eff="$(sshd_effective "$ADMIN" 2>/dev/null)"; then
    if grep -qF "$KEY_FILE" <<<"$eff"; then fail "the administrator's effective sshd config references the claude key file"; else pass "administrator's effective sshd config does not reference the claude key file"; fi
  else
    fail "cannot read the effective sshd config for $ADMIN"
  fi
  if eff="$(sshd_effective "$DEPLOY_USER" 2>/dev/null)"; then
    if grep -qF "$KEY_FILE" <<<"$eff"; then fail "deploy's effective sshd config references the claude key file"; else pass "deploy's effective sshd config does not reference the claude key file"; fi
  else
    fail "cannot read the effective sshd config for $DEPLOY_USER"
  fi
}

do_report() {
  require_privilege
  TMP="$(mktemp -d)"
  do_checks
  if [ "$FAILURES" -gt 0 ]; then
    printf 'install-claude-access: %d check(s) failed\n' "$FAILURES"
    [ "$1" = "status" ] || exit 1
  else
    printf 'install-claude-access: all checks passed\n'
  fi
}

# ---- verify --live (client-driven) ----

LIVE_CONTAINER_MADE=0
LIVE_CID=""
readonly CID_RE='^[0-9a-f]{12,64}$'
readonly IMAGE_RE='^[A-Za-z0-9][A-Za-z0-9._/:@-]*$'
# No hung connection may block the cleanup trap from ever running.
readonly LIVE_SSH_OPTS=(-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

# live_ssh_admin <remote command...>: the administrator's own ssh identity (no -i), batch mode.
live_ssh_admin() { ssh -o BatchMode=yes "${LIVE_SSH_OPTS[@]}" -- "$HOST" "$@" </dev/null; }

# live_ssh_claude <claude command...>: only the given private key (identities-only), as the claude user.
live_ssh_claude() {
  ssh -i "$IDENTITY" -o IdentitiesOnly=yes -o BatchMode=yes "${LIVE_SSH_OPTS[@]}" -o User="$CLAUDE_USER" -- "$HOST" "$@" </dev/null
}

# shellcheck disable=SC2329 # invoked through the EXIT trap
live_cleanup() {
  # Only a container this run created (its id was captured from docker run) is ever removed, and by id.
  if [ "$LIVE_CONTAINER_MADE" -eq 1 ] && [ -n "$LIVE_CID" ]; then
    live_ssh_admin "sudo -n docker rm -f $LIVE_CID" >/dev/null 2>&1 || err "install-claude-access: could not remove the test container; remove it by hand: ssh <alias> sudo docker rm -f $LIVE_CID"
    LIVE_CONTAINER_MADE=0
  fi
  cleanup
}

# live_expect <label> <want-rc> <claude command...>: runs the claude command and records PASS/FAIL on its exit status.
live_expect() {
  local label="$1" want="$2" rc=0
  shift 2
  LIVE_OUT="$(live_ssh_claude "$@" 2>&1)" || rc=$?
  if [ "$rc" -eq "$want" ]; then pass "$label (exit $rc)"; else fail "$label: exit $rc, want $want"; fi
}

do_live() {
  local image="${LIVE_TEST_IMAGE:-busybox:1.37.0}" existing cid
  [ -n "$HOST" ] || die "verify --live needs --host" 2
  [ -n "$IDENTITY" ] || die "verify --live needs --identity" 2
  [ -f "$IDENTITY" ] && [ -r "$IDENTITY" ] || die "cannot read identity file: $IDENTITY" 2
  # The image is interpolated into a remote shell command: plain image-reference characters only, no leading dash.
  [[ "$image" =~ $IMAGE_RE ]] || die "LIVE_TEST_IMAGE must match $IMAGE_RE" 2
  TMP="$(mktemp -d)"
  trap live_cleanup EXIT
  # An interrupt must run the EXIT trap (which removes the test container).
  trap 'exit 130' INT
  trap 'exit 143' TERM
  trap 'exit 129' HUP

  existing="$(live_ssh_admin "sudo -n docker ps -a -q --filter label=platform.app=$LIVE_APP")" || die "cannot list containers over ssh as the administrator"
  [ -z "$existing" ] || die "a container labelled platform.app=$LIVE_APP already exists; remove it first: ssh <alias> sudo docker rm -f $LIVE_APP"
  # The container is created and removed by id; a same-named unlabelled container is never ours, so it stops the run.
  existing="$(live_ssh_admin "sudo -n docker ps -a -q --filter 'name=^$LIVE_APP\$'")" || die "cannot list containers over ssh as the administrator"
  [ -z "$existing" ] || die "a container named $LIVE_APP already exists (not labelled by this check); remove or rename it first"

  cid="$(live_ssh_admin "sudo -n docker run -d --name $LIVE_APP --label platform.app=$LIVE_APP $image sleep 300")" || die "could not create the test container"
  [[ "$cid" =~ $CID_RE ]] || die "docker run returned an unexpected container id; check by hand: ssh <alias> sudo docker ps -a --filter label=platform.app=$LIVE_APP"
  LIVE_CID="$cid"
  LIVE_CONTAINER_MADE=1

  live_expect "claude ps lists the test container" 0 ps
  grep -qF "$LIVE_APP" <<<"$LIVE_OUT" || fail "claude ps output does not name $LIVE_APP"
  live_expect "claude stats" 0 stats
  live_expect "claude status" 0 status
  live_expect "claude logs" 0 logs "$LIVE_APP" 5
  live_expect "claude restart of the labelled test app" 0 restart "$LIVE_APP"
  live_expect "claude restart of an unlabelled name is refused by the helper" 1 restart traefik
  live_expect "claude logs with an over-maximum line count is refused by the wrapper" 2 logs "$LIVE_APP" 99999
  live_expect "claude arbitrary command is refused by the wrapper" 2 id

  # The container is removed here and again by the EXIT trap if anything above died.
  if live_ssh_admin "sudo -n docker rm -f $LIVE_CID" >/dev/null; then
    LIVE_CONTAINER_MADE=0
    pass "test container removed"
  else
    fail "could not remove the test container"
  fi

  if [ "$FAILURES" -gt 0 ]; then
    printf 'install-claude-access: %d live check(s) failed\n' "$FAILURES"
    exit 1
  fi
  printf 'install-claude-access: all live checks passed\n'
}

# ---- main ----

main() {
  local cmd="install" host="" keyfile="" ADMIN_ARG="" live=0
  KEY=""
  FROM=""
  HOST=""
  IDENTITY=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      install | status | verify) cmd="$1"; shift ;;
      --live) live=1; shift ;;
      --identity) [ "$#" -ge 2 ] && [ -n "$2" ] || die "missing value for --identity" 2; IDENTITY="$2"; shift 2 ;;
      --host) [ "$#" -ge 2 ] && [ -n "$2" ] || die "missing value for --host" 2; host="$2"; shift 2 ;;
      --pubkey-file) [ "$#" -ge 2 ] && [ -n "$2" ] || die "missing value for --pubkey-file" 2; keyfile="$2"; shift 2 ;;
      --key) [ "$#" -ge 2 ] || die "missing value for --key" 2; KEY="$2"; shift 2 ;;
      --from) [ "$#" -ge 2 ] && [ -n "$2" ] || die "missing value for --from" 2; FROM="$2"; shift 2 ;;
      --admin-user) [ "$#" -ge 2 ] && [ -n "$2" ] || die "missing value for --admin-user" 2; ADMIN_ARG="$2"; shift 2 ;;
      -h | --help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  case "$host" in -*) die "refusing option-looking --host: $host" 2 ;; esac
  case "$IDENTITY" in -*) die "refusing option-looking --identity: $IDENTITY" 2 ;; esac
  if [ "$live" -eq 1 ] && [ "$cmd" != "verify" ]; then die "--live is only valid with verify" 2; fi
  if [ -n "$keyfile" ] && [ -n "$KEY" ]; then die "give --pubkey-file or --key, not both" 2; fi
  [ -z "$keyfile" ] || KEY="$(read_key_file "$keyfile")"
  [ -z "$KEY" ] || check_key "$KEY"
  [ -z "$FROM" ] || check_from "$FROM"
  [ -z "$ADMIN_ARG" ] || [[ "$ADMIN_ARG" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || die "--admin-user must be a plain account name (^[a-z_][a-z0-9_-]{0,31}\$)" 2
  if [ "$cmd" = "install" ] && [ -z "$KEY" ]; then die "install needs --pubkey-file" 2; fi

  if [ "$live" -eq 1 ]; then
    HOST="$host"
    do_live
    exit 0
  fi

  if [ -n "$host" ]; then
    local remote="bash -s -- $cmd"
    [ -z "$KEY" ] || remote+=" --key $(printf '%q' "$KEY")"
    [ -z "$FROM" ] || remote+=" --from $(printf '%q' "$FROM")"
    [ -z "$ADMIN_ARG" ] || remote+=" --admin-user $(printf '%q' "$ADMIN_ARG")"
    exec ssh -o BatchMode=yes -- "$host" "$remote" < "${BASH_SOURCE[0]}"
  fi

  ADMIN="${ADMIN_ARG:-$(id -un)}"
  case "$cmd" in
    install) do_install ;;
    status | verify) do_report "$cmd" ;;
  esac
}

main "$@"
exit 0
