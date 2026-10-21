#!/usr/bin/env bash
# Tests for verify-ingress.sh with a curl stub: no network, no ssh. The stub serves response headers from fixture
# files shaped like real `curl -I` captures (CRLF line endings), one per hostname, else a default fixture.
# SC1091: lib.sh is sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# SC2016: the stub body is single-quoted on purpose (it expands when the stub runs).
# shellcheck disable=SC1091,SC2016,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/verify-ingress.sh"

t_init
t_stub ssh 0
t_stub sudo 0

DOMAIN="example.test"
FIX="$T_TMP/fixtures"
mkdir -p "$FIX"
export FIX

# The curl stub: logs its argv, takes the hostname from the last argument (https://<host>/), prints that host's
# fixture (else the default one), and exits 6 (could not resolve) when the fixture is the word UNREACHABLE.
cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl' >> "$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
url="${*: -1}"
h="${url#https://}"
h="${h%/}"
f="$FIX/$h"
[ -e "$f" ] || f="$FIX/default"
if [ "$(cat "$f")" = "UNREACHABLE" ]; then exit 6; fi
cat "$f"
STUB
chmod +x "$STUB_BIN/curl"

set_fixture() { # name kind
  case "$2" in
    gated) printf 'HTTP/2 302 \r\nlocation: https://team.cloudflareaccess.com/cdn-cgi/access/login/x?kid=1&redirect_url=%%2F\r\ncontent-length: 0\r\n\r\n' > "$FIX/$1" ;;
    open) printf 'HTTP/2 200 \r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: 120\r\n\r\n' > "$FIX/$1" ;;
    err500) printf 'HTTP/2 500 \r\ncontent-length: 0\r\n\r\n' > "$FIX/$1" ;;
    unreachable) printf 'UNREACHABLE' > "$FIX/$1" ;;
  esac
}

run_v() { # script-path args...
  local s="$1"
  shift
  t_reset_calls
  run_cmd env -u PLATFORM_DOMAIN bash "$s" "$@"
}

# ---- each access_gate_check rc maps to the right result ----
set_fixture default gated
run_v "$script" --domain "$DOMAIN"
expect_rc "gated (302 to the Access login) passes" 0
expect_out_has "gated prints PASS" "PASS:"
expect_out_has "gated prints OK" "verify-ingress: OK"

set_fixture default open
run_v "$script" --domain "$DOMAIN"
expect_rc "open (200, no challenge) fails" 1
expect_out_has "open has its own message" "WITHOUT an Access challenge"

set_fixture default err500
run_v "$script" --domain "$DOMAIN"
expect_rc "unconfirmed (500) fails" 1
expect_out_has "unconfirmed has its own message" "could not confirm Cloudflare Access"
expect_out_has "unconfirmed names the status" "HTTP 500"
expect_out_lacks "unconfirmed is not reported as open" "WITHOUT an Access challenge"

set_fixture default unreachable
run_v "$script" --domain "$DOMAIN"
expect_rc "unreachable fails" 1
expect_out_has "unreachable has its own message" "could not reach https://"
expect_out_lacks "unreachable is not reported as open" "WITHOUT an Access challenge"

# ---- the request is a random unused name under the domain ----
set_fixture default gated
run_v "$script" --domain "$DOMAIN"
expect_calls_has "the request goes to a random ingress-verify name" "https://ingress-verify-"
expect_calls_has "the request is under the domain" ".$DOMAIN/"
first="$(grep -oE 'ingress-verify-[0-9]+' "$CALL_LOG" | head -n 1)"
run_v "$script" --domain "$DOMAIN"
second="$(grep -oE 'ingress-verify-[0-9]+' "$CALL_LOG" | head -n 1)"
expect_eq "two runs pick different random names" "$([ "$first" != "$second" ] && echo yes || echo no)" "yes"

# ---- the domain comes from --domain or PLATFORM_DOMAIN, never a default ----
t_reset_calls
run_cmd env -u PLATFORM_DOMAIN bash "$script"
expect_rc "no domain exits 2" 2
expect_out_has "no domain says so" "no domain"
expect_eq "no domain made no network call" "$(t_calls)" ""

t_reset_calls
run_cmd env PLATFORM_DOMAIN="$DOMAIN" bash "$script"
expect_rc "PLATFORM_DOMAIN in the environment is used" 0
expect_calls_has "the environment domain reaches curl" ".$DOMAIN/"

t_reset_calls
run_cmd env -u PLATFORM_DOMAIN bash "$script" --domain 'Not A Domain'
expect_rc "an invalid domain exits 2" 2
expect_eq "an invalid domain made no network call" "$(t_calls)" ""

# ---- --expect-open: rc 1 passes only for the named host ----
set_fixture default gated
set_fixture "public.$DOMAIN" open
run_v "$script" --domain "$DOMAIN" --expect-open "public.$DOMAIN"
expect_rc "an open exception passes for the named host while the random name is gated" 0
expect_out_has "the exception is reported" "open as expected"

set_fixture default open
run_v "$script" --domain "$DOMAIN" --expect-open "public.$DOMAIN"
expect_rc "rc 1 on any other host (the random name) fails even with an exception named" 1
expect_out_has "the random name open is still reported" "WITHOUT an Access challenge"

set_fixture default gated
set_fixture "public.$DOMAIN" gated
run_v "$script" --domain "$DOMAIN" --expect-open "public.$DOMAIN"
expect_rc "the named exception host being gated fails" 1
expect_out_has "the mismatch is reported" "should be public"

set_fixture "public.$DOMAIN" unreachable
run_v "$script" --domain "$DOMAIN" --expect-open "public.$DOMAIN"
expect_rc "the named exception host being unreachable fails" 1

# ---- --host ALIAS only labels the output: no ssh or sudo, the on-host command is printed ----
set_fixture default gated
run_v "$script" --domain "$DOMAIN" --host myalias
expect_rc "--host ALIAS run passes" 0
expect_calls_lacks "--host made no ssh call" "ssh"
expect_calls_lacks "--host made no sudo call" "sudo"
expect_calls_lacks "the alias is not a request target" "myalias"
expect_out_has "the output is labelled with the alias" "host alias myalias"
expect_out_has "the on-host verify command is printed" 'make host-ingress HOST=myalias ARGS="verify"'

# ---- --probe-jobs is manual: it prints, never requests ----
run_v "$script" --domain "$DOMAIN" --probe-jobs "app.$DOMAIN"
expect_rc "--probe-jobs does not fail the run" 0
expect_out_has "--probe-jobs prints the manual check" "MANUAL (not run)"
expect_calls_lacks "--probe-jobs makes no request to the app host" "app.$DOMAIN"

# ---- usage errors ----
run_v "$script" --bogus
expect_rc "an unknown argument exits 2" 2
run_v "$script" --domain
expect_rc "a missing --domain value exits 2" 2

# ---- mutation: flipping the open classification to gated must be caught ----
# With the "200, no challenge" branch returning 0 (gated), an open host would pass; the open-fixture assertion above
# (rc 1) would then fail. Prove the mutation is real and that it flips the result.
mutant="$T_TMP/mutant.sh"
sed '/ACCESS_GATE_CODE" = "200"/{n;s/return 1/return 0/;}' "$script" > "$mutant"
if cmp -s "$script" "$mutant"; then _fail "the mutation changed the script" "mutant identical to the original"; else _pass; fi
set_fixture default open
run_v "$mutant" --domain "$DOMAIN"
expect_rc "mutation: open flipped to gated makes an open host pass, so the open-fixture assertion would fail" 0

# ---- Access-gate classification fixtures: lookalike and unrelated redirect targets are never a pass ----
printf 'HTTP/2 302 \r\nlocation: https://evilcloudflareaccess.com/cdn-cgi/access/login/x\r\ncontent-length: 0\r\n\r\n' > "$FIX/default"
run_v "$script" --domain "$DOMAIN"
expect_rc "a lookalike host (evilcloudflareaccess.com) redirect fails" 1
expect_out_has "the lookalike redirect is unconfirmed" "could not confirm Cloudflare Access"

printf 'HTTP/2 302 \r\nlocation: https://cloudflareaccess.com.evil.test/login\r\ncontent-length: 0\r\n\r\n' > "$FIX/default"
run_v "$script" --domain "$DOMAIN"
expect_rc "a suffix lookalike (cloudflareaccess.com.evil.test) redirect fails" 1
expect_out_has "the suffix lookalike is unconfirmed" "could not confirm Cloudflare Access"

printf 'HTTP/2 302 \r\nlocation: https://www.unrelated.test/somewhere\r\ncontent-length: 0\r\n\r\n' > "$FIX/default"
run_v "$script" --domain "$DOMAIN"
expect_rc "a 302 to an unrelated host fails" 1
expect_out_has "the unrelated 302 is unconfirmed" "could not confirm Cloudflare Access"
expect_out_has "the unrelated 302 names its status" "HTTP 302"

printf 'HTTP/2 403 \r\ncf-access-domain: team.cloudflareaccess.com\r\ncontent-length: 0\r\n\r\n' > "$FIX/default"
run_v "$script" --domain "$DOMAIN"
expect_rc "a cf-access response header fixture passes" 0
expect_out_has "the cf-access header fixture prints PASS" "PASS:"

# ---- more usage cases ----
run_v "$script" --domain "$DOMAIN" --expect-open 'Bad Host'
expect_rc "an invalid --expect-open value exits 2" 2
expect_calls_lacks "an invalid --expect-open value made no request" "curl"
run_v "$script" --domain "$DOMAIN" --probe-jobs 'Bad Host'
expect_rc "an invalid --probe-jobs value exits 2" 2
expect_calls_lacks "an invalid --probe-jobs value made no request" "curl"
run_v "$script" --domain "$DOMAIN" --expect-open
expect_rc "a missing --expect-open value exits 2" 2
run_v "$script" --domain "$DOMAIN" --probe-jobs
expect_rc "a missing --probe-jobs value exits 2" 2
run_v "$script" --help
expect_rc "--help exits 0" 0
expect_out_has "--help prints the usage" "Usage: verify-ingress.sh"
expect_calls_lacks "--help made no request" "curl"

# ---- structural marker assertions: always run, with or without the stronghold checkout ----
begin_n="$(grep -c '^# >>> access-gate (canonical: .claude/scripts/lib/access-gate.sh) >>>$' "$script" || true)"
end_n="$(grep -c '^# <<< access-gate <<<$' "$script" || true)"
expect_eq "the begin marker exists exactly once" "$begin_n" "1"
expect_eq "the end marker exists exactly once" "$end_n" "1"
block="$(sed -n '/^# >>> access-gate/,/^# <<< access-gate/p' "$script")"
if grep -q '^access_gate_check() {$' <<<"$block"; then _pass; else _fail "access_gate_check is defined inside the marked block"; fi
if grep -q 'cloudflareaccess.com' <<<"$block"; then _pass; else _fail "the marked block still carries the Access host check"; fi

# ---- pinned checksum of the vendored block: drift fails here even without the stronghold checkout ----
# On an intentional change, update the canonical block in the stronghold, re-vendor it, and replace this checksum with
# the output of: sed -n '/^# >>> access-gate/,/^# <<< access-gate/p' verify-ingress.sh | sha256sum
PINNED_SUM="e75c60d15e42db69b40e55f09d3e14c580da38d4926186f10b1870368fb48425"
got_sum="$(printf '%s\n' "$block" | sha256sum | cut -d' ' -f1)"
expect_eq "the vendored access-gate block matches its pinned checksum" "$got_sum" "$PINNED_SUM"

# ---- byte-identity with the canonical block, when the stronghold checkout is present ----
canon="${STRONGHOLD_DIR:-$HOME/code}/.claude/scripts/lib/access-gate.sh"
if [ -r "$canon" ]; then
  want="$(sed -n '/^# >>> access-gate/,/^# <<< access-gate/p' "$canon")"
  expect_eq "the vendored block is byte-identical to the canonical one" "$block" "$want"
else
  echo "NOTICE: $canon not found: byte-identity with the canonical access-gate block was not checked"
fi

t_finish
