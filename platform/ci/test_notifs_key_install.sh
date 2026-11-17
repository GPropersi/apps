#!/usr/bin/env bash
# Tests for notifs-key-install.sh against a stub `tailscale`: a dry run never reaches the key or the host, a real run
# sends the 4 stdin lines to `notifs-key <app>` and checks the printed sha256, and the key never appears in the output.
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/notifs-key-install.sh"

t_init
KEY='dak_ZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZZ'
CID='client-id-value'
CSEC='client-secret-value'
BASE='https://notifs.example.invalid'
KEY_HASH="$(printf '%s' "$KEY" | sha256sum | cut -d' ' -f1)"

# The stub logs argv, keeps its stdin for inspection and prints $STUB_HASH (default: the real hash) with exit $STUB_RC.
stub="$STUB_BIN/tailscale"
# The stub body is single-quoted on purpose: its variables expand when it runs.
# shellcheck disable=SC2016
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "tailscale" >> "$CALL_LOG"' \
  'for a in "$@"; do printf " %s" "$a" >> "$CALL_LOG"; done' \
  'printf "\n" >> "$CALL_LOG"' \
  'cat > "$T_TMP/stdin.txt"' \
  'printf "%s\n" "${STUB_HASH-}"' \
  'exit "${STUB_RC:-0}"' > "$stub"
chmod +x "$stub"

install_env() {
  env NOTIFS_KEY="$KEY" NOTIFS_ACCESS_CLIENT_ID="$CID" NOTIFS_ACCESS_CLIENT_SECRET="$CSEC" NOTIFS_BASE_URL="$BASE" \
    DEPLOY_HOST=hostx "$@"
}

# dry run: nothing is sent, even with a complete environment
t_reset_calls
rm -f "$T_TMP/stdin.txt"
run_cmd install_env DRY_RUN=true STUB_HASH="$KEY_HASH" "$script" birthdays
expect_rc "dry run: succeeds" 0
expect_eq "dry run: tailscale is never invoked" "$(t_calls)" ""
if [ ! -e "$T_TMP/stdin.txt" ]; then _pass; else _fail "dry run: nothing was piped to the host"; fi
expect_out_has "dry run: says so" "dry run"
expect_out_lacks "dry run: no key in the output" "$KEY"

# dry run needs no key or host at all
t_reset_calls
run_cmd env DRY_RUN=true "$script" birthdays
expect_rc "dry run: no key, no host" 0
expect_eq "dry run without a key: tailscale is never invoked" "$(t_calls)" ""

# real run
t_reset_calls
run_cmd install_env DRY_RUN=false STUB_HASH="$KEY_HASH" "$script" birthdays
expect_rc "real run: succeeds" 0
expect_calls_has "real run: the restricted subcommand and app" "tailscale ssh deploy@hostx notifs-key birthdays"
expect_eq "real run: the 4 stdin lines in order" "$(cat "$T_TMP/stdin.txt")" "$(printf '%s\n%s\n%s\n%s' "$KEY" "$CID" "$CSEC" "$BASE")"
expect_out_has "real run: the hash is reported" "sha256=$KEY_HASH"
expect_out_lacks "real run: no key in the output" "$KEY"
expect_out_lacks "real run: no client secret in the output" "$CSEC"
expect_calls_lacks "real run: the key is not in argv" "$KEY"
expect_calls_lacks "real run: the client secret is not in argv" "$CSEC"

# the host's hash differs (a well-formed sha256 of something else)
run_cmd install_env DRY_RUN=false STUB_HASH="$(printf '%064d' 0)" "$script" birthdays
expect_rc "hash mismatch" 1
expect_out_has "hash mismatch: named" "does not match"
expect_out_lacks "hash mismatch: no key in the output" "$KEY"
expect_out_lacks "hash mismatch: no client secret in the output" "$CSEC"
expect_out_lacks "hash mismatch: the host's hash is not echoed" "$(printf '%064d' 0)"

# the host prints something that is not a sha256
run_cmd install_env DRY_RUN=false STUB_HASH="garbage" "$script" birthdays
expect_rc "host output is not a sha256" 1
expect_out_has "host output is not a sha256: named" "did not report a sha256"
expect_out_lacks "host output is not a sha256: garbage not echoed" "garbage"

# the host refuses
run_cmd install_env DRY_RUN=false STUB_RC=1 STUB_HASH="" "$script" birthdays
expect_rc "host refuses" 1
expect_out_has "host refuses: 24 h hint" "within 24 h"
expect_out_lacks "host refuses: no key in the output" "$KEY"
expect_out_lacks "host refuses: no client secret in the output" "$CSEC"

# missing inputs
t_reset_calls
run_cmd env DRY_RUN=false NOTIFS_ACCESS_CLIENT_ID="$CID" NOTIFS_ACCESS_CLIENT_SECRET="$CSEC" NOTIFS_BASE_URL="$BASE" DEPLOY_HOST=hostx "$script" birthdays
expect_rc "real run without a key" 1
expect_eq "real run without a key: tailscale is never invoked" "$(t_calls)" ""
t_reset_calls
run_cmd env DRY_RUN=false NOTIFS_KEY="$KEY" NOTIFS_ACCESS_CLIENT_ID="$CID" NOTIFS_ACCESS_CLIENT_SECRET="$CSEC" NOTIFS_BASE_URL="$BASE" "$script" birthdays
expect_rc "real run without a host" 1
expect_eq "real run without a host: tailscale is never invoked" "$(t_calls)" ""

# DRY_RUN must be explicit: unset or odd values fail closed (never fall through to a write)
t_reset_calls
run_cmd install_env "$script" birthdays
expect_rc "DRY_RUN unset is refused" 2
run_cmd install_env DRY_RUN=maybe "$script" birthdays
expect_rc "DRY_RUN=maybe is refused" 2
expect_eq "refused DRY_RUN: tailscale is never invoked" "$(t_calls)" ""

run_cmd install_env DRY_RUN=false "$script"
expect_rc "usage" 2

t_finish
