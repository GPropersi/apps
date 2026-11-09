#!/usr/bin/env bash
# Tests for app-new.sh and `make app-new` on a scratch copy of the repo (the scripts it calls, the real go-react
# template, the Makefile). Mocked: network and host tools are stubs that fail and log, git is a logging wrapper.
# Proves: the happy path yields a valid app with no placeholder left (also for a hyphenated name and a Go-keyword
# name); every refusal (invalid, reserved, pg_-prefixed, existing, declared elsewhere, unknown template, missing
# purpose) leaves apps/ unchanged; a forced failure mid-copy leaves nothing behind; the access scope and the Dockerfile
# pin checks are not vacuous (one defect each, separate runs, distinct messages); no network or ssh call is made and
# git runs only inside the scratch work tree.
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh. SC2016: the single-quoted
# `$HOME` and backticks in one purpose string, and the stub body, are meant literally. SC2012: ls -A of directories this
# test created, only to compare listings.
# shellcheck disable=SC1091,SC2154,SC2016,SC2012
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
root="$(cd "$here/../.." && pwd)"
placeholder="tmpl""goreact"

real_git="$(command -v git)"
t_init
export TMPDIR="$T_TMP/tmp"
mkdir -p "$TMPDIR"

S="$T_TMP/repo"
mkdir -p "$S/platform/scaffold" "$S/platform/registry" "$S/platform/lib" "$S/platform/lint" "$S/templates/go-react" "$S/apps"
cp -- "$root/platform/scaffold/app-new.sh" "$S/platform/scaffold/"
cp -- "$root/platform/registry/validate-app-yaml.sh" "$root/platform/registry/reserved-names.txt" "$S/platform/registry/"
cp -- "$root/platform/lib/yaml-subset.sh" "$S/platform/lib/"
cp -- "$root/platform/lint/check-apps.sh" "$root/platform/lint/check-template-copies.sh" "$S/platform/lint/"
cp -- "$root/Makefile" "$S/Makefile"
tar -C "$root/templates/go-react" --exclude=node_modules --exclude=./web/dist -cf - . | tar -C "$S/templates/go-react" -xf -
echo "apps" > "$S/apps/README.md"
app_new="$S/platform/scaffold/app-new.sh"
tpl="$S/templates/go-react"

# Network and host tools must never be called; git is the real one behind a logger.
for tool in ssh curl wget nc docker platform scp rsync; do t_stub "$tool" 97; done
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "git %%s\\n" "$*" >> "$CALL_LOG"\n'
  printf 'exec %q "$@"\n' "$real_git"
} > "$STUB_BIN/git"
chmod +x "$STUB_BIN/git"

snap() { find "$S/apps" -print0 | LC_ALL=C sort -z | xargs -0 -r stat -c '%n %F %s' | md5sum; }
leftovers() { ls -A "$TMPDIR" | tr '\n' ' '; }

# refuse <label> <want rc> <fixed text the output must carry> <args...>
refuse() {
  local label="$1" want_rc="$2" text="$3" before after
  shift 3
  before="$(snap)"
  run_cmd "$app_new" "$@"
  expect_rc "$label: exit status" "$want_rc"
  expect_out_has "$label: message" "$text"
  after="$(snap)"
  expect_eq "$label: apps/ unchanged" "$after" "$before"
  expect_eq "$label: no temp leftovers" "$(leftovers)" ""
}

# ---- happy path ----
run_cmd "$app_new" demo --purpose "Demo app for tests"
expect_rc "demo: scaffolded" 0
expect_out_has "demo: next steps name the test command" "make test-app APP=demo"
expect_out_has "demo: next steps mention access.env" "/etc/platform/access.env"
expect_file "demo: app.yaml" "$S/apps/demo/app.yaml"
expect_eq "demo: name" "$(sed -n 's/^name: //p' "$S/apps/demo/app.yaml")" "demo"
expect_eq "demo: owner default" "$(sed -n 's/^owner: //p' "$S/apps/demo/app.yaml")" "gpropersi"
expect_eq "demo: purpose" "$(sed -n 's/^purpose: //p' "$S/apps/demo/app.yaml")" "Demo app for tests"
expect_eq "demo: template kept" "$(sed -n 's/^template: //p' "$S/apps/demo/app.yaml")" "go-react"
expect_eq "demo: no placeholder in any file" "$(grep -rIl -- "$placeholder" "$S/apps/demo" | tr '\n' ' ')" ""
expect_eq "demo: no placeholder in any path" "$(find "$S/apps/demo" -name "*$placeholder*" | tr '\n' ' ')" ""
expect_eq "demo: APP_NAME" "$(sed -n 's/^export const APP_NAME = //p' "$S/apps/demo/web/src/appName.ts")" '"demo";'
expect_eq "demo: page title" "$(sed -n 's#.*<title>\(.*\)</title>.*#\1#p' "$S/apps/demo/web/index.html")" "demo"
expect_eq "demo: module path" "$(sed -n 's/^module //p' "$S/apps/demo/go.mod")" "github.com/gpropersi/apps/apps/demo"
expect_eq "demo: Go package identifier" "$(sed -n 's/^package //p' "$S/apps/demo/appmeta.go")" "app_demo"
expect_out_has_text "$(cat "$S/apps/demo/internal/app/run.go")" '"github.com/gpropersi/apps/apps/demo/internal/platform"' "demo: import path rewritten"
expect_out_has_text "$(cat "$S/apps/demo/internal/app/run.go")" 'app_demo "github.com/gpropersi/apps/apps/demo"' "demo: import alias is the identifier"
expect_eq "demo: nothing but the new app was added" "$(ls -A "$S/apps" | tr '\n' ' ')" "README.md demo "
expect_eq "demo: no temp leftovers" "$(leftovers)" ""
if cmp -s -- "$S/apps/demo/Dockerfile" "$tpl/Dockerfile"; then _pass; else _fail "demo: Dockerfile copied unchanged"; fi
if diff -r -q -- "$tpl/internal/platform" "$S/apps/demo/internal/platform" > /dev/null; then _pass; else _fail "demo: helper package byte-identical"; fi

# Offline: no network or host call, and git only inside the scratch tree (a temp dir under TMPDIR, never the repo). The
# call log is cumulative, so this is checked after the demo run and again at the very end over every run.
check_offline() { # <label>
  local tool
  for tool in ssh curl wget nc docker platform scp rsync; do
    if grep -Eq "^$tool( |\$)" "$CALL_LOG"; then _fail "$1: $tool was called"; else _pass; fi
  done
  expect_calls_has "$1: git ran in the scratch tree (init)" "git -C $TMPDIR/"
  if grep -Eq "^git -C $TMPDIR/[^ ]+ init " "$CALL_LOG" && grep -Eq "^git -C $TMPDIR/[^ ]+ add " "$CALL_LOG"; then _pass; else _fail "$1: the git wrapper saw init and add"; fi
  if grep -q '^git' "$CALL_LOG" && ! grep '^git' "$CALL_LOG" | grep -v "^git -C $TMPDIR/" | grep -q .; then _pass; else _fail "$1: every git call runs -C inside the scratch tree"; fi
  if grep -qF -- "$S" "$CALL_LOG"; then _fail "$1: a call mentions the repo"; else _pass; fi
}
check_offline "demo"

# The same name again, now existing.
refuse "existing apps/demo" 1 "already exists" demo --purpose "Again"

# ---- a hyphenated name, a keyword name, owner and purpose carrying sed/shell syntax ----
run_cmd "$app_new" demo-app --owner alice --purpose 'A&B \1 s#x#y# $HOME `id` ok'
expect_rc "hyphenated name" 0
expect_eq "hyphen: Go package identifier" "$(sed -n 's/^package //p' "$S/apps/demo-app/appmeta.go")" "app_demo_app"
expect_eq "hyphen: module path keeps the hyphen" "$(sed -n 's/^module //p' "$S/apps/demo-app/go.mod")" "github.com/gpropersi/apps/apps/demo-app"
expect_eq "hyphen: owner" "$(sed -n 's/^owner: //p' "$S/apps/demo-app/app.yaml")" "alice"
expect_eq "hyphen: purpose is literal" "$(sed -n 's/^purpose: //p' "$S/apps/demo-app/app.yaml")" 'A&B \1 s#x#y# $HOME `id` ok'
expect_eq "hyphen: no placeholder left" "$(grep -rIl -- "$placeholder" "$S/apps/demo-app" | tr '\n' ' ')" ""

run_cmd "$app_new" go --purpose "A Go keyword as a name"
expect_rc "keyword name" 0
expect_eq "keyword: Go package identifier is not the keyword" "$(sed -n 's/^package //p' "$S/apps/go/appmeta.go")" "app_go"

# ---- refusals leave apps/ unchanged ----
refuse "uppercase name" 1 "must match" Demo --purpose "x"
refuse "one-letter name" 1 "must match" a --purpose "x"
refuse "path in the name" 1 "must match" ../escape --purpose "x"
refuse "slash in the name" 1 "must match" a/b --purpose "x"
refuse "name with a space" 1 "must match" "a b" --purpose "x"
refuse "reserved name" 1 "is reserved" redis --purpose "x"
refuse "pg_ prefixed Postgres identifier" 1 "refused Postgres identifier" pg-thing --purpose "x"
refuse "the placeholder as a name" 1 "placeholder" "${placeholder}-x" --purpose "x"
refuse "unknown template" 1 "template 'go-htmx' is not available yet (available: go-react)" fresh --template go-htmx --purpose "x"
refuse "nonsense template" 1 "template '../x' is not available yet" fresh --template ../x --purpose "x"
refuse "owner that is an email" 1 "short handle" fresh --owner a@b.example --purpose "x"
refuse "purpose over 120 chars" 1 "maximum is 120" fresh --purpose "$(printf 'x%.0s' $(seq 130))"
refuse "multi-line purpose" 1 "single line" fresh --purpose $'one\ntwo'
refuse "missing purpose" 2 "--purpose" fresh
refuse "blank purpose" 2 "--purpose" fresh --purpose "   "
refuse "missing name" 2 "NAME is required" --purpose "x"
refuse "unknown flag" 2 "unknown argument" fresh --bogus

# A name already declared by another app's app.yaml (its directory name differs), exact or by Postgres identifier.
mkdir -p "$S/apps/dirname"
printf 'name: taken-name\n' > "$S/apps/dirname/app.yaml"
refuse "name declared by another app.yaml" 1 "already declared by apps/dirname/app.yaml" taken-name --purpose "x"
printf 'name: dup_one\n' > "$S/apps/dirname/app.yaml"
refuse "Postgres identifier already used by another app.yaml" 1 "already declared by apps/dirname/app.yaml" dup-one --purpose "x"
rm -r "$S/apps/dirname"

# A templates/ directory without an app.yaml is not a template (and is not listed as available).
mkdir -p "$S/templates/empty"
refuse "template dir without app.yaml" 1 "template 'empty' is not available yet (available: go-react)" fresh --template empty --purpose "x"
rmdir "$S/templates/empty"

# owner and purpose are plain text: control characters and leading or inner YAML syntax are refused.
for bad in 'x: y' '"q' "'q" 'a # b' '[x]' '{x}' '*a' '&a' '!a' '|a' '>a' '%a' '@a' '-a' '#a' '?a' ',a'; do
  refuse "purpose '$bad'" 1 "must be plain text" fresh --purpose "$bad"
done
refuse "control character in purpose" 1 "control characters" fresh --purpose $'bell\a'
refuse "YAML syntax in owner" 1 "must be plain text" fresh --owner '"x' --purpose "x"

# An ambient NAME, PURPOSE, OWNER or TEMPLATE in the environment is never used by make app-new.
before="$(snap)"
run_cmd env NAME=ambient PURPOSE=ambient make -C "$S" app-new
expect_rc "ambient NAME and PURPOSE are ignored" 2
expect_eq "ambient NAME and PURPOSE: apps/ unchanged" "$(snap)" "$before"
run_cmd env OWNER=ambient TEMPLATE=go-htmx make -C "$S" app-new NAME=envtest PURPOSE=x
expect_rc "ambient OWNER and TEMPLATE are ignored" 0
expect_eq "ambient OWNER ignored" "$(sed -n 's/^owner: //p' "$S/apps/envtest/app.yaml")" "gpropersi"
rm -r "$S/apps/envtest"

# The placeholder is found anywhere: in a binary file, in another case, in a path; a symlink or a newline path is refused.
printf 'x\0TmplGoReact\0' > "$tpl/blob.bin"
refuse "placeholder in a binary file" 1 "still present" nobin --purpose "x"
rm -f "$tpl/blob.bin"
printf 'tmpl_go_react\n' > "$tpl/variant.txt"
refuse "placeholder in another spelling" 1 "still present" novariant --purpose "x"
rm -f "$tpl/variant.txt"
printf 'x\n' > "$tpl/tmplgoreact.txt"
run_cmd "$app_new" renamed-file --purpose "x"
expect_rc "a file named with the placeholder is renamed" 0
expect_file "renamed file" "$S/apps/renamed-file/renamed-file.txt"
rm -r "$S/apps/renamed-file"
rm -f "$tpl/tmplgoreact.txt"
ln -s /etc/passwd "$tpl/link"
refuse "symlink in the template" 1 "contains symlinks" nolink --purpose "x"
rm -f "$tpl/link"

# ---- a forced failure mid-copy leaves no partial directory ----
failing="$T_TMP/failing-bin"
mkdir -p "$failing"
printf '#!/bin/sh\nexit 1\n' > "$failing/tar"
chmod +x "$failing/tar"
before="$(snap)"
run_cmd env "PATH=$failing:$PATH" "$app_new" midcopy --purpose "x"
expect_rc "failed copy: exit status" 1
expect_out_has "failed copy: message" "copying templates/go-react failed"
expect_eq "failed copy: apps/ unchanged" "$(snap)" "$before"
expect_eq "failed copy: no temp leftovers" "$(leftovers)" ""

# ---- the checks are not vacuous: one defect each, separate runs, distinct messages ----
# (1) access: public only (the app.yaml is valid for the registry; check-apps refuses it for this template).
cp -- "$tpl/app.yaml" "$T_TMP/app.yaml.orig"
printf 'access: public\n' >> "$tpl/app.yaml"
refuse "access: public" 1 "access 'public' is not supported by template go-react" nopublic --purpose "x"
expect_out_lacks "access: public run reports no Dockerfile defect" "pinned"
cp -- "$T_TMP/app.yaml.orig" "$tpl/app.yaml"
printf 'access: restricted\n' >> "$tpl/app.yaml"
refuse "access: restricted" 1 "access 'restricted' is not supported by template go-react" norestricted --purpose "x"
cp -- "$T_TMP/app.yaml.orig" "$tpl/app.yaml"
printf 'access: family\n' >> "$tpl/app.yaml"
run_cmd "$app_new" famok --purpose "x"
expect_rc "access: family passes" 0
rm -r "$S/apps/famok"
cp -- "$T_TMP/app.yaml.orig" "$tpl/app.yaml"

# (2) a Dockerfile defect only: an unpinned FROM, then a root USER.
cp -- "$tpl/Dockerfile" "$T_TMP/Dockerfile.orig"
sed -i '0,/@sha256:[0-9a-f]*/s///' "$tpl/Dockerfile"
refuse "unpinned FROM" 1 "is not pinned as @sha256" nounpin --purpose "x"
expect_out_lacks "unpinned FROM run reports no access defect" "access"
cp -- "$T_TMP/Dockerfile.orig" "$tpl/Dockerfile"
sed -i 's/^USER 65532:65532$/USER root/' "$tpl/Dockerfile"
refuse "root USER" 1 "final-stage USER root is not a literal numeric non-zero uid" noroot --purpose "x"
cp -- "$T_TMP/Dockerfile.orig" "$tpl/Dockerfile"

# (3) the helper copy drifting from the template: a placeholder in the template's helper dir is rewritten in the app's
# copy, so the copies differ (and the template's own helper dir is refused).
cp -- "$tpl/internal/platform/jobs.go" "$T_TMP/jobs.go.orig"
printf '\n// %s is the template app\n' "$placeholder" >> "$tpl/internal/platform/jobs.go"
refuse "placeholder in the template helpers" 1 "names the placeholder app" nodrift --purpose "x"
cp -- "$T_TMP/jobs.go.orig" "$tpl/internal/platform/jobs.go"

# The template is intact again: one more scaffold passes.
run_cmd "$app_new" restored --purpose "x"
expect_rc "template restored: scaffold passes" 0

# ---- make app-new ----
before="$(snap)"
run_cmd make -C "$S" -n app-new NAME=viamake PURPOSE="Via make"
expect_rc "make -n app-new" 0
expect_out_has "make -n app-new: calls the script" "platform/scaffold/app-new.sh"
expect_eq "make -n app-new: apps/ unchanged" "$(snap)" "$before"
run_cmd make -C "$S" app-new
expect_rc "make app-new without NAME" 2
expect_out_has "make app-new without NAME: usage" "usage: make app-new NAME=<name>"
run_cmd make -C "$S" app-new NAME=viamake PURPOSE="Via make" OWNER=bob
expect_rc "make app-new" 0
expect_eq "make app-new: owner passed" "$(sed -n 's/^owner: //p' "$S/apps/viamake/app.yaml")" "bob"
run_cmd make -C "$S" app-new NAME=viamake2 PURPOSE="Via make" TEMPLATE=go-htmx
expect_rc "make app-new unknown template (make reports a failed recipe as 2)" 2
expect_out_has "make app-new unknown template: message" "is not available yet"
expect_eq "no temp leftovers at the end" "$(leftovers)" ""

run_cmd make -C "$S" app-new NAME=nopurpose
expect_rc "make app-new without PURPOSE" 2
expect_out_has "make app-new without PURPOSE: usage" "usage: make app-new NAME=<name>"
expect_eq "no temp leftovers after the make cases" "$(leftovers)" ""
check_offline "whole run"

t_finish
