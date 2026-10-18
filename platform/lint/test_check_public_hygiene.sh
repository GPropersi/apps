#!/usr/bin/env bash
# Tests for check-public-hygiene.sh. Seeds are assembled from pieces so this file never trips the check itself.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
check="$here/check-public-hygiene.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

passed=0
failed=0

new_repo() {
  repo="$tmp/repo-$RANDOM"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf 'plain text\n' > "$repo/README.md"
  git -C "$repo" add README.md
}

add_file() {
  # $1 repo, $2 path, $3 content
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add -- "$2"
}

run_check() {
  rc=0
  out="$("$check" --root "$repo" --allow "$repo/allow.txt" 2>&1)" || rc=$?
}

expect_fail() {
  # $1 label, $2 rule expected in output, $3 seed that must NOT appear in output
  if [ "$rc" -eq 1 ] && grep -qE -- " $2\$" <<<"$out" && ! grep -qF -- "$3" <<<"$out"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "FAIL: $1 (rc=$rc)"; echo "$out"
  fi
}

expect_pass() {
  if [ "$rc" -eq 0 ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "FAIL: $1 (rc=$rc)"; echo "$out"
  fi
}

pad="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

new_repo; run_check; expect_pass "clean repo passes"

new_repo; seed="gh""p_$pad"; add_file "$repo" a.txt "$seed"; run_check
expect_fail "github token" github-token "$seed"

new_repo; seed="github""_pat_$pad"; add_file "$repo" a.txt "$seed"; run_check
expect_fail "github pat" github-pat "$seed"

new_repo; seed="AK""IAABCDEFGHIJKLMNOP"; add_file "$repo" a.txt "$seed"; run_check
expect_fail "aws key" aws-key "$seed"

new_repo; seed="xo""xb-1234567890-abc"; add_file "$repo" a.txt "$seed"; run_check
expect_fail "slack token" slack-token "$seed"

new_repo; seed="-----BEGIN RSA PRIV""ATE KEY-----"; add_file "$repo" a.txt "$seed"; run_check
expect_fail "private key header" private-key "$seed"

new_repo; seed="myhost.tail9"".ts.net"; add_file "$repo" a.txt "$seed"; run_check
expect_fail "tailnet name" tailnet-name "$seed"

new_repo; seed="ssh:/""/user@host"; add_file "$repo" a.txt "$seed"; run_check
expect_fail "ssh url" ssh-url "$seed"

new_repo; seed="8.8.8"".8"; add_file "$repo" a.txt "$seed"; run_check
expect_fail "public ipv4" ipv4 "$seed"

new_repo; seed="192.168.1"".20"; add_file "$repo" a.txt "$seed"; run_check
expect_fail "private ipv4" ipv4 "$seed"

new_repo; add_file "$repo" a.txt "listen on 127.0.0.1 and 0.0.0.0"; run_check
expect_pass "loopback and 0.0.0.0 pass"

new_repo; add_file "$repo" .env "X=1"; run_check
expect_fail "tracked .env" tracked-env "X=1"

new_repo; add_file "$repo" .env.example "X="; run_check
expect_pass ".env.example passes"

new_repo; seed="pem""body"; add_file "$repo" deploy/id.pem "$seed"; run_check
expect_fail "tracked pem" tracked-key-file "$seed"

new_repo; seed="key""body"; add_file "$repo" deploy/id.key "$seed"; run_check
expect_fail "tracked key" tracked-key-file "$seed"

new_repo; add_file "$repo" deploy/.env "X=1"; run_check
expect_fail "nested .env" tracked-env "X=1"

new_repo; add_file "$repo" deploy/.env.example "X="; add_file "$repo" .env.sample "X="; run_check
expect_pass "nested .env.example and .env.sample pass"

new_repo; add_file "$repo" .env.local "X=1"; run_check
expect_fail ".env.local" tracked-env "X=1"

new_repo; seed="8.8.8"".8"; add_file "$repo" a.txt "127.0.0.1 then $seed"; run_check
expect_fail "loopback mixed with public ip on one line" ipv4 "$seed"

new_repo; seed="gh""p_$pad"; printf '%s\0bin\n' "$seed" > "$repo/bin.dat"; git -C "$repo" add bin.dat; run_check
expect_pass "binary file is skipped"

new_repo; seed="gh""p_$pad"; add_file "$repo" a.txt $'one\ntwo\n'"$seed"; run_check
expect_fail "finding reports its line number" github-token "$seed"
if grep -qxF "FAIL a.txt:3 github-token" <<<"$out"; then
  passed=$((passed + 1))
else
  failed=$((failed + 1)); echo "FAIL: line number 3 not reported"; echo "$out"
fi

new_repo; seed="gh""p_$pad"; add_file "$repo" a.txt "$seed"; add_file "$repo" b.txt "$seed"; run_check
if grep -qF "2 finding(s)" <<<"$out"; then
  passed=$((passed + 1))
else
  failed=$((failed + 1)); echo "FAIL: finding count 2 not reported"; echo "$out"
fi

new_repo; seed="gh""p_$pad"; add_file "$repo" a.txt "$seed"
printf 'a.txt github-token\n' > "$repo/allow.txt"; run_check
expect_pass "exact allowlist entry excuses its file and rule"

new_repo; seed="gh""p_$pad"; add_file "$repo" a.txt "$seed"
printf 'b.txt github-token\n' > "$repo/allow.txt"; run_check
expect_fail "allowlist entry for another file does not excuse" github-token "$seed"

new_repo; seed="gh""p_$pad"; add_file "$repo" a.txt "$seed"
printf 'a.txt ssh-url\n* github-token\n' > "$repo/allow.txt"; run_check
expect_fail "allowlist is not a wildcard and not rule-agnostic" github-token "$seed"

new_repo; seed="gh""p_$pad"; add_file "$repo" a.txt "$seed"
printf '# a.txt github-token\n\n' > "$repo/allow.txt"; run_check
expect_fail "allowlist comment and blank lines excuse nothing" github-token "$seed"

new_repo; add_file "$repo" .env "X=1"
printf '.env tracked-env\n' > "$repo/allow.txt"; run_check
expect_pass "allowlist excuses tracked-env"

new_repo; seed="8.8.8"".8"; add_file "$repo" a.txt "$seed"
printf 'a.txt ipv4\n' > "$repo/allow.txt"; run_check
expect_pass "allowlist excuses ipv4"

# CLI behavior: argument handling and the default allowlist path.
run_raw() {
  rc=0
  out="$("$check" "$@" 2>&1)" || rc=$?
}

expect_rc() {
  # $1 label, $2 expected rc
  if [ "$rc" -eq "$2" ]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "FAIL: $1 (rc=$rc, want $2)"; echo "$out"
  fi
}

run_raw --help; expect_rc "--help exits 0" 0
run_raw --bogus; expect_rc "unknown argument exits 2" 2
run_raw --root; expect_rc "missing --root value exits nonzero" 2

new_repo; seed="gh""p_$pad"; add_file "$repo" a.txt "$seed"; run_raw --root "$repo"
expect_fail "no allowlist file: finding still fails" github-token "$seed"

new_repo; seed="gh""p_$pad"; add_file "$repo" a.txt "$seed"
mkdir -p "$repo/platform/lint"; printf 'a.txt github-token\n' > "$repo/platform/lint/hygiene-allow.txt"
git -C "$repo" add platform/lint/hygiene-allow.txt; run_raw --root "$repo"
expect_rc "default allowlist path is used" 0

echo "hygiene tests:$passed passed, $failed failed"
[ "$failed" -eq 0 ]
