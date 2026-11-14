#!/usr/bin/env bash
# write-access-env.sh: write /etc/platform/access.env on the host from values kept off the host, so a new or rebuilt
# host needs no hand-typed file. The file holds the two Cloudflare Access settings `platform deploy` hands to every app:
# ACCESS_TEAM_DOMAIN and ACCESS_AUD. Both are account-specific, so they are never committed (the repo is public).
#
# Run it from the dev box. It is not a CI step: CI reaches the host only as the restricted `deploy` login, and this
# file must stay root-owned and unwritable by it, because it decides how Access identities are verified.
#
# Where the values come from, in order:
#   1. ACCESS_TEAM_DOMAIN and ACCESS_AUD in the environment (both or neither; one alone is an error);
#   2. otherwise the GitHub environment variables of the same names on the `production` environment of the repo in the
#      current directory (the repo is logged before reading; `gh variable get`, your own gh login; set them once with
#      `gh variable set ACCESS_TEAM_DOMAIN --env production`, then the same for ACCESS_AUD, and paste the value at the
#      prompt so it never lands in your shell history). Both are identifiers, not credentials.
# Both are validated with the installer's own rules (install-ingress.sh chk_access_file) before anything is sent, and a
# value is never printed, logged or put on a command line (it travels on ssh's stdin only).
#
# What it does on the host (one ssh call each, BatchMode, passwordless sudo needed, same as the installers):
#   - looks at the current file; the same content with owner root:root and mode 0644 reports `already` and changes nothing;
#   - a file with DIFFERENT content, or a symlink or other non-regular file, is replaced only with --force, otherwise the
#     run stops (fail closed); --check fails for a symlink or non-regular file;
#   - refuses to write when /etc/platform is not root-owned or is group or world writable;
#   - writes through a temp file in /etc/platform (root:root, 0644) and one mv, so a reader never sees a partial file;
#   - re-reads the result and fails unless the owner, mode and content are the intended ones.
#
# Usage: write-access-env.sh --host ALIAS [--env NAME] [--force] [--check]
#   --host    the ssh alias of the host (required)
#   --env     the GitHub environment to read the variables from (default production)
#   --force   replace an existing file whose content differs
#   --check   read-only: report whether the host file matches the source values, change nothing
#
# Exit: 0 written, already current, or (--check) matching | 1 failed, refused, or (--check) different or missing |
#       2 usage error or no usable values
set -uo pipefail

export LC_ALL=C

readonly ACCESS_FILE="/etc/platform/access.env"
readonly TEAM_RE='^[a-z0-9-]+\.cloudflareaccess\.com$'
readonly AUD_RE='^[0-9a-f]{64}$'
readonly GH_TIMEOUT=30
readonly SSH_TIMEOUT=120
# The remote script (run as root by `sudo -n bash -c`): temp file beside the target, then one mv.
# The directory must be root-owned and not group or world writable (stat prints uid:mode; a 4-digit mode keeps the group and
# other digits last), otherwise the run refuses before creating anything. mv -fT replaces a symlink at the target itself
# and fails on a directory instead of moving into it. No single quote may appear in it (it sits inside sudo -n bash -c '...').
# shellcheck disable=SC2016 # expands on the host, not here
readonly REMOTE_WRITE='set -eu; umask 022; d=/etc/platform; test -d $d; s=$(stat -c %u:%a $d); case $s in 0:*[2367]?|0:*[2367]) echo "$d is group or world writable" >&2; exit 1;; 0:*) ;; *) echo "$d is not owned by root" >&2; exit 1;; esac; t=$(mktemp $d/.access.env.XXXXXX); trap "rm -f $t" EXIT; cat > $t; chown root:root $t; chmod 0644 $t; mv -fT $t $d/access.env'

err() { printf 'write-access-env: %s\n' "$1" >&2; }
log() { printf '%s write-access-env: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >&2; }

HOST=""
TEAM=""
AUD=""
DESIRED=""

# phase <name> <cmd...>: run one external call with a timestamped start and its rc and duration. The command's own
# stdout is the caller's; stderr (error text, never a value) goes through.
phase() {
  local name="$1" start rc=0
  shift
  start=$SECONDS
  log "$name: start"
  "$@" || rc=$?
  log "$name: end rc=$rc $((SECONDS - start))s"
  return "$rc"
}

rssh() { timeout "$SSH_TIMEOUT" ssh -o BatchMode=yes -o ConnectTimeout=15 -- "$HOST" "$@"; }

# gh_var <key> <env>: prints the variable's value; its error text goes to stderr.
gh_var() { timeout "$GH_TIMEOUT" gh variable get "$1" --env "$2"; }

# gh_repo: prints the owner/name of the repo gh resolves from the current directory (the one gh_var will read).
gh_repo() { timeout "$GH_TIMEOUT" gh repo view --json nameWithOwner -q .nameWithOwner; }

# load_values <github-env>: sets TEAM and AUD, validated. Returns 2 when no usable value exists.
load_values() {
  local gh_env="$1" repo
  TEAM="${ACCESS_TEAM_DOMAIN:-}"
  AUD="${ACCESS_AUD:-}"
  if [ -n "$TEAM" ] || [ -n "$AUD" ]; then
    if [ -z "$TEAM" ] || [ -z "$AUD" ]; then
      err "set both ACCESS_TEAM_DOMAIN and ACCESS_AUD in the environment, or neither (then they are read from the GitHub environment $gh_env)"
      return 2
    fi
  else
    command -v gh >/dev/null 2>&1 || { err "no values in the environment and gh is not installed"; return 2; }
    repo="$(phase "resolve the GitHub repo of the current directory" gh_repo)" \
      || { err "could not resolve the GitHub repo of the current directory (run from the repo clone, logged in with gh)"; return 2; }
    log "reading ACCESS_TEAM_DOMAIN and ACCESS_AUD from environment $gh_env of GitHub repo $repo"
    TEAM="$(phase "read ACCESS_TEAM_DOMAIN from GitHub environment $gh_env" gh_var ACCESS_TEAM_DOMAIN "$gh_env")" \
      || { err "could not read the GitHub variable ACCESS_TEAM_DOMAIN of environment $gh_env (run from the repo, logged in with gh; set it with gh variable set)"; return 2; }
    AUD="$(phase "read ACCESS_AUD from GitHub environment $gh_env" gh_var ACCESS_AUD "$gh_env")" \
      || { err "could not read the GitHub variable ACCESS_AUD of environment $gh_env (run from the repo, logged in with gh; set it with gh variable set)"; return 2; }
  fi
  [[ "$TEAM" =~ $TEAM_RE ]] || { err "ACCESS_TEAM_DOMAIN is not <team>.cloudflareaccess.com (lowercase letters, digits, hyphens; no surrounding whitespace or CR)"; return 2; }
  [[ "$AUD" =~ $AUD_RE ]] || { err "ACCESS_AUD is not 64 lowercase hex characters (no surrounding whitespace or CR)"; return 2; }
  DESIRED="$(printf 'ACCESS_TEAM_DOMAIN=%s\nACCESS_AUD=%s\n' "$TEAM" "$AUD")"
}

# host_state: prints present (a regular file), absent, or other (a symlink or any non-regular file, which `platform deploy`
# refuses); returns non-zero when the host could not be asked (ssh or sudo failed).
host_state() {
  local s
  s="$(phase "look for $ACCESS_FILE on $HOST" rssh "sudo -n bash -c 'if test -L $ACCESS_FILE; then echo other; elif test -f $ACCESS_FILE; then echo present; elif test -e $ACCESS_FILE; then echo other; else echo absent; fi'" </dev/null)" || return 1
  case "$s" in present | absent | other) printf '%s\n' "$s" ;; *) return 1 ;; esac
}

# host_meta: prints uid:gid:mode of the file.
host_meta() { phase "stat $ACCESS_FILE on $HOST" rssh "sudo -n stat -c %u:%g:%a -- $ACCESS_FILE" </dev/null; }

# host_content: prints the file (trailing newlines dropped by the caller's substitution). Only ever compared, never shown.
host_content() { phase "read $ACCESS_FILE on $HOST" rssh "sudo -n cat -- $ACCESS_FILE" </dev/null; }

main() {
  local gh_env="production" force=0 check=0 state meta content rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --host) [ $# -ge 2 ] && [ -n "$2" ] || { err "missing value for --host"; return 2; }; HOST="$2"; shift 2 ;;
      --env) [ $# -ge 2 ] && [ -n "$2" ] || { err "missing value for --env"; return 2; }; gh_env="$2"; shift 2 ;;
      --force) force=1; shift ;;
      --check) check=1; shift ;;
      -h | --help) sed -n '2,/^set -/{/^set -/!p;}' "${BASH_SOURCE[0]}"; return 0 ;;
      *) err "unknown argument: $1"; return 2 ;;
    esac
  done
  [ -n "$HOST" ] || { err "usage: write-access-env.sh --host ALIAS [--env NAME] [--force] [--check]"; return 2; }
  case "$HOST" in -*) err "refusing option-looking --host: $HOST"; return 2 ;; esac

  load_values "$gh_env" || return $?

  state="$(host_state)" || { err "could not look at $ACCESS_FILE on $HOST (ssh or passwordless sudo failed); nothing was changed"; return 1; }

  if [ "$state" = "present" ]; then
    meta="$(host_meta)" || { err "could not stat $ACCESS_FILE on $HOST; nothing was changed"; return 1; }
    content="$(host_content)" || { err "could not read $ACCESS_FILE on $HOST; nothing was changed"; return 1; }
    if [ "$content" = "$DESIRED" ] && [ "$meta" = "0:0:644" ]; then
      printf 'already: %s on %s holds the source values (root:root 0644)\n' "$ACCESS_FILE" "$HOST"
      return 0
    fi
    if [ "$check" -eq 1 ]; then
      if [ "$content" = "$DESIRED" ]; then
        err "$ACCESS_FILE on $HOST has the source values but owner:group:mode is $meta, want 0:0:644"
      else
        err "$ACCESS_FILE on $HOST differs from the source values"
      fi
      return 1
    fi
    if [ "$content" != "$DESIRED" ] && [ "$force" -ne 1 ]; then
      err "$ACCESS_FILE on $HOST already exists with different content; nothing was changed. Rerun with --force to replace it"
      return 1
    fi
  elif [ "$state" = "other" ]; then
    if [ "$check" -eq 1 ]; then
      err "$ACCESS_FILE on $HOST is a symlink or not a regular file (platform deploy refuses it)"
      return 1
    fi
    if [ "$force" -ne 1 ]; then
      err "$ACCESS_FILE on $HOST is a symlink or not a regular file; nothing was changed. Rerun with --force to replace it with a regular file"
      return 1
    fi
  else
    if [ "$check" -eq 1 ]; then
      err "$ACCESS_FILE is missing on $HOST"
      return 1
    fi
  fi

  rc=0
  printf '%s\n' "$DESIRED" | phase "write $ACCESS_FILE on $HOST" rssh "sudo -n bash -c '$REMOTE_WRITE'" || rc=$?
  [ "$rc" -eq 0 ] || { err "the write failed (rc $rc); the previous file, if any, is untouched"; return 1; }

  meta="$(host_meta)" || { err "could not re-check $ACCESS_FILE after the write"; return 1; }
  content="$(host_content)" || { err "could not re-read $ACCESS_FILE after the write"; return 1; }
  [ "$meta" = "0:0:644" ] || { err "after the write $ACCESS_FILE has owner:group:mode $meta, want 0:0:644"; return 1; }
  [ "$content" = "$DESIRED" ] || { err "after the write $ACCESS_FILE does not hold the source values"; return 1; }
  printf 'wrote: %s on %s (root:root 0644)\n' "$ACCESS_FILE" "$HOST"
  printf 'next: make host-ingress HOST=%s ARGS="verify" checks the file with the rest of the stack\n' "$HOST"
}

main "$@"
