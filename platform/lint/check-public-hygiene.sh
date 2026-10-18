#!/usr/bin/env bash
# check-public-hygiene.sh — fail when a tracked file looks like it leaks a secret or personal data.
#
# This repo is PUBLIC: no secrets, tokens, keys, tailnet names, ssh:// URLs or IP addresses, ever.
# Scans every tracked text file (git ls-files) and reports `FAIL <file>[:<line>] <rule>`; it never
# prints the matched text, so a leak is not copied into CI logs. Exit 1 on any finding.
#
# Allowlist (platform/lint/hygiene-allow.txt): one exact `<path> <rule>` pair per line, '#' comments.
# No wildcards, so an entry excuses exactly one rule in exactly one file.
#
# Usage: check-public-hygiene.sh [--root DIR] [--allow FILE]
set -euo pipefail

root=""
allow=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) root="${2:?missing value for --root}"; shift 2 ;;
    --allow) allow="${2:?missing value for --allow}"; shift 2 ;;
    -h|--help) sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$root" ] || root="$(git rev-parse --show-toplevel)"
cd "$root"
[ -n "$allow" ] || allow="$root/platform/lint/hygiene-allow.txt"

rule_names=(github-token github-pat aws-key slack-token private-key tailnet-name ssh-url)
rule_regexes=(
  'gh[pousr]_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  'AKIA[0-9A-Z]{16}'
  'xox[bp]-[A-Za-z0-9-]{10,}'
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  '[A-Za-z0-9-]+\.ts\.net'
  'ssh:[/][/]'
)

failures=0

is_allowed() {
  [ -f "$allow" ] && grep -qxF -- "$1 $2" "$allow"
}

report() {
  # $1 file, $2 rule, $3 line-number prefix (may be empty)
  if is_allowed "$1" "$2"; then
    return 0
  fi
  echo "FAIL $1${3:+:$3} $2"
  failures=$((failures + 1))
}

while IFS= read -r -d '' file; do
  [ -f "$file" ] || continue

  case "$file" in
    *.pem|*.key) report "$file" tracked-key-file "" ;;
  esac
  case "$file" in
    .env.example|.env.sample|*/.env.example|*/.env.sample) ;;
    .env|.env.*|*/.env|*/.env.*) report "$file" tracked-env "" ;;
  esac

  for i in "${!rule_names[@]}"; do
    while IFS=: read -r lineno _; do
      [ -n "$lineno" ] && report "$file" "${rule_names[$i]}" "$lineno"
    done < <(grep -InE -e "${rule_regexes[$i]}" -- "$file" || true)
  done

  # Any IPv4 literal except loopback / 0.0.0.0 (private LAN addresses are personal data too).
  while IFS=: read -r lineno _; do
    [ -n "$lineno" ] && report "$file" ipv4 "$lineno"
  done < <(grep -InoE '([0-9]{1,3}\.){3}[0-9]{1,3}' -- "$file" \
    | grep -vE '^[0-9]+:(127\.[0-9.]+|0\.0\.0\.0)$' || true)
done < <(git ls-files -z)

if [ "$failures" -gt 0 ]; then
  echo "public-hygiene: $failures finding(s). This repo is public; remove the data or add an exact allowlist entry." >&2
  exit 1
fi
echo "public-hygiene: OK"
