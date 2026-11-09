#!/usr/bin/env bash
# Tests for check-apps.sh against scratch git repos: a good app, a missing test, a missing Dockerfile, FROM pinning
# (digest, scratch, stage alias, tag-only), and the final-stage USER forms.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
check="$here/check-apps.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

digest="$(printf 'a%.0s' $(seq 64))"
passed=0
failed=0

# new_root: an empty git repo in $root.
new_root() {
  root="$tmp/root-$RANDOM"
  mkdir -p "$root"
  git -C "$root" init -q
}

# add_app <name> <Dockerfile text, or - for none> [no-test]
add_app() {
  local name="$1" df="$2" notest="${3:-}"
  mkdir -p "$root/apps/$name"
  printf 'name: %s\n' "$name" > "$root/apps/$name/app.yaml"
  if [ "$df" != "-" ]; then printf '%b' "$df" > "$root/apps/$name/Dockerfile"; fi
  if [ -z "$notest" ]; then printf '#!/usr/bin/env bash\nexit 0\n' > "$root/apps/$name/test_app.sh"; fi
  git -C "$root" add -A
}

run_check() {
  rc=0
  out="$("$check" --root "$root" 2>&1)" || rc=$?
}

expect_pass() {
  if [ "$rc" -eq 0 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: $1 (rc=$rc)"; echo "$out"; fi
}

# expect_fail <label> <regex the output must match>
expect_fail() {
  if [ "$rc" -eq 1 ] && grep -qE -- "$2" <<< "$out"; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1)); echo "FAIL: $1 (rc=$rc, wanted /$2/)"; echo "$out"
  fi
}

good="FROM alpine@sha256:$digest\nUSER 1000\n"

new_root; run_check
expect_pass "no apps passes"

new_root; add_app good "$good"; run_check
expect_pass "a good app passes"

new_root; add_app notests "$good" no-test; run_check
expect_fail "no test script" "^apps/notests: no tracked test_\\*\\.sh"

new_root; add_app nodf -; run_check
expect_fail "no Dockerfile" "^apps/nodf: no tracked Dockerfile"

new_root; add_app tagged "FROM alpine:3.20\nUSER 1000\n"; run_check
expect_fail "tag-only FROM" "^apps/tagged/Dockerfile: FROM alpine:3\\.20 is not pinned"

new_root; add_app shortdigest "FROM alpine@sha256:abc\nUSER 1000\n"; run_check
expect_fail "short digest" "^apps/shortdigest/Dockerfile: FROM alpine@sha256:abc is not pinned"

new_root; add_app multi "FROM golang@sha256:$digest AS build\nRUN true\nFROM build AS mid\nFROM alpine@sha256:$digest\nCOPY --from=build /a /a\nUSER 1000\n"; run_check
expect_pass "multi-stage with an alias FROM"

new_root; add_app multibad "FROM golang@sha256:$digest AS build\nFROM alpine:3\nUSER 1000\n"; run_check
expect_fail "unpinned second stage" "^apps/multibad/Dockerfile: FROM alpine:3 is not pinned"

new_root; add_app scr "FROM scratch\nUSER 1000\n"; run_check
expect_pass "FROM scratch"

new_root; add_app plat "FROM --platform=linux/arm64 alpine@sha256:$digest\nuser 1000\n"; run_check
expect_pass "FROM with a flag and a lowercase user"

new_root; add_app cont "# comment\nFROM alpine@sha256:$digest\nUSER \\\\\n  1000\n"; run_check
expect_pass "continuation lines and comments"

for u in 1000 1000:1000 65534; do
  new_root; add_app uok "FROM alpine@sha256:$digest\nUSER $u\n"; run_check
  expect_pass "USER $u"
done

# SC2016: the $-expanded USER values are literal Dockerfile text.
# shellcheck disable=SC2016
for u in app root 0 0:1000 00 '$UID' '${UID}:1000'; do
  new_root; add_app ubad "FROM alpine@sha256:$digest\nUSER $u\n"; run_check
  expect_fail "USER $u" "^apps/ubad/Dockerfile: final-stage USER .* is not a literal numeric non-zero uid"
done

new_root; add_app noimage "FROM\nUSER 1000\n"; run_check
expect_fail "FROM without an image" "^apps/noimage/Dockerfile: FROM without an image"

new_root; add_app nofrom "RUN true\nUSER 1000\n"; run_check
expect_fail "no FROM instruction" "^apps/nofrom/Dockerfile: no FROM instruction"

# A nested app.yaml is not an app: apps/good/sub/app.yaml (no Dockerfile or test beside it) must be skipped.
new_root; add_app good "$good"; mkdir -p "$root/apps/good/sub"; printf 'name: sub\n' > "$root/apps/good/sub/app.yaml"
git -C "$root" add -A; run_check
expect_pass "nested app.yaml is skipped"

new_root; add_app earlier "FROM golang@sha256:$digest AS build\nUSER 1000\nFROM alpine@sha256:$digest\n"; run_check
expect_fail "USER only in an earlier stage" "^apps/earlier/Dockerfile: final stage has no USER"

new_root; add_app none "FROM alpine@sha256:$digest\n"; run_check
expect_fail "no USER" "^apps/none/Dockerfile: final stage has no USER"

new_root; add_app lastwins "FROM alpine@sha256:$digest\nUSER root\nUSER 1000\n"; run_check
expect_pass "the last USER wins"

new_root; add_app lastbad "FROM alpine@sha256:$digest\nUSER 1000\nUSER root\n"; run_check
expect_fail "a later root USER wins" "final-stage USER root"

new_root; add_app cmt "FROM alpine@sha256:$digest\nUSER 1000\n# note \\\\\nUSER root\n"; run_check
expect_fail "a comment ending in a backslash does not swallow the next instruction" "final-stage USER root"

new_root; add_app onb "FROM alpine@sha256:$digest\nONBUILD USER root\nUSER 1000\n"; run_check
expect_pass "ONBUILD USER is ignored"

new_root; add_app up "FROM alpine@sha256:$digest AS Base\nFROM base\nUSER 1000\n"; run_check
expect_pass "uppercase AS keyword with a lowercase alias use"

# An untracked app directory is ignored (only tracked app.yaml files count).
new_root; mkdir -p "$root/apps/loose"; printf 'name: loose\n' > "$root/apps/loose/app.yaml"; run_check
expect_pass "untracked app is ignored"

# Access scope of template go-react: only an absent access key or `family` passes.
set_yaml() { # <app> <extra lines...>: app.yaml = name + template go-react + the extra lines
  local app="$1"
  shift
  { printf 'name: %s\ntemplate: go-react\n' "$app"; printf '%s\n' "$@"; } > "$root/apps/$app/app.yaml"
  git -C "$root" add -A
}
new_root; add_app gr "$good"; set_yaml gr; run_check
expect_pass "go-react app without access passes"

new_root; add_app gr "$good"; set_yaml gr "access: family"; run_check
expect_pass "go-react app with access family passes"

new_root; add_app gr "$good"; set_yaml gr "access: public"; run_check
expect_fail "go-react app with access public" "^apps/gr/app\\.yaml: access 'public' is not supported by template go-react"

new_root; add_app gr "$good"; set_yaml gr "access: restricted"; run_check
expect_fail "go-react app with access restricted" "^apps/gr/app\\.yaml: access 'restricted' is not supported by template go-react"

new_root; add_app gr "$good"; set_yaml gr "access: \"public\""; run_check
expect_fail "a quoted access value is read too" "access 'public' is not supported"

new_root; add_app gr "$good"; set_yaml gr "access:"; run_check
expect_fail "an empty access value fails closed" "access '' is not supported"

new_root; add_app other "$good"; printf 'name: other\ntemplate: go-htmx\naccess: public\n' > "$root/apps/other/app.yaml"; git -C "$root" add -A; run_check
expect_pass "access is only restricted for template go-react"

# CLI behaviour.
rc=0; out="$("$check" --bogus 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: unknown argument exits 2 (rc=$rc)"; fi
rc=0; out="$("$check" --root 2>&1)" || rc=$?
if [ "$rc" -eq 2 ]; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: missing --root value exits 2 (rc=$rc)"; fi

echo "check-apps tests: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
