#!/usr/bin/env bash
# Tests for write-access-env.sh with ssh and gh stubs: no network, no host. The ssh stub is a tiny stateful host: it keeps
# the access file and its owner:group:mode in a scratch directory, answers the script's look, stat and cat calls, and
# takes the write from stdin, so what reaches the "host" is exactly what the script streams.
# SC1091: lib.sh is sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# SC2016: the stub bodies are single-quoted on purpose (they expand when the stub runs).
# SC2034: real_write sets rc and out for the expect_* helpers from lib.sh.
# shellcheck disable=SC1091,SC2016,SC2034,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/write-access-env.sh"

t_init

TEAM="example.cloudflareaccess.com"
AUD="$(printf '0%.0s' {1..64})"
OTHER_AUD="$(printf '1%.0s' {1..64})"
WANT="$(printf 'ACCESS_TEAM_DOMAIN=%s\nACCESS_AUD=%s\n' "$TEAM" "$AUD")"
HOSTDIR="$T_TMP/host"
export HOSTDIR

# The ssh stub. Knobs: SSH_FAIL=1 (every call exits 255), SSH_WRITE_RC (the write call's exit code; nothing is stored),
# SSH_WRITE_META (the mode the write "produces", default 0:0:644), SSH_BAD_DIR (the write refuses: bad /etc/platform),
# SSH_WRITE_BAD_CONTENT (the stored file differs from what was sent), SSH_CAT_FAIL_AFTER_WRITE (re-read fails). A file
# $HOSTDIR/symlink marks the seeded access file as a symlink (the look answers `other`).
cat > "$STUB_BIN/ssh" <<'STUB'
#!/usr/bin/env bash
printf 'ssh' >> "$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
if [ "${SSH_FAIL:-0}" = 1 ]; then echo "ssh: connect failed ZQXD2" >&2; exit 255; fi
while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do shift; done
shift
shift
cmd="$*"
f="$HOSTDIR/access.env"
case "$cmd" in
  *mktemp*)
    rc="${SSH_WRITE_RC:-0}"
    if [ "$rc" -ne 0 ]; then echo "remote write failed" >&2; exit "$rc"; fi
    if [ -n "${SSH_BAD_DIR:-}" ]; then echo "/etc/platform is group or world writable" >&2; exit 1; fi
    cat > "$f"
    if [ -n "${SSH_WRITE_BAD_CONTENT:-}" ]; then printf 'garbage\n' > "$f"; fi
    rm -f "$HOSTDIR/symlink"
    touch "$HOSTDIR/written"
    printf '%s' "${SSH_WRITE_META:-0:0:644}" > "$HOSTDIR/meta"
    ;;
  *"test -L"*) if [ -e "$HOSTDIR/symlink" ]; then echo other; elif [ -e "$f" ]; then echo present; else echo absent; fi ;;
  *"stat -c"*) [ -e "$f" ] || exit 1; cat "$HOSTDIR/meta" ;;
  *"cat --"*)
    [ -e "$f" ] || exit 1
    if [ -n "${SSH_CAT_FAIL_AFTER_WRITE:-}" ] && [ -e "$HOSTDIR/written" ]; then echo "cat failed" >&2; exit 1; fi
    cat "$f"
    ;;
  *) echo "unexpected remote command" >&2; exit 99 ;;
esac
STUB
chmod +x "$STUB_BIN/ssh"

# The gh stub: serves GH_TEAM / GH_AUD for `gh variable get <KEY> --env <ENV>`, exits GH_RC (with an error line) when set.
cat > "$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
printf 'gh' >> "$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
if [ "$1" = repo ]; then
  if [ "${GH_REPO_RC:-0}" -ne 0 ]; then echo "no git remote ZQXD4" >&2; exit "$GH_REPO_RC"; fi
  printf '%s\n' "${GH_REPO:-example/apps}"
  exit 0
fi
if [ "${GH_RC:-0}" -ne 0 ]; then echo "HTTP 404: Not Found ZQXD3" >&2; exit "$GH_RC"; fi
if [ -n "${GH_FAIL_KEY:-}" ] && [ "$3" = "$GH_FAIL_KEY" ]; then echo "HTTP 404: Not Found ZQXD5" >&2; exit 1; fi
case "$3" in
  ACCESS_TEAM_DOMAIN) printf '%s\n' "${GH_TEAM-}" ;;
  ACCESS_AUD) printf '%s\n' "${GH_AUD-}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$STUB_BIN/gh"

reset_host() {
  rm -rf "$HOSTDIR"
  mkdir -p "$HOSTDIR"
  t_reset_calls
}
seed_host() { # content [meta]
  printf '%s' "$1" > "$HOSTDIR/access.env"
  printf '%s' "${2:-0:0:644}" > "$HOSTDIR/meta"
}
# run_w <env assignments...> -- <script args...>: the script with no ambient ACCESS_* or stub knobs.
run_w() {
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  t_reset_calls
  run_cmd env -u ACCESS_TEAM_DOMAIN -u ACCESS_AUD -u SSH_FAIL -u SSH_WRITE_RC -u SSH_WRITE_META \
    -u SSH_BAD_DIR -u SSH_WRITE_BAD_CONTENT -u SSH_CAT_FAIL_AFTER_WRITE -u GH_RC -u GH_REPO_RC -u GH_REPO -u GH_FAIL_KEY -u GH_TEAM -u GH_AUD \
    "${envs[@]}" bash "$script" "$@"
}

# ---- values from the environment: a missing file is written, with the right content and mode ----
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias
expect_rc "env values: a missing file is written" 0
expect_out_has "env values: says wrote" "wrote: /etc/platform/access.env on alias"
expect_eq "env values: the host file holds exactly the two lines" "$(cat "$HOSTDIR/access.env")" "${WANT%$'\n'}"
expect_eq "env values: owner, group and mode are root:root 0644" "$(cat "$HOSTDIR/meta")" "0:0:644"
expect_out_lacks "env values: the AUD is never printed" "$AUD"
expect_out_lacks "env values: the team domain is never printed" "$TEAM"
expect_calls_lacks "env values: the AUD is never on an ssh command line" "$AUD"
expect_calls_lacks "env values: the team domain is never on an ssh command line" "$TEAM"
expect_calls_has "env values: every ssh call is BatchMode" "ssh -o BatchMode=yes"
expect_calls_has "env values: the write uses passwordless sudo and a temp file in /etc/platform" "mktemp"
expect_calls_lacks "env values: gh is not called when both values are in the environment" "gh variable"

# ---- idempotent: the same content with the right owner and mode changes nothing ----
reset_host
seed_host "${WANT%$'\n'}"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias
expect_rc "same file: succeeds" 0
expect_out_has "same file: reports already" "already: /etc/platform/access.env on alias"
expect_calls_lacks "same file: no write call" "mktemp"

# ---- different content is refused without --force and replaced with it ----
reset_host
seed_host "$(printf 'ACCESS_TEAM_DOMAIN=%s\nACCESS_AUD=%s' "$TEAM" "$OTHER_AUD")"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias
expect_rc "different file: refused without --force" 1
expect_out_has "different file: says to rerun with --force" "--force"
expect_calls_lacks "different file: no write call without --force" "mktemp"
expect_eq "different file: the host file is untouched" "$(cat "$HOSTDIR/access.env")" "$(printf 'ACCESS_TEAM_DOMAIN=%s\nACCESS_AUD=%s' "$TEAM" "$OTHER_AUD")"
expect_out_lacks "different file: the host's AUD is never printed" "$OTHER_AUD"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias --force
expect_rc "different file: replaced with --force" 0
expect_eq "different file: --force leaves the source values" "$(cat "$HOSTDIR/access.env")" "${WANT%$'\n'}"

# ---- right content, wrong mode: rewritten without --force (the content is not in doubt) ----
reset_host
seed_host "${WANT%$'\n'}" "0:0:666"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias
expect_rc "wrong mode: repaired" 0
expect_eq "wrong mode: back to root:root 0644" "$(cat "$HOSTDIR/meta")" "0:0:644"

# ---- the write's own result is re-checked ----
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" SSH_WRITE_META="0:0:666" -- --host alias
expect_rc "a wrong mode after the write fails the run" 1
expect_out_has "a wrong mode after the write is named" "owner:group:mode"
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" SSH_WRITE_RC=7 -- --host alias
expect_rc "a failing remote write fails the run" 1
expect_out_has "a failing remote write says the old file is untouched" "untouched"
expect_out_has "a failing remote write shows the remote error text" "remote write failed"

# ---- --check is read-only ----
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias --check
expect_rc "--check: a missing file fails" 1
expect_out_has "--check: names the missing file" "missing on alias"
expect_calls_lacks "--check: no write call for a missing file" "mktemp"
seed_host "${WANT%$'\n'}"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias --check
expect_rc "--check: a matching file passes" 0
seed_host "$(printf 'ACCESS_TEAM_DOMAIN=%s\nACCESS_AUD=%s' "$TEAM" "$OTHER_AUD")"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias --check
expect_rc "--check: a different file fails" 1
expect_out_has "--check: says it differs" "differs from the source values"
expect_calls_lacks "--check: never writes even with different content" "mktemp"

# ---- values from GitHub when the environment has none ----
reset_host
run_w GH_TEAM="$TEAM" GH_AUD="$AUD" -- --host alias
expect_rc "github values: written" 0
expect_eq "github values: the host file holds the GitHub values" "$(cat "$HOSTDIR/access.env")" "${WANT%$'\n'}"
expect_calls_has "github values: reads ACCESS_TEAM_DOMAIN from the production environment" "gh variable get ACCESS_TEAM_DOMAIN --env production"
expect_calls_has "github values: reads ACCESS_AUD from the production environment" "gh variable get ACCESS_AUD --env production"
reset_host
run_w GH_TEAM="$TEAM" GH_AUD="$AUD" -- --host alias --env staging
expect_calls_has "github values: --env picks the environment" "gh variable get ACCESS_AUD --env staging"
reset_host
run_w GH_RC=1 -- --host alias
expect_rc "github failing: exit 2, nothing sent" 2
expect_out_has "github failing: shows gh's error text" "ZQXD3"
expect_out_has "github failing: names the variable" "ACCESS_TEAM_DOMAIN"
expect_calls_lacks "github failing: no ssh call" "ssh"

# ---- invalid values never leave the machine and are never echoed ----
reset_host
run_w ACCESS_TEAM_DOMAIN="evil.example.test" ACCESS_AUD="$AUD" -- --host alias
expect_rc "a team domain outside cloudflareaccess.com is rejected" 2
expect_out_lacks "the rejected team domain is not echoed" "evil.example.test"
expect_calls_lacks "a rejected value makes no ssh call" "ssh"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="bad-aud-VALUE123" -- --host alias
expect_rc "a malformed AUD is rejected" 2
expect_out_lacks "the rejected AUD is not echoed" "VALUE123"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$(printf 'A%.0s' {1..64})" -- --host alias
expect_rc "an uppercase AUD is rejected (the installer wants lowercase hex)" 2
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="${AUD}0" -- --host alias
expect_rc "a 65-character AUD is rejected" 2
run_w ACCESS_TEAM_DOMAIN="$TEAM"$'\n'"X=1" ACCESS_AUD="$AUD" -- --host alias
expect_rc "a team domain with a newline is rejected" 2
run_w ACCESS_TEAM_DOMAIN="$TEAM" -- --host alias
expect_rc "only one of the two environment values is an error" 2
expect_out_has "the half-set error says both or neither" "both ACCESS_TEAM_DOMAIN and ACCESS_AUD"
expect_calls_lacks "the half-set error does not fall back to gh" "gh variable"

# ---- host failures change nothing and say so ----
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" SSH_FAIL=1 -- --host alias
expect_rc "an unreachable host fails" 1
expect_out_has "an unreachable host shows ssh's error text" "ZQXD2"
expect_out_has "an unreachable host says nothing was changed" "nothing was changed"

# ---- usage ----
run_w -- --host
expect_rc "--host without a value is a usage error" 2
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --env production
expect_rc "no --host is a usage error" 2
expect_calls_lacks "no --host makes no call" "ssh"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host -oProxyCommand=x
expect_rc "an option-looking --host is refused" 2
expect_calls_lacks "an option-looking --host makes no ssh call" "ssh"
run_w -- --bogus
expect_rc "an unknown argument is a usage error" 2
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias --env
expect_rc "--env without a value is a usage error" 2
expect_calls_lacks "--env without a value makes no call" "ssh"
run_w -- --help
expect_rc "--help succeeds" 0
expect_out_has "--help shows the usage line" "Usage: write-access-env.sh --host ALIAS"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host ''
expect_rc "an empty --host is a usage error" 2
expect_calls_lacks "an empty --host makes no call" "ssh"

# ---- a trailing CR or whitespace is rejected with a reason, never trimmed, nothing sent ----
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="${AUD}"$'\r' -- --host alias
expect_rc "an AUD with a trailing CR is rejected" 2
expect_out_has "the CR rejection says why" "no surrounding whitespace or CR"
expect_calls_lacks "the CR rejection makes no ssh call" "ssh"
run_w ACCESS_TEAM_DOMAIN="$TEAM "  ACCESS_AUD="$AUD" -- --host alias
expect_rc "a team domain with trailing whitespace is rejected" 2
expect_out_has "the whitespace rejection says why" "no surrounding whitespace or CR"
expect_calls_lacks "the whitespace rejection makes no ssh call" "ssh"

# ---- a symlink or non-regular file at the target is state `other`: never already, --check fails, --force replaces ----
reset_host
seed_host "${WANT%$'\n'}"
touch "$HOSTDIR/symlink"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias
expect_rc "a symlink with the right content is not already: refused without --force" 1
expect_out_lacks "a symlink is never reported already" "already:"
expect_out_has "a symlink refusal names it and says --force" "symlink or not a regular file"
expect_out_has "a symlink refusal says to rerun with --force" "--force"
expect_calls_lacks "a symlink refusal writes nothing" "mktemp"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias --check
expect_rc "--check fails for a symlink even with the right content" 1
expect_calls_lacks "--check on a symlink writes nothing" "mktemp"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias --force
expect_rc "--force replaces a symlink" 0
expect_out_has "--force on a symlink writes" "wrote: /etc/platform/access.env on alias"
expect_calls_has "--force on a symlink does write" "mktemp"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias
expect_out_has "after the replacement the file is a regular file and current" "already:"

# ---- a /etc/platform that is not safe makes the write refuse ----
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" SSH_BAD_DIR=1 -- --host alias
expect_rc "a bad /etc/platform fails the run" 1
expect_out_has "a bad /etc/platform shows the remote reason" "group or world writable"
expect_eq "a bad /etc/platform leaves no file" "$(ls "$HOSTDIR")" ""

# ---- GitHub source details ----
reset_host
run_w GH_TEAM="$TEAM" GH_AUD="$AUD" GH_REPO="example/apps" -- --host alias
expect_out_has "github values: the resolved repo is logged" "GitHub repo example/apps"
expect_calls_has "github values: the repo is resolved with gh repo view" "gh repo view"
run_w GH_REPO_RC=1 GH_TEAM="$TEAM" GH_AUD="$AUD" -- --host alias
expect_rc "an unresolvable repo is exit 2" 2
expect_out_has "an unresolvable repo shows gh's error" "ZQXD4"
expect_calls_lacks "an unresolvable repo reads no variable" "gh variable"
expect_calls_lacks "an unresolvable repo makes no ssh call" "ssh"
run_w GH_FAIL_KEY=ACCESS_AUD GH_TEAM="$TEAM" GH_AUD="$AUD" -- --host alias
expect_rc "the second variable failing is exit 2" 2
expect_out_has "the second variable failing names ACCESS_AUD" "GitHub variable ACCESS_AUD"
expect_calls_lacks "the second variable failing makes no ssh call" "ssh"
run_w GH_TEAM="" GH_AUD="$AUD" -- --host alias
expect_rc "an empty gh value is rejected" 2
expect_calls_lacks "an empty gh value makes no ssh call" "ssh"
mkdir -p "$T_TMP/nogh"
ln -sf "$(command -v bash)" "$T_TMP/nogh/bash"
run_w PATH="$T_TMP/nogh" -- --host alias
expect_rc "gh not installed is exit 2" 2
expect_out_has "gh not installed says so" "gh is not installed"

# ---- more host cases ----
reset_host
seed_host "${WANT%$'\n'}" "0:0:666"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias --check
expect_rc "--check: right content with a wrong mode fails" 1
expect_out_has "--check: names the wrong mode" "want 0:0:644"
expect_calls_lacks "--check: wrong mode is not repaired" "mktemp"
reset_host
seed_host "${WANT%$'\n'}"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias --force
expect_rc "--force on a current file succeeds" 0
expect_out_has "--force on a current file reports already" "already:"
expect_calls_lacks "--force on a current file writes nothing" "mktemp"
reset_host
seed_host "${WANT%$'\n'}" "1000:1000:644"
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias
expect_rc "a wrong owner with the right content is repaired" 0
expect_eq "a wrong owner is back to root:root" "$(cat "$HOSTDIR/meta")" "0:0:644"
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" SSH_CAT_FAIL_AFTER_WRITE=1 -- --host alias
expect_rc "a failing re-read after the write fails the run" 1
expect_out_has "a failing re-read is named" "could not re-read"
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" SSH_WRITE_BAD_CONTENT=1 -- --host alias
expect_rc "different content after the write fails the run" 1
expect_out_has "different content after the write is named" "does not hold the source values"
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias
expect_calls_has "the write command chowns to root:root" "chown root:root"
expect_calls_has "the write command sets mode 0644" "chmod 0644"
expect_calls_has "the write command replaces with mv -f" "mv -f"

# ---- the real remote write script, run under bash in a temp directory ----
# The script text is taken from write-access-env.sh itself (its REMOTE_WRITE line), with /etc/platform replaced by a temp
# directory. Minimal shim: chown (we are not root; it logs its arguments), mv (logs, then runs the real one), and stat
# (only the directory check answers DIR_STAT, so the uid and mode rules can be exercised without root).
eval "$(grep '^readonly REMOTE_WRITE=' "$script")"
rdir="$T_TMP/real/platform"
shim="$T_TMP/real/shim"
mkdir -p "$rdir" "$shim"
cat > "$shim/chown" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SHIM_LOG.chown"
[ -z "${CHOWN_FAIL:-}" ] || { echo "chown failed" >&2; exit 1; }
STUB
cat > "$shim/mv" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SHIM_LOG.mv"
PATH=/usr/bin:/bin exec mv "$@"
STUB
cat > "$shim/stat" <<'STUB'
#!/usr/bin/env bash
if [ -n "${DIR_STAT:-}" ] && [ "$1" = "-c" ] && [ -d "${*: -1}" ]; then echo "$DIR_STAT"; exit 0; fi
PATH=/usr/bin:/bin exec stat "$@"
STUB
chmod +x "$shim/chown" "$shim/mv" "$shim/stat"
export SHIM_LOG="$T_TMP/real/shim.log"
real_cmd="${REMOTE_WRITE//\/etc\/platform/$rdir}"
# real_write <env assignments...>: runs the substituted script with WANT on stdin; output in $out, status in $rc.
real_write() {
  rm -f "$SHIM_LOG.chown" "$SHIM_LOG.mv"
  rc=0
  out="$(printf '%s' "$WANT" | env -u CHOWN_FAIL -u DIR_STAT "$@" PATH="$shim:$PATH" bash -c "$real_cmd" 2>&1)" || rc=$?
}
real_leftovers() { find "$rdir" -name '.access.env.*' | wc -l | tr -d ' '; }

real_write DIR_STAT=0:755
expect_rc "real script: writes into a root-owned 755 directory" 0
expect_eq "real script: the file holds exactly what was streamed" "$(cat "$rdir/access.env")" "${WANT%$'\n'}"
expect_eq "real script: the mode is 0644" "$(stat -c %a "$rdir/access.env")" "644"
expect_eq "real script: no temp file is left behind" "$(real_leftovers)" "0"
expect_out_has_text "$(cat "$SHIM_LOG.chown")" "root:root $rdir/.access.env." "real script: chown root:root on a temp file inside the target directory"
expect_eq "real script: exactly one mv" "$(wc -l < "$SHIM_LOG.mv" | tr -d ' ')" "1"
expect_out_has_text "$(cat "$SHIM_LOG.mv")" "-fT $rdir/.access.env." "real script: the one mv is a forced rename from the target directory"
expect_out_has_text "$(cat "$SHIM_LOG.mv")" "$rdir/access.env" "real script: the mv lands on access.env"

# an existing symlink is replaced, never followed
printf 'UNTOUCHED\n' > "$T_TMP/real/elsewhere"
rm -f "$rdir/access.env"
ln -s "$T_TMP/real/elsewhere" "$rdir/access.env"
real_write DIR_STAT=0:755
expect_rc "real script: replaces a symlink at the target" 0
expect_eq "real script: the target is a regular file after the write" "$([ -L "$rdir/access.env" ] && echo link || echo file)" "file"
expect_eq "real script: the symlink's old target is untouched" "$(cat "$T_TMP/real/elsewhere")" "UNTOUCHED"
expect_eq "real script: the replaced file holds the new content" "$(cat "$rdir/access.env")" "${WANT%$'\n'}"

# a failure after the temp file exists removes it and leaves the old file alone
printf 'OLD\n' > "$rdir/access.env"
real_write DIR_STAT=0:755 CHOWN_FAIL=1
expect_rc "real script: a failing chown fails the run" 1
expect_eq "real script: a failed run leaves no temp file" "$(real_leftovers)" "0"
expect_eq "real script: a failed run leaves the old file" "$(cat "$rdir/access.env")" "OLD"
expect_eq "real script: a failed run never reaches mv" "$([ -e "$SHIM_LOG.mv" ] && echo ran || echo none)" "none"

# the directory rules: refuse before creating anything
for ds in 1000:755 0:775 0:757 0:777 0:1777; do
  real_write DIR_STAT="$ds"
  expect_rc "real script: directory $ds is refused" 1
  expect_eq "real script: directory $ds creates no temp file" "$(real_leftovers)" "0"
  expect_eq "real script: directory $ds leaves the old file" "$(cat "$rdir/access.env")" "OLD"
done
expect_out_has "real script: the group or world writable reason is shown" "group or world writable"
real_write DIR_STAT=1000:755
expect_out_has "real script: the not-root-owned reason is shown" "not owned by root"
real_write DIR_STAT=0:2755
expect_rc "real script: a setgid 2755 root directory is accepted" 0

# ---- logging: every external call has a timestamped start and end with its rc ----
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias
expect_out_has "the log marks the write's start" "write /etc/platform/access.env on alias: start"
expect_out_has "the log marks the write's end with rc and duration" "write /etc/platform/access.env on alias: end rc=0"

t_finish
