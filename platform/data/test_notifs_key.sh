#!/usr/bin/env bash
# Mocked tests for notifs-key.sh (no docker, no network). The secrets root is a real temp directory with the setgid-style
# 2710 mode like new-db's tests use, the registry root is a temp tree standing in for /var/lib/platform/registry, and the
# per-app lock is the real flock. Every key and credential below is a fake fixture string.
# SC2016: the stub bodies are single-quoted on purpose, their variables expand when the stub runs. SC2034: rc is read by
# expect_rc from lib.sh.
# shellcheck disable=SC1091,SC2154,SC2016,SC2034
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/notifs-key.sh"
REAL_CHMOD="$(command -v chmod)"
REAL_MV="$(command -v mv)"
REAL_CHGRP="$(command -v chgrp)"
export REAL_MV

t_init
SECRETS="$T_TMP/secrets"
REGISTRY="$T_TMP/registry"
LOCKS="$T_TMP/locks"
LOGGER_LOG="$T_TMP/logger.log"
export LOGGER_LOG

KEY1='dak_ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ'
KEY2='dak_QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ'
CID1='fake-client-id'
CSEC1='fake-client-secret-0123456789abcdef'
BASE1='https://example.test'

if command -v flock >/dev/null 2>&1; then _pass; else _fail "flock is available for the lock test"; fi

# logger records its message so the audit trail can be checked for secrets.
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$*" >> "$LOGGER_LOG"\n'
  printf 'exit 0\n'
} > "$STUB_BIN/logger"
"$REAL_CHMOD" +x "$STUB_BIN/logger"

fresh() {
  rm -rf "$SECRETS" "$REGISTRY" "$LOCKS"
  mkdir -p "$SECRETS" "$REGISTRY" "$LOCKS"
  "$REAL_CHMOD" 2710 "$SECRETS"
  "$REAL_CHMOD" 1777 "$LOCKS"
  : > "$LOGGER_LOG"
  export NOTIFS_KEY_SECRETS_ROOT="$SECRETS"
  export NOTIFS_KEY_REGISTRY_ROOT="$REGISTRY"
  export NOTIFS_KEY_LOCK_DIR="$LOCKS"
  export NOTIFS_KEY_LOCK_WAIT=5
  export NOTIFS_KEY_STDIN_TIMEOUT=5
}

# deployed <app> <notifs line or empty>: a registry entry; secrets dir 2750 like new-db makes it.
deployed() {
  mkdir -p "$REGISTRY/$1" "$SECRETS/$1"
  "$REAL_CHMOD" 2750 "$SECRETS/$1"
  {
    printf 'schema_version: 1\nname: %s\nport: 8080\n' "$1"
    [ -z "${2:-}" ] || printf '%s\n' "$2"
  } > "$REGISTRY/$1/app.yaml"
}

# nk <app> <key> <cid> <csec> <base>: run with those four lines on stdin.
nk() {
  local app="$1"
  shift
  rc=0
  out="$(printf '%s\n' "$@" | bash "$script" "$app" 2>&1)" || rc=$?
}

sf() { cat "$SECRETS/${2:-myapp}/$1" 2>/dev/null; } # sf <file> [app]
# a snapshot of every file under the secrets root with its content, to prove nothing changed
snap() { find "$SECRETS" -type f ! -name '*.lock' -exec sh -c 'for f; do printf "%s\n" "$f"; cat "$f"; done' sh {} + | sort; }
count_named() { find "$1" -maxdepth 1 -name "$2" | wc -l; }

# ---- happy path ----

fresh
deployed myapp 'notifs: true'
nk myapp "$KEY1" "$CID1" "$CSEC1" "$BASE1"
expect_rc "happy path exits 0" 0
expect_eq "prints the sha256 of the key as its last line" "$(tail -n 1 <<<"$out")" "$(printf '%s' "$KEY1" | sha256sum | cut -d' ' -f1)"
expect_out_lacks "the output has no key" "$KEY1"
expect_eq "notifs-key content" "$(sf notifs-key)" "$KEY1"
expect_eq "notifs-access-client-id content" "$(sf notifs-access-client-id)" "$CID1"
expect_eq "notifs-access-client-secret content" "$(sf notifs-access-client-secret)" "$CSEC1"
expect_eq "notifs-base-url content" "$(sf notifs-base-url)" "$BASE1"
for f in notifs-key notifs-access-client-id notifs-access-client-secret notifs-base-url; do
  expect_eq "$f mode is 440 (same as new-db's files)" "$(/usr/bin/stat -c '%a' "$SECRETS/myapp/$f")" "440"
  expect_eq "$f has the group of the secrets root (same as new-db's files)" "$(/usr/bin/stat -c '%g' "$SECRETS/myapp/$f")" "$(/usr/bin/stat -c '%g' "$SECRETS")"
done
expect_eq "no temp file is left behind" "$(count_named "$SECRETS/myapp" '.tmp*')" "0"
expect_eq "the lock file is in the lock dir" "$(count_named "$LOCKS" 'myapp.lock')" "1"
expect_eq "no lock file in the secrets root" "$(count_named "$SECRETS" '*.lock')" "0"
if grep -qF -e "$KEY1" -e "$CSEC1" -e "$CID1" "$LOGGER_LOG"; then _fail "the log carries no key or credential"; else _pass; fi
if grep -q 'phase=write end rc=0' "$LOGGER_LOG" && grep -q 'end rc=0 dur=' "$LOGGER_LOG"; then _pass; else _fail "the log has phase and end lines with rc and duration" "$(cat "$LOGGER_LOG")"; fi

# a second run with a rotated key replaces the set; the key is renamed last
nk myapp "$KEY2" "$CID1" "$CSEC1" "$BASE1"
expect_rc "rotation exits 0" 0
expect_eq "the key rotated" "$(sf notifs-key)" "$KEY2"

# The group assertion above is vacuous when the temp dir's group equals the user's primary group (new files get it either
# way). When the user has a supplementary group different from the primary, chgrp the setgid secrets root to it and assert
# the new files inherit it; otherwise skip silently.
primary_gid="$(id -g)"
alt_gid=""
for g in $(id -G); do
  if [ "$g" != "$primary_gid" ]; then
    alt_gid="$g"
    break
  fi
done
if [ -n "$alt_gid" ] && "$REAL_CHGRP" "$alt_gid" "$SECRETS" 2>/dev/null; then
  "$REAL_CHGRP" "$alt_gid" "$SECRETS/myapp"
  "$REAL_CHMOD" 2710 "$SECRETS"
  "$REAL_CHMOD" 2750 "$SECRETS/myapp"
  rm -f "$SECRETS/myapp/notifs-key" "$SECRETS/myapp/notifs-access-client-id" "$SECRETS/myapp/notifs-access-client-secret" "$SECRETS/myapp/notifs-base-url"
  nk myapp "$KEY1" "$CID1" "$CSEC1" "$BASE1"
  expect_rc "a run under a differently-grouped secrets root exits 0" 0
  expect_eq "notifs-key inherits the secrets root's supplementary group" "$(/usr/bin/stat -c '%g' "$SECRETS/myapp/notifs-key")" "$alt_gid"
fi

# ---- the rename phase: key last, and a failed rename leaves the old key ----

# mv stub that records the destination basename of each call and delegates to the real mv.
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "%%s\\n" "$(basename "${@: -1}")" >> "$MV_LOG"\n'
  printf 'exec "$REAL_MV" "$@"\n'
} > "$STUB_BIN/mv"
"$REAL_CHMOD" +x "$STUB_BIN/mv"
MV_LOG="$T_TMP/mv-calls"
export MV_LOG
fresh
deployed ordered 'notifs: true'
: > "$MV_LOG"
nk ordered "$KEY1" "$CID1" "$CSEC1" "$BASE1"
expect_rc "an ordered run exits 0" 0
expect_eq "notifs-key is renamed last" "$(tail -n 1 "$MV_LOG")" "notifs-key"
expect_eq "all four files were renamed" "$(wc -l < "$MV_LOG" | tr -d ' ')" "4"

# mv stub that fails for notifs-base-url
{
  printf '#!/usr/bin/env bash\n'
  printf 'case "${@: -1}" in */notifs-base-url) exit 1 ;; esac\n'
  printf 'exec "$REAL_MV" "$@"\n'
} > "$STUB_BIN/mv"
fresh
deployed failmv 'notifs: true'
printf '%s' "$KEY1" > "$SECRETS/failmv/notifs-key"
nk failmv "$KEY2" "$CID1" "$CSEC1" "$BASE1"
expect_rc "a failed rename exits 1" 1
expect_out_has "the failed rename names the file" "notifs-base-url"
expect_eq "the old key is still in place (key renamed last)" "$(sf notifs-key failmv)" "$KEY1"
rm -f "$STUB_BIN/mv"

# restore the key set the refusal section below snapshots
fresh
deployed myapp 'notifs: true'
nk myapp "$KEY2" "$CID1" "$CSEC1" "$BASE1"
expect_rc "the refusal section's key set is seeded" 0

# ---- refusals leave an existing key set byte-identical ----

before="$(snap)"
refuse() { # <label> <app> <key> <cid> <csec> <base>
  local label="$1"
  shift
  nk "$@"
  expect_rc "$label: refused" 1
  expect_eq "$label: existing files untouched" "$(snap)" "$before"
  expect_eq "$label: no temp file" "$(count_named "$SECRETS/myapp" '.tmp*')" "0"
}
refuse "key without dak_ prefix" myapp 'abc_ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ' "$CID1" "$CSEC1" "$BASE1"
refuse "key too short" myapp 'dak_short' "$CID1" "$CSEC1" "$BASE1"
refuse "key too long" myapp "${KEY1}X" "$CID1" "$CSEC1" "$BASE1"
refuse "key with a bad character" myapp 'dak_ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZAA!' "$CID1" "$CSEC1" "$BASE1"
refuse "empty key" myapp '' "$CID1" "$CSEC1" "$BASE1"
refuse "http base url" myapp "$KEY1" "$CID1" "$CSEC1" 'http://example.test'
refuse "bare host base url" myapp "$KEY1" "$CID1" "$CSEC1" 'example.test'
refuse "empty client id" myapp "$KEY1" '' "$CSEC1" "$BASE1"
refuse "empty client secret" myapp "$KEY1" "$CID1" '' "$BASE1"
refuse "client id with a space" myapp "$KEY1" 'a b' "$CSEC1" "$BASE1"
expect_out_lacks "a refusal never prints the key" "$KEY1"

# stdin shape: three lines, five lines
rc=0
out="$(printf '%s\n%s\n%s\n' "$KEY1" "$CID1" "$CSEC1" | NOTIFS_KEY_STDIN_TIMEOUT=1 bash "$script" myapp 2>&1)" || rc=$?
expect_rc "three stdin lines refused" 1
expect_eq "three stdin lines: untouched" "$(snap)" "$before"
rc=0
out="$(printf '%s\n%s\n%s\n%s\nextra\n' "$KEY1" "$CID1" "$CSEC1" "$BASE1" | bash "$script" myapp 2>&1)" || rc=$?
expect_rc "five stdin lines refused" 1
expect_eq "five stdin lines: untouched" "$(snap)" "$before"
rc=0
out="$(printf '%s\n%s\n%s\n%s\nextra' "$KEY1" "$CID1" "$CSEC1" "$BASE1" | bash "$script" myapp 2>&1)" || rc=$?
expect_rc "an unterminated fifth line refused" 1
expect_eq "unterminated fifth line: untouched" "$(snap)" "$before"

# the stdin timeout fires with nothing written
rc=0
out="$({ printf '%s\n' "$KEY2"; sleep 4; } | NOTIFS_KEY_STDIN_TIMEOUT=1 bash "$script" myapp 2>&1)" || rc=$?
expect_rc "a stalled stdin times out and fails" 1
expect_out_has "the timeout names the step" "client id"
expect_eq "a stalled stdin: untouched" "$(snap)" "$before"

# ---- registry refusals ----

fresh
mkdir -p "$SECRETS/ghost"
"$REAL_CHMOD" 2750 "$SECRETS/ghost"
before="$(snap)"
nk ghost "$KEY1" "$CID1" "$CSEC1" "$BASE1"
expect_rc "an app that never deployed (no registry entry) is refused" 1
expect_out_has "the never-deployed refusal says why" "never deployed"
expect_eq "never deployed: nothing written" "$(snap)" "$before"

rm -rf "$REGISTRY"
nk ghost "$KEY1" "$CID1" "$CSEC1" "$BASE1"
expect_rc "a missing registry directory is refused" 1
expect_eq "missing registry: nothing written" "$(snap)" "$before"

fresh
# reg_refuse <label> <app> <registry notifs lines>: the app starts with an existing key set; the refusal must leave it byte-identical.
reg_refuse() {
  local label="$1" app="$2" snapshot
  deployed "$app" "$3"
  printf '%s' "$KEY2" > "$SECRETS/$app/notifs-key"
  printf '%s' "$CID1" > "$SECRETS/$app/notifs-access-client-id"
  printf '%s' "$CSEC1" > "$SECRETS/$app/notifs-access-client-secret"
  printf '%s' "$BASE1" > "$SECRETS/$app/notifs-base-url"
  snapshot="$(snap)"
  nk "$app" "$KEY1" "$CID1" "$CSEC1" "$BASE1"
  expect_rc "$label: refused" 1
  expect_eq "$label: existing key set untouched" "$(snap)" "$snapshot"
}
reg_refuse "an app without notifs" plain ''
reg_refuse "an app with notifs: false" off 'notifs: false'
reg_refuse "an app with notifs: yes" odd 'notifs: yes'
reg_refuse "an indented notifs: true only" indented '  notifs: true'
reg_refuse "a quoted notifs: true" quoted 'notifs: "true"'
reg_refuse "a duplicate notifs: false and notifs: true" dup $'notifs: false\nnotifs: true'

# an unknown app name shape
nk 'Bad_App' "$KEY1" "$CID1" "$CSEC1" "$BASE1"
expect_rc "a malformed app name is a usage error" 2

# no argument, extra argument
rc=0
out="$(printf '%s\n' "$KEY1" | bash "$script" 2>&1)" || rc=$?
expect_rc "no argument is a usage error" 2
rc=0
out="$(printf '%s\n' "$KEY1" | bash "$script" a b 2>&1)" || rc=$?
expect_rc "an extra argument is a usage error" 2

# ---- secrets directory: absent or symlinked ----

fresh
deployed gone 'notifs: true'
rm -rf "$SECRETS/gone"
nk gone "$KEY1" "$CID1" "$CSEC1" "$BASE1"
expect_rc "an absent secrets directory is refused" 1
if [ -e "$SECRETS/gone" ]; then _fail "an absent secrets directory is not created"; else _pass; fi

fresh
deployed linked 'notifs: true'
rm -rf "$SECRETS/linked"
mkdir -p "$T_TMP/elsewhere"
ln -s "$T_TMP/elsewhere" "$SECRETS/linked"
nk linked "$KEY1" "$CID1" "$CSEC1" "$BASE1"
expect_rc "a symlinked secrets directory is refused" 1
expect_eq "nothing written through the symlink" "$(find "$T_TMP/elsewhere" -mindepth 1 | wc -l)" "0"

# a symlinked target file is refused and not followed
fresh
deployed tgt 'notifs: true'
echo precious > "$T_TMP/precious"
ln -s "$T_TMP/precious" "$SECRETS/tgt/notifs-key"
printf '%s' "$CID1" > "$SECRETS/tgt/notifs-access-client-id"
printf '%s' "$CSEC1" > "$SECRETS/tgt/notifs-access-client-secret"
printf '%s' "$BASE1" > "$SECRETS/tgt/notifs-base-url"
snapshot="$(snap)"
nk tgt "$KEY1" "$CID1" "$CSEC1" "$BASE1"
expect_rc "a symlinked notifs-key is refused" 1
expect_eq "the symlink target is untouched" "$(cat "$T_TMP/precious")" "precious"
expect_eq "the existing credentials are untouched" "$(snap)" "$snapshot"

# ---- the per-app lock is taken ----

fresh
deployed locked 'notifs: true'
exec 8>>"$LOCKS/locked.lock"
flock -n 8
rc=0
out="$(printf '%s\n' "$KEY1" "$CID1" "$CSEC1" "$BASE1" | NOTIFS_KEY_LOCK_WAIT=1 bash "$script" locked 2>&1)" || rc=$?
expect_rc "a held per-app lock makes it refuse after the wait" 1
expect_out_has "the lock refusal says so" "holds the lock"
expect_eq "locked: nothing written" "$(count_named "$SECRETS/locked" 'notifs-*')" "0"
exec 8>&-
nk locked "$KEY1" "$CID1" "$CSEC1" "$BASE1"
expect_rc "after the lock is released it succeeds" 0

# a missing lock dir is refused before any write
fresh
deployed nolock 'notifs: true'
rm -rf "$LOCKS"
nk nolock "$KEY1" "$CID1" "$CSEC1" "$BASE1"
expect_rc "a missing lock directory is refused" 1
expect_eq "no lock dir: nothing written" "$(count_named "$SECRETS/nolock" 'notifs-*')" "0"

t_finish
