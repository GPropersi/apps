#!/bin/sh
# redis-entrypoint.sh: Redis cannot read a password from a file, so this wrapper builds the ACL file from the
# mounted admin password file at first start, then execs redis-server with the arguments it was given.
#
# Mounted read-only into the redis container (set as the service entrypoint). Never prints the password or its hash
# and never passes either in the environment or on a command line.
#
# users.acl (built only when absent; ACL SAVE rewrites it at runtime with the per-app users):
#   user default off
#   user admin on #<sha256 of the admin password> ~* &* +@all
#   user health on nopass -@all +ping
# The admin password is the file's content with exactly one trailing newline stripped (new-db and verify strip
# identically for REDISCLI_AUTH, so the hash and the client password always agree).
# The write is atomic: a temp file in the data dir (created under umask 077) is moved to users.acl, so the file is
# either absent or complete. A leftover temp file from an interrupted start is removed at the next start.
#
# REDIS_ENTRYPOINT_DATA and REDIS_ENTRYPOINT_ADMIN_FILE exist only so the offline test can use a scratch tree.
set -eu

data="${REDIS_ENTRYPOINT_DATA:-/data}"
admin_file="${REDIS_ENTRYPOINT_ADMIN_FILE:-/etc/platform/redis-admin.password}"
acl="$data/users.acl"
tmp="$data/users.acl.tmp"

umask 077
rm -f "$tmp"

if [ ! -e "$acl" ]; then
  [ -r "$admin_file" ] || { echo "redis-entrypoint: cannot read the admin password file" >&2; exit 1; }
  # "$(cat; printf x)" keeps every trailing newline, then exactly one is stripped.
  pw="$(cat "$admin_file"; printf x)"
  pw="${pw%x}"
  nl='
'
  case "$pw" in
    *"$nl") pw="${pw%"$nl"}" ;;
  esac
  [ -n "$pw" ] || { echo "redis-entrypoint: admin password file is empty" >&2; exit 1; }
  hash="$(printf '%s' "$pw" | sha256sum | cut -d ' ' -f 1)"
  pw=""
  {
    printf 'user default off\n'
    printf 'user admin on #%s ~* &* +@all\n' "$hash"
    printf 'user health on nopass -@all +ping\n'
  } > "$tmp"
  # Flush the data blocks before the rename: a power loss must not leave a rename without its content.
  sync "$tmp"
  mv "$tmp" "$acl"
fi

# Fail closed: an ACL file without the default user switched off (truncated, hand-edited) would leave Redis open.
# ACL SAVE appends more tokens after "off" (such as sanitize-payload), so accept those, but never "on".
awk '$1 == "user" && $2 == "default" && $3 == "off" { ok = 1; for (i = 4; i <= NF; i++) if ($i == "on") ok = 0 } END { exit ok ? 0 : 1 }' "$acl" \
  || { echo "redis-entrypoint: users.acl does not switch the default user off" >&2; exit 1; }

exec redis-server "$@"
