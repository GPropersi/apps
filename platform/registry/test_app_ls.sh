#!/usr/bin/env bash
# Tests for app-ls.sh: registry fixtures in a scratch root and canned `platform ls` TSV, no docker or ssh.
# SC1091: lib.sh is sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/app-ls.sh"

t_init
tab=$'\t'

# make_app <root> <name> <owner> <template> <mem> [access]
make_app() {
  local dir="$1/apps/$2"
  mkdir -p "$dir"
  {
    echo "schema_version: 1"
    echo "name: $2"
    echo "owner: $3"
    echo "purpose: Fixture app"
    echo "template: $4"
    echo "memory_cap: $5"
    echo "port: 8080"
    if [ -n "${6:-}" ]; then echo "access: $6"; fi
  } > "$dir/app.yaml"
}

root="$T_TMP/root"
make_app "$root" chores family go-react 64m
make_app "$root" notes giovanni flask 128m public
make_app "$root" quiz giovanni node-hono 32m restricted

live="$T_TMP/live.tsv"
run_ls() { run_cmd bash "$script" --root "$root" "$@"; }
row_of() { grep -E "^$1 " <<<"$out" || true; }

# Registry only: offline, sorted, STATE is "-", the default access is family.
run_ls
expect_rc "registry-only listing" 0
expect_out_has "header" "APP"
expect_eq "header columns" "$(head -n 1 <<<"$out" | tr -s ' ')" "APP OWNER TEMPLATE MEM ACCESS STATE"
expect_eq "registry-only chores row" "$(row_of chores | tr -s ' ')" "chores family go-react 64m family -"
expect_eq "registry-only notes row" "$(row_of notes | tr -s ' ')" "notes giovanni flask 128m public -"
expect_eq "rows are sorted by app" "$(awk 'NR > 1 { print $1 }' <<<"$out" | tr '\n' ' ')" "chores notes quiz "

# Join with live state: health folded into STATE, absent -> not deployed.
printf 'chores\trunning\tunhealthy\nnotes\trunning\thealthy\n' > "$live"
run_ls --live-from "$live"
expect_rc "join with live state" 0
expect_eq "unhealthy folded into STATE" "$(row_of chores | tr -s ' ')" "chores family go-react 64m family running (unhealthy)"
expect_eq "healthy folded into STATE" "$(row_of notes | tr -s ' ')" "notes giovanni flask 128m public running (healthy)"
expect_eq "registered but absent is not deployed" "$(row_of quiz | tr -s ' ')" "quiz giovanni node-hono 32m restricted not deployed"
printf 'chores\texited\tnone\n' > "$live"
run_ls --live-from "$live"
expect_eq "health none prints the bare state" "$(row_of chores | tr -s ' ')" "chores family go-react 64m family exited"

# Empty live file (rc 0 from platform ls): every registered app is not deployed, exit 0.
: > "$live"
run_ls --live-from "$live"
expect_rc "empty live file" 0
expect_eq "empty live file: all not deployed" "$(grep -c 'not deployed' <<<"$out")" "3"

# A labelled container with no registry entry: listed as UNREGISTERED, non-zero.
printf 'chores\trunning\tnone\nstray\trunning\tnone\n' > "$live"
run_ls --live-from "$live"
expect_rc "unregistered container exits non-zero" 1
expect_eq "unregistered container is named" "$(row_of stray | tr -s ' ')" "stray - - - - UNREGISTERED"
expect_out_has "unregistered error line" "no apps/<name>/app.yaml"

# Malformed live input: error, non-zero, no table (the header is not printed either).
for bad in "chores${tab}running" "chores${tab}running${tab}none${tab}x" "Bad_App${tab}running${tab}none" "chores${tab}running${tab}weird" "chores${tab}${tab}none" "garbage"; do
  printf '%s\n' "$bad" > "$live"
  run_ls --live-from "$live"
  if [ "$rc" -ne 0 ]; then _pass; else _fail "bad live row exits non-zero: $bad" "rc=0"; fi
  expect_out_lacks "bad live row prints no table: $bad" "OWNER"
done
printf 'chores\trunning\tnone\nchores\texited\tnone\n' > "$live"
run_ls --live-from "$live"
if [ "$rc" -ne 0 ]; then _pass; else _fail "a repeated live app exits non-zero" "rc=0"; fi
expect_out_lacks "a repeated live app prints no table" "OWNER"
printf 'chores\trunning\tnone\n\nnotes\trunning\tnone\n' > "$live"
run_ls --live-from "$live"
if [ "$rc" -ne 0 ]; then _pass; else _fail "a blank line mid-file exits non-zero" "rc=0"; fi
expect_out_lacks "a blank line mid-file prints no table" "OWNER"
run_ls --live-from "$T_TMP/missing.tsv"
if [ "$rc" -ne 0 ]; then _pass; else _fail "a missing live file exits non-zero" "rc=0"; fi
expect_out_lacks "a missing live file prints no table" "OWNER"

# An invalid app.yaml stops before any output, even when other apps are fine.
bad_root="$T_TMP/bad-root"
make_app "$bad_root" chores family go-react 64m
make_app "$bad_root" broken family go-react 64m
printf 'unknown_key: 1\n' >> "$bad_root/apps/broken/app.yaml"
run_cmd bash "$script" --root "$bad_root"
if [ "$rc" -ne 0 ]; then _pass; else _fail "an invalid app.yaml exits non-zero" "rc=0"; fi
expect_out_has "the invalid file is named" "broken/app.yaml"
expect_out_lacks "an invalid app.yaml prints no partial table" "OWNER"
expect_out_lacks "an invalid app.yaml hides the valid apps" "chores family"

# Zero apps: header only, exit 0 (offline and with an empty live file).
empty_root="$T_TMP/empty-root"
mkdir -p "$empty_root"
run_cmd bash "$script" --root "$empty_root"
expect_rc "zero apps" 0
expect_eq "zero apps prints only the header" "$(grep -c . <<<"$out")" "1"
expect_out_has "zero apps header" "OWNER"
: > "$live"
run_cmd bash "$script" --root "$empty_root" --live-from "$live"
expect_rc "zero apps with an empty live file" 0

# Usage errors.
run_cmd bash "$script" --bogus
expect_rc "unknown option" 2
run_cmd bash "$script" --live-from
expect_rc "--live-from needs a value" 2

t_finish
