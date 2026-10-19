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
