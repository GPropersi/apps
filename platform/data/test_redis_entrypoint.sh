#!/usr/bin/env bash
# Offline test for redis-entrypoint.sh: runs the real script against a throwaway /data and admin file with a stub
# redis-server on PATH that records its argv, its environment and the users.acl it was started with.
# The stub's shape is UNVERIFIED until the live run of the data stack (plan Step 6).
# shellcheck disable=SC1091
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"

t_init
# A fixed umask: the mode-600 check must prove the script's own umask 077, not the caller's.
umask 022
entry="$here/redis-entrypoint.sh"
secret="correct horse battery staple"
want_hash="$(printf '%s' "$secret" | sha256sum | cut -d ' ' -f 1)"

# The recording stub: argv and env go to files, the users.acl it sees is copied.
rec="$T_TMP/rec"
mkdir -p "$rec"
cat > "$STUB_BIN/redis-server" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC_DIR/argv"
env > "$REC_DIR/env"
if [ -e "$ENTRY_DATA/users.acl" ]; then cp "$ENTRY_DATA/users.acl" "$REC_DIR/acl"; else : > "$REC_DIR/no-acl"; fi
exit 0
EOF
chmod +x "$STUB_BIN/redis-server"

# fresh_case <name>: a new data dir, admin file path and recording dir; sets $d, $admin.
fresh_case() {
  d="$T_TMP/$1/data"
  admin="$T_TMP/$1/admin-file"
  rec="$T_TMP/$1/rec"
  mkdir -p "$d" "$rec"
}

# run_entry [args...]: run the entrypoint with the scratch paths; sets $rc and $out (stdout and stderr together).
run_entry() {
  rc=0
  out="$(REC_DIR="$rec" ENTRY_DATA="$d" REDIS_ENTRYPOINT_DATA="$d" REDIS_ENTRYPOINT_ADMIN_FILE="$admin" "$entry" "$@" 2>&1)" || rc=$?
}

# ---- no trailing newline and exactly one trailing newline give the same hash ----

fresh_case nonl
printf '%s' "$secret" > "$admin"
run_entry --maxmemory 96mb
expect_rc "entrypoint runs (no trailing newline)" 0
acl_nonl="$(cat "$rec/acl" 2>/dev/null)"
expect_out_has_text "$acl_nonl" "user admin on #$want_hash ~* &* +@all" "no trailing newline: admin hash is the sha256 of the password"

fresh_case onenl
printf '%s\n' "$secret" > "$admin"
run_entry --maxmemory 96mb
expect_rc "entrypoint runs (one trailing newline)" 0
acl_onenl="$(cat "$rec/acl" 2>/dev/null)"
expect_out_has_text "$acl_onenl" "user admin on #$want_hash ~* &* +@all" "one trailing newline: hash is the sha256 of the newline-stripped password"
expect_eq "both variants write the identical users.acl" "$acl_onenl" "$acl_nonl"

# ---- the content of users.acl ----

want_acl="$(printf 'user default off\nuser admin on #%s ~* &* +@all\nuser health on nopass -@all +ping\n' "$want_hash")"
expect_eq "users.acl is exactly the three expected lines" "$acl_onenl" "$want_acl"
expect_eq "users.acl is mode 600 (written under umask 077)" "$(stat -c '%a' "$d/users.acl")" "600"
expect_eq "no temp file left after a normal start" "$(find "$d" -name 'users.acl.tmp*' | wc -l | tr -d ' ')" "0"

# ---- arguments pass through, nothing printed, no secret in argv or env ----

expect_eq "redis-server receives the arguments unchanged" "$(tr '\n' ' ' < "$rec/argv")" "--maxmemory 96mb "
expect_eq "nothing is printed to stdout or stderr" "$out" ""
if [ -s "$rec/env" ]; then _pass; else _fail "the stub did not record its environment (the secret check below would be vacuous)"; fi
if grep -qF -e "$secret" -e "$want_hash" "$rec/argv" "$rec/env"; then _fail "the password or its hash reached the redis-server argv or environment"; else _pass; fi

# ---- an existing users.acl is left byte for byte untouched ----

fresh_case existing
printf '%s\n' "$secret" > "$admin"
printf 'user default off\nuser app1 on #aa ~app1:* +get\n' > "$d/users.acl"
cp "$d/users.acl" "$T_TMP/existing-before"
# A stale temp file next to an existing users.acl: only the entrypoint's own cleanup can remove it.
printf 'garbage\n' > "$d/users.acl.tmp"
run_entry --appendonly yes
expect_rc "entrypoint runs with an existing users.acl" 0
if cmp -s "$T_TMP/existing-before" "$d/users.acl"; then _pass; else _fail "an existing users.acl was modified"; fi
expect_eq "an existing users.acl start prints nothing" "$out" ""
expect_eq "a stale temp file is removed even when users.acl exists" "$(find "$d" -name 'users.acl.tmp*' | wc -l | tr -d ' ')" "0"

# An ACL SAVE rewrite keeps the default user off but appends tokens: still valid.
fresh_case saved
printf 'user default off sanitize-payload resetchannels -@all\nuser app1 on #aa ~app1:* +get\n' > "$d/users.acl"
run_entry --appendonly yes
expect_rc "an ACL SAVE style default-off line is accepted" 0

# ---- fail closed: an existing users.acl that does not switch the default user off must not start redis ----

bad_acl_case() {
  fresh_case "$1"
  printf '%s\n' "$2" > "$d/users.acl"
  run_entry --appendonly yes
  if [ "$rc" -ne 0 ]; then _pass; else _fail "$1: a users.acl without 'user default off' must fail the start"; fi
  if [ ! -e "$rec/argv" ]; then _pass; else _fail "$1: redis-server started with an open default user"; fi
  expect_out_has "$1: names the problem" "does not switch the default user off"
}
bad_acl_case acl-default-on 'user default on nopass ~* &* +@all'
bad_acl_case acl-no-default 'user app1 on #aa ~app1:* +get'
bad_acl_case acl-default-off-then-on 'user default off on'
fresh_case acl-empty
: > "$d/users.acl"
run_entry --appendonly yes
if [ "$rc" -ne 0 ] && [ ! -e "$rec/argv" ]; then _pass; else _fail "a zero-length users.acl (crash after rename) must fail the start"; fi

# ---- atomic write: an interrupted write leaves users.acl absent, the next start rebuilds it complete ----

fresh_case atomic
printf '%s\n' "$secret" > "$admin"
# A stale temp file from an earlier interrupted start must not survive.
printf 'garbage\n' > "$d/users.acl.tmp"
# The stub mv fails, as if the write was interrupted just before the rename; it and a stub sync log their argv in
# call order, so the test can check the flush happens first and that both paths are inside the data dir.
cat > "$STUB_BIN/mv" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC_DIR/mv-argv"
printf 'mv\n' >> "$REC_DIR/order"
exit 1
EOF
cat > "$STUB_BIN/sync" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$REC_DIR/sync-argv"
printf 'sync\n' >> "$REC_DIR/order"
exit 0
EOF
chmod +x "$STUB_BIN/mv" "$STUB_BIN/sync"
run_entry --appendonly yes
expect_eq "the temp file is flushed (sync) before it is renamed" "$(tr '\n' ' ' < "$rec/order" 2>/dev/null)" "sync mv "
expect_eq "sync is given the temp file in the data dir" "$(cat "$rec/sync-argv" 2>/dev/null)" "$d/users.acl.tmp"
expect_eq "mv moves the temp file in the data dir onto users.acl in the data dir" "$(tr '\n' ' ' < "$rec/mv-argv" 2>/dev/null)" "$d/users.acl.tmp $d/users.acl "
if [ "$rc" -ne 0 ]; then _pass; else _fail "an interrupted write must fail the start"; fi
if [ ! -e "$d/users.acl" ]; then _pass; else _fail "an interrupted write left a users.acl behind"; fi
if [ ! -e "$rec/argv" ]; then _pass; else _fail "redis-server started after an interrupted write"; fi
rm -f "$STUB_BIN/mv" "$STUB_BIN/sync"
run_entry --appendonly yes
expect_rc "the next start succeeds" 0
acl_rebuilt="$(cat "$rec/acl" 2>/dev/null)"
expect_eq "the next start rebuilds the complete users.acl" "$acl_rebuilt" "$acl_nonl"
expect_eq "the stale temp file is removed at the next start" "$(find "$d" -name 'users.acl.tmp*' | wc -l | tr -d ' ')" "0"

# ---- an empty and a missing admin file fail closed ----

fresh_case empty
: > "$admin"
run_entry --appendonly yes
if [ "$rc" -ne 0 ] && [ ! -e "$d/users.acl" ]; then _pass; else _fail "an empty admin file must fail the start without writing users.acl"; fi

fresh_case nofile
run_entry --appendonly yes
if [ "$rc" -ne 0 ] && [ ! -e "$d/users.acl" ]; then _pass; else _fail "a missing admin file must fail the start without writing users.acl"; fi

expect_out_has "a missing admin file says it cannot be read" "cannot read the admin password file"

# ---- exactly one trailing newline is stripped; unusual characters survive ----

# pw_case <name> <file content> <expected password>: the users.acl hash is the sha256 of the expected password.
pw_case() {
  local want
  fresh_case "$1"
  printf '%s' "$2" > "$admin"
  run_entry --appendonly yes
  want="$(printf '%s' "$3" | sha256sum | cut -d ' ' -f 1)"
  expect_rc "$1: entrypoint runs" 0
  if grep -qxF "user admin on #$want ~* &* +@all" "$d/users.acl"; then _pass; else _fail "$1: the admin hash is not the sha256 of the expected password"; fi
}
pw_case two-newlines $'pw\n\n' $'pw\n'
pw_case three-newlines $'pw\n\n\n' $'pw\n\n'
pw_case odd-characters $'a b%s\\ -x\n' 'a b%s\ -x'
pw_case ends-with-x 'abcx' 'abcx'

fresh_case lone-newline
printf '\n' > "$admin"
run_entry --appendonly yes
if [ "$rc" -ne 0 ] && [ ! -e "$d/users.acl" ]; then _pass; else _fail "a file holding only a newline is an empty password and must fail the start"; fi

t_finish
