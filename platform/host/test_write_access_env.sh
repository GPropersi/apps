#!/usr/bin/env bash
# Tests for write-access-env.sh with ssh and gh stubs: no network, no host. The ssh stub is a tiny stateful host: it keeps
# the access file and its owner:group:mode in a scratch directory, answers the script's look, stat and cat calls, and
# takes the write from stdin, so what reaches the "host" is exactly what the script streams.
# SC1091: lib.sh is sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# SC2016: the stub bodies are single-quoted on purpose (they expand when the stub runs).
# shellcheck disable=SC1091,SC2016,SC2154
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
# SSH_WRITE_META (the mode the write "produces", default 0:0:644).
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
    cat > "$f"
    printf '%s' "${SSH_WRITE_META:-0:0:644}" > "$HOSTDIR/meta"
    ;;
  *"test -e"*) if [ -e "$f" ]; then echo present; else echo absent; fi ;;
  *"stat -c"*) [ -e "$f" ] || exit 1; cat "$HOSTDIR/meta" ;;
  *"cat --"*) [ -e "$f" ] || exit 1; cat "$f" ;;
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
if [ "${GH_RC:-0}" -ne 0 ]; then echo "HTTP 404: Not Found ZQXD3" >&2; exit "$GH_RC"; fi
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
  run_cmd env -u ACCESS_TEAM_DOMAIN -u ACCESS_AUD -u SSH_FAIL -u SSH_WRITE_RC -u SSH_WRITE_META -u GH_RC -u GH_TEAM -u GH_AUD \
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

# ---- logging: every external call has a timestamped start and end with its rc ----
reset_host
run_w ACCESS_TEAM_DOMAIN="$TEAM" ACCESS_AUD="$AUD" -- --host alias
expect_out_has "the log marks the write's start" "write /etc/platform/access.env on alias: start"
expect_out_has "the log marks the write's end with rc and duration" "write /etc/platform/access.env on alias: end rc=0"

t_finish
