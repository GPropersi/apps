#!/usr/bin/env bash
# app-new.sh: scaffold apps/<name>/ from a template under templates/. Offline: no network, ssh or `platform new-db`
# call, and no git against the real repository (git runs only inside a throwaway scratch work tree).
#
#   platform/scaffold/app-new.sh NAME --purpose "<one line>" [--template T] [--owner O]
#   make app-new NAME=<name> PURPOSE="<one line>" [TEMPLATE=go-react] [OWNER=gpropersi]
#
# Exit 0: apps/<name>/ was created. Exit 1: refused or failed; apps/ is exactly as before. Exit 2: usage.
#
# Steps (each failure removes everything this script made, by an EXIT trap):
#   1. validate NAME (the registry validator: name rule, reserved-names.txt, Postgres identifier rule), refuse an
#      existing apps/<name>/ or a name (or Postgres identifier) already declared by any apps/*/app.yaml;
#   2. TEMPLATE must be a directory under templates/ holding an app.yaml;
#   3. copy the template into a temp dir under apps/, replace the placeholder app name (the Go package identifier
#      becomes app_<name with - as _>, so a name such as `go` or `map` never collides with a Go keyword), write
#      owner and purpose into app.yaml, and check that no placeholder is left;
#   4. build a scratch git work tree (outside the repo) holding only the new app and the template, `git add` it, and run
#      validate-app-yaml.sh, check-apps.sh and check-template-copies.sh against it (those two read only tracked files,
#      so an untracked scaffold would pass vacuously);
#   5. rename the temp dir to apps/<name>/.
set -uo pipefail

# The scratch work tree must not inherit the caller's git environment (a hook or `git rebase --exec` would point git at
# the REAL repository) or the user's git config (excludes, hooks, templates change what `git add` tracks).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_NAMESPACE GIT_ALTERNATE_OBJECT_DIRECTORIES
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
apps="$repo/apps"
templates="$repo/templates"
placeholder="tmpl""goreact"

die() { echo "app-new: $*" >&2; exit 1; }
usage() {
  echo "usage: app-new.sh NAME --purpose \"<one line>\" [--template T] [--owner O]" >&2
  exit 2
}

name=""
template="go-react"
owner="gpropersi"
purpose=""
have_purpose=0
while [ $# -gt 0 ]; do
  case "$1" in
    --template) [ $# -ge 2 ] || usage; template="$2"; shift 2 ;;
    --owner) [ $# -ge 2 ] || usage; owner="$2"; shift 2 ;;
    --purpose) [ $# -ge 2 ] || usage; purpose="$2"; have_purpose=1; shift 2 ;;
    -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
    -*) echo "app-new: unknown argument: $1" >&2; usage ;;
    *) [ -z "$name" ] || usage; name="$1"; shift ;;
  esac
done
[ -n "$name" ] || { echo "app-new: NAME is required" >&2; usage; }
if [ "$have_purpose" -ne 1 ] || [[ "$purpose" =~ ^[[:space:]]*$ ]]; then
  echo "app-new: --purpose (PURPOSE=) is required: one line saying what the app is for" >&2
  usage
fi
case "$purpose$owner" in
  *$'\n'* | *$'\r'*) die "owner and purpose must be a single line" ;;
  *) ;;
esac
# owner and purpose are written as plain YAML scalars: no control characters, no leading YAML syntax character, and no
# ": " or " #" inside (the registry validator is the second guard).
for v in "$owner" "$purpose"; do
  if [[ "$v" =~ [[:cntrl:]] ]]; then die "owner and purpose must not contain control characters"; fi
  case "$v" in
    [\"\'\[\]\{\}\&\*\!\|\>%@\`#?:,-]* | *": "* | *" #"* | *":")
      die "owner and purpose must be plain text: no leading YAML syntax character (one of \" ' [ ] { } & * ! | > % @ \` # ? : , -) and no ': ' or ' #' inside" ;;
    *) ;;
  esac
done

tmpapp=""
scratch=""
pre=""
claimed=""
cleanup() {
  local rc=$?
  [ -z "$claimed" ] || rmdir -- "$claimed" 2> /dev/null
  [ -z "$tmpapp" ] || rm -rf -- "$tmpapp"
  [ -z "$scratch" ] || rm -rf -- "$scratch"
  [ -z "$pre" ] || rm -rf -- "$pre"
  return "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# ---- 1. the name ----
[[ "$name" =~ ^[A-Za-z0-9_-]+$ ]] || die "name '$name' must match ^[a-z][a-z0-9-]{1,30}\$ (lowercase letters, digits, hyphens)"
if [[ "$name" =~ tmpl-?go-?react ]]; then
  die "name '$name' must not contain the template placeholder '$placeholder'"
fi

# stub_yaml <dir> <template>: a minimal app.yaml for the registry validator, so the name, owner and purpose rules
# are the validator's own and not copies of its regexes.
stub_yaml() {
  mkdir -p -- "$1"
  {
    printf 'schema_version: 1\nname: %s\nowner: %s\npurpose: %s\ntemplate: %s\nmemory_cap: 64m\nport: 8080\n' \
      "$name" "$owner" "$purpose" "$2"
  } > "$1/app.yaml"
}

pre="$(mktemp -d)" || die "cannot create a temp directory"
stub_yaml "$pre/$name" "go-react"
"$here/../registry/validate-app-yaml.sh" "$pre/$name/app.yaml" > "$pre/out.txt" 2>&1 || {
  while IFS= read -r line; do
    line="${line//"$pre/$name/app.yaml: "/}"
    printf 'app-new: refused: %s\n' "$line" >&2
  done < "$pre/out.txt"
  exit 1
}

[ ! -e "$apps/$name" ] && [ ! -L "$apps/$name" ] || die "refused: apps/$name/ already exists"
pg_name="${name//-/_}"
if [ -d "$apps" ]; then
  for yaml in "$apps"/*/app.yaml; do
    [ -f "$yaml" ] || continue
    existing="$(awk '/^name:/ { sub(/^name:[ \t]*/, ""); sub(/[ \t]+$/, ""); gsub(/^["\047]|["\047]$/, ""); print; exit }' "$yaml")"
    [ -n "$existing" ] || continue
    if [ "$existing" = "$name" ] || [ "${existing//-/_}" = "$pg_name" ]; then
      die "refused: the name '$name' (Postgres identifier '$pg_name') is already declared by ${yaml#"$repo"/}"
    fi
  done
fi

# ---- 2. the template ----
available=""
for d in "$templates"/*/; do
  [ -f "${d}app.yaml" ] && available="$available${available:+, }$(basename "$d")"
done
[[ "$template" =~ ^[a-z][a-z0-9-]*$ ]] && [ -f "$templates/$template/app.yaml" ] \
  || die "refused: template '$template' is not available yet (available: ${available:-none})"

# ---- 3. copy and substitute ----
mkdir -p -- "$apps" || die "cannot create $apps"
tmpapp="$(mktemp -d "$apps/.app-new.XXXXXX")" || die "cannot create a temp directory under apps/"

# copy_tree <src> <dest>: the template without build output or installed packages.
copy_tree() {
  tar -C "$1" --exclude=node_modules --exclude=./web/dist --exclude=.git -cf - . | tar -C "$2" -xf -
}
copy_tree "$templates/$template" "$tmpapp" || die "copying templates/$template failed"
if links="$(find "$tmpapp" -type l)" && [ -n "$links" ]; then
  die "refused: templates/$template contains symlinks: ${links//"$tmpapp"\//}"
fi
if names="$(find "$tmpapp" -name '*
*')" && [ -n "$names" ]; then
  die "refused: templates/$template contains a path with a newline"
fi

ident="app_${name//-/_}"
# Go files: the module path keeps the hyphenated name, every other use of the placeholder is a Go identifier.
while IFS= read -r -d '' f; do
  sed -i -e "s#apps/apps/$placeholder#apps/apps/$name#g" -e "s#$placeholder#$ident#g" "$f" || die "rewriting $f failed"
done < <(grep -rIlZ --include='*.go' -- "$placeholder" "$tmpapp")
while IFS= read -r -d '' f; do
  case "$f" in *.go) continue ;; *) ;; esac
  sed -i -e "s#$placeholder#$name#g" "$f" || die "rewriting $f failed"
done < <(grep -rIlZ -- "$placeholder" "$tmpapp")
# File and directory names (none today; kept so a future template cannot leave one behind). Deepest first.
while IFS= read -r p; do
  [ -n "$p" ] || continue
  mv -- "$p" "$(dirname "$p")/$(basename "$p" | sed "s#$placeholder#$name#g")" || die "renaming $p failed"
done < <(find "$tmpapp" -depth -name "*$placeholder*")

# owner and purpose; the values travel through the environment so no character in them is shell or sed syntax.
OWNER_V="$owner" PURPOSE_V="$purpose" awk '
  /^owner:/ { print "owner: " ENVIRON["OWNER_V"]; o++; next }
  /^purpose:/ { print "purpose: " ENVIRON["PURPOSE_V"]; p++; next }
  { print }
  END { exit (o == 1 && p == 1) ? 0 : 1 }' "$tmpapp/app.yaml" > "$tmpapp/app.yaml.new" \
  || die "the template's app.yaml must carry exactly one owner: and one purpose: line"
mv -- "$tmpapp/app.yaml.new" "$tmpapp/app.yaml" || die "writing app.yaml failed"

# No placeholder may survive in any file (binary files included) or path, in any case or spacing variant.
left_re='tmpl.?go.?react'
grep_rc=0
left="$(grep -rilE -- "$left_re" "$tmpapp")" || grep_rc=$?
[ "$grep_rc" -le 1 ] || die "scanning for leftover placeholders failed"
if [ -n "$left" ]; then
  die "refused: the placeholder '$placeholder' is still present in: ${left//"$tmpapp"\//}"
fi
if left="$(find "$tmpapp" -iname "*tmpl*go*react*")" && [ -n "$left" ]; then
  die "refused: a path still carries the placeholder '$placeholder': ${left//"$tmpapp"\//}"
fi

# ---- 4. the same checks `make lint` runs, on a scratch git work tree ----
scratch="$(mktemp -d)" || die "cannot create a scratch directory"
mkdir -p "$scratch/apps/$name" "$scratch/templates/$template" || die "cannot create the scratch tree"
copy_tree "$tmpapp" "$scratch/apps/$name" || die "copying into the scratch tree failed"
copy_tree "$templates/$template" "$scratch/templates/$template" || die "copying the template into the scratch tree failed"
git -C "$scratch" init -q || die "git init in the scratch tree failed"
git -C "$scratch" add -A || die "git add in the scratch tree failed"

problems=0
run_check() { # <label> <cmd...>
  local label="$1" out
  shift
  if out="$("$@" 2>&1)"; then return 0; fi
  problems=$((problems + 1))
  while IFS= read -r line; do
    printf 'app-new: refused (%s): %s\n' "$label" "${line//"$scratch"\//}" >&2
  done <<< "$out"
}
run_check "app.yaml" "$here/../registry/validate-app-yaml.sh" "$scratch/apps/$name/app.yaml"
run_check "per-app contract" "$here/../lint/check-apps.sh" --root "$scratch"
run_check "helper copies" "$here/../lint/check-template-copies.sh" --root "$scratch"
[ "$problems" -eq 0 ] || die "nothing was created (apps/ is unchanged)"

# ---- 5. rename into place ----
chmod 755 "$tmpapp" || die "chmod of the new app directory failed"
# Claim the name first (mkdir fails when it exists, even if it appeared after the earlier check), then rename onto the
# empty claimed directory: rename(2) onto an empty directory is atomic and never nests the temp dir inside.
mkdir -- "$apps/$name" || die "refused: apps/$name/ appeared meanwhile (another app-new run?)"
claimed="$apps/$name"
mv -T -- "$tmpapp" "$apps/$name" || die "renaming into apps/$name failed"
tmpapp=""
claimed=""

cat << EOF
app-new: created apps/$name/ from templates/$template (owner $owner).
Next steps:
  1. make test-app APP=$name                 run the new app's own tests
  2. git add apps/$name && make lint         the lints read tracked files only
  3. open a PR; CI creates the database and Redis ACL on the first deploy (app-new never calls platform new-db)
  4. once per host: create /etc/platform/access.env with the Access team domain and audience tag (see
     templates/$template/README.md); an app without them refuses to start
EOF
