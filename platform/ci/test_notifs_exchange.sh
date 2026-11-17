#!/usr/bin/env bash
# Tests for the notifs-exchange helpers: notifs-apps.sh (only `notifs: true` apps are selected), notifs-exchange-name.sh
# (the registrar-mode name) and oidc-claims.sh (claim values decoded from a token, the token never printed).
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"

t_init
repo="$T_TMP/repo"
mkapp() { mkdir -p "$repo/apps/$1"; printf '%b' "$2" > "$repo/apps/$1/app.yaml"; }
mkapp on-app 'schema_version: 1\nname: on-app\nnotifs: true\nport: 8080\n'
mkapp off-app 'schema_version: 1\nname: off-app\nnotifs: false\n'
mkapp plain 'schema_version: 1\nname: plain\n'
mkapp spaced 'schema_version: 1\nnotifs:   true  \n'
mkapp trueish 'schema_version: 1\nnotifs: truely\n'
mkapp twice 'schema_version: 1\nnotifs: true\nnotifs: true\n'
mkapp nested 'schema_version: 1\njobs:\n  notifs: true\n'
mkapp quoted 'schema_version: 1\nnotifs: "true"\n'
mkdir -p "$repo/apps/no-yaml"

in_repo() { ( cd "$repo" || exit 99; "$@" ); }
apps_sh="$here/notifs-apps.sh"

run_cmd in_repo "$apps_sh" '["on-app","off-app","plain"]'
expect_rc "apps: mixed list" 0
expect_eq "apps: only the notifs: true app is kept" "$out" '["on-app"]'

run_cmd in_repo "$apps_sh" '["off-app","plain"]'
expect_rc "apps: none opted in" 0
expect_eq "apps: none opted in prints []" "$out" '[]'

run_cmd in_repo "$apps_sh" '[]'
expect_eq "apps: empty list prints []" "$out" '[]'

run_cmd in_repo "$apps_sh" '["spaced","on-app"]'
expect_eq "apps: extra spaces around true are accepted, order kept" "$out" '["spaced","on-app"]'

for n in trueish twice nested quoted no-yaml; do
  run_cmd in_repo "$apps_sh" "[\"$n\"]"
  expect_eq "apps: $n is never selected" "$out" '[]'
done

run_cmd in_repo "$apps_sh" '["missing-app"]'
expect_eq "apps: an app with no directory is dropped" "$out" '[]'

run_cmd in_repo "$apps_sh" '["on-app","Bad_Name"]'
expect_rc "apps: an invalid name is refused" 1
run_cmd in_repo "$apps_sh" 'not json'
expect_rc "apps: not JSON is refused" 1
run_cmd in_repo "$apps_sh"
expect_rc "apps: usage" 2

# the registrar-mode name
name_sh="$here/notifs-exchange-name.sh"
run_cmd "$name_sh" birthdays
expect_rc "name: simple" 0
expect_eq "name: birthdays" "$out" "birthdays"
run_cmd "$name_sh" my-app
expect_eq "name: hyphen becomes underscore" "$out" "my_app"
run_cmd "$name_sh" 'Bad Name'
expect_rc "name: refused name" 1
run_cmd "$name_sh" a
expect_rc "name: too short" 1
run_cmd "$name_sh"
expect_rc "name: usage" 2

# the claims
claims_sh="$here/oidc-claims.sh"
b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }
payload='{"workflow_ref":"owner/apps/.github/workflows/notifs-exchange.yml@refs/heads/main","ref":"refs/heads/main","environment":"production","sub":"repo:owner/apps:environment:production","extra":"~~~???>>>"}'
token="$(printf '{"alg":"RS256"}' | b64url).$(printf '%s' "$payload" | b64url).c2lnbmF0dXJl"

run_cmd "$claims_sh" <<< "$token"
expect_rc "claims: valid token" 0
expect_out_has "claims: workflow_ref" "workflow_ref=owner/apps/.github/workflows/notifs-exchange.yml@refs/heads/main"
expect_out_has "claims: ref" "ref=refs/heads/main"
expect_out_has "claims: environment" "environment=production"
expect_out_lacks "claims: the token is never printed" "$token"
expect_out_lacks "claims: nothing beyond the three claims" "sub="

none="$(printf '{"alg":"RS256"}' | b64url).$(printf '{"sub":"x"}' | b64url).c2ln"
run_cmd "$claims_sh" <<< "$none"
expect_rc "claims: missing claims print empty values" 0
expect_out_has "claims: empty environment" "environment="

run_cmd "$claims_sh" <<< "not-a-jwt"
expect_rc "claims: not a JWT" 1
run_cmd "$claims_sh" <<< "a.b.c"
expect_rc "claims: a payload that is not JSON" 1
run_cmd "$claims_sh" <<< ""
expect_rc "claims: empty input" 1
run_cmd "$claims_sh" extra
expect_rc "claims: usage" 2

t_finish
