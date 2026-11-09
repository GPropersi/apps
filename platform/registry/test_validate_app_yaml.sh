#!/usr/bin/env bash
# Offline tests for the app.yaml validator: the unmutated example passes (copied to <scratch>/<name>/app.yaml),
# and one mutated copy per schema rule fails with a named reason. Also covers the `make lint` wiring
# (validate-tracked.sh over tracked apps/*/app.yaml) in a scratch git repo.
# shellcheck disable=SC1091,SC2016,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"

t_init
validator="$here/validate-app-yaml.sh"
example="$here/app.yaml.example"
root="$(cd "$here/../.." && pwd)"
cases="$T_TMP/cases"
mkdir -p "$cases"
at='@'

# put <dir>: a fresh copy of the example at $cases/<dir>/app.yaml (name line left as is). Echoes the path.
put() {
  mkdir -p "$cases/$1"
  cp "$example" "$cases/$1/app.yaml"
  echo "$cases/$1/app.yaml"
}

# mutate <label> <reason> <sed-expr> [dir]: apply the sed expression to the example, expect rc 1 and the reason.
mutate() {
  local label="$1" reason="$2" expr="$3" dir="${4:-chores}" f
  rm -rf "${cases:?}/$dir"
  mkdir -p "$cases/$dir"
  f="$cases/$dir/app.yaml"
  sed -e "$expr" "$example" > "$f"
  run_cmd "$validator" "$f"
  expect_rc "$label: rc" 1
  expect_out_has "$label: reason" "$reason"
  expect_out_has "$label: names the file" "$f: "
}

# ---- the valid example, and usage ----

f="$(put chores)"
run_cmd "$validator" "$f"
expect_rc "example validates" 0
expect_eq "example prints nothing" "$out" ""

run_cmd "$validator"
expect_rc "no arguments is a usage error" 2

run_cmd "$validator" "$cases/absent/app.yaml"
expect_rc "missing file" 1
expect_out_has "missing file: reason" "not a readable file"

# Several files: one bad file fails the run and the good one is not blamed.
f="$(put chores)"
mutate "second bad file" "unknown key" '$a colour: red' other
bad="$cases/other/app.yaml"
run_cmd "$validator" "$f" "$bad"
expect_rc "two files, one bad" 1
expect_out_lacks "good file not blamed" "$f: "

# ---- mutations, one per rule ----

mutate "unknown top-level key" "unknown key 'colour'" '$a colour: red'
mutate "typo of a key" "unknown key 'purposes'" 's/^purpose:/purposes:/'
mutate "missing owner" "missing required key 'owner'" '/^owner:/d'
mutate "missing port" "missing required key 'port'" '/^port:/d'
mutate "missing schema_version" "missing required key 'schema_version'" '/^schema_version:/d'
mutate "name differs from directory" "must equal the parent directory name" 's/^name: chores/name: elsewhere/'
mutate "reserved name" "is reserved" 's/^name: chores/name: redis/' redis
mutate "reserved livetest name" "is reserved" 's/^name: chores/name: ingress-livetest/' ingress-livetest
mutate "pg_ prefix mapping" "refused Postgres identifier" 's/^name: chores/name: pg-x/' pg-x
mutate "template0 mapping" "refused Postgres identifier" 's/^name: chores/name: template0/' template0
mutate "public mapping" "refused Postgres identifier" 's/^name: chores/name: public/' public
mutate "bad name shape" "must match" 's/^name: chores/name: Chores/' Chores
mutate "template outside the enum" "template 'rust' is not one of" 's/^template: go-react/template: rust/'
mutate "memory_cap too large" "must be between 16m and 512m" 's/^memory_cap: 64m/memory_cap: 600m/'
mutate "memory_cap too small" "must be between 16m and 512m" 's/^memory_cap: 64m/memory_cap: 8m/'
mutate "memory_cap wrong unit" "memory_cap '64g'" 's/^memory_cap: 64m/memory_cap: 64g/'
mutate "memory_cap no unit" "memory_cap '64'" 's/^memory_cap: 64m/memory_cap: 64/'
mutate "port zero" "port '0'" 's/^port: 8080/port: 0/'
mutate "port too large" "port '70000'" 's/^port: 8080/port: 70000/'
mutate "port not a number" "port 'http'" 's/^port: 8080/port: http/'
mutate "port as a string" "port must be an unquoted value" 's/^port: 8080/port: "8080"/'
mutate "unknown access" "access 'everyone'" 's/^access: family/access: everyone/'
mutate "owner as an email" "owner must be a short handle, not an email" "s/^owner: family/owner: bob${at}home/"
mutate "owner bad shape" "owner 'Bob'" 's/^owner: family/owner: Bob/'
mutate "duplicate job name" "duplicate job name 'daily-digest'" 's/name: send-reminder/name: daily-digest/'
mutate "bad job name" "name 'Bad_Name' must match" 's/name: send-reminder/name: Bad_Name/'
mutate "bad timeout unit" "timeout '2x'" 's/timeout: 2m/timeout: 2x/'
mutate "timeout over 1h in minutes" "timeout '61m' is over the 1h maximum" 's/timeout: 2m/timeout: 61m/'
mutate "timeout over 1h in seconds" "timeout '3601s' is over the 1h maximum" 's/timeout: 2m/timeout: 3601s/'
mutate "timeout over 1h in hours" "timeout '2h' is over the 1h maximum" 's/timeout: 2m/timeout: 2h/'
mutate "timeout zero" "timeout must be greater than zero" 's/timeout: 2m/timeout: 0m/'
mutate "job missing timeout" "is missing required key 'timeout'" '/timeout: 30s/d'
mutate "job unknown key" "has unknown key 'retries'" 's/^    timeout: 30s/    timeout: 30s\n    retries: 3/'
mutate "unquoted cron with a leading star" "schedule must be a quoted cron string" 's/schedule: "0 7 \* \* \*"/schedule: * * * * */'
mutate "unquoted cron" "schedule must be a quoted cron string" 's/schedule: "0 7 \* \* \*"/schedule: 0 7 * * */'
mutate "cron with four fields" "schedule must have exactly 5 fields" 's/schedule: "0 7 \* \* \*"/schedule: "0 7 * *"/'
mutate "cron with a bad field" "is not a cron field" 's/schedule: "0 7 \* \* \*"/schedule: "0 seven * * *"/'
mutate "schema_version 2" "schema_version '2' must be 1" 's/^schema_version: 1/schema_version: 2/'
mutate "schema_version as a string" "schema_version must be an unquoted value" 's/^schema_version: 1/schema_version: "1"/'
mutate "duplicate top-level key" "duplicate path port" '$a port: 9090'
mutate "purpose empty" "purpose must not be empty" 's/^purpose: .*/purpose: ""/'
long="$(printf '%0121d' 0 | tr 0 x)"
mutate "purpose over 120 chars" "purpose is 121 characters" "s/^purpose: .*/purpose: $long/"
mutate "health_path without a slash" "health_path 'healthz' must start with /" 's#^health_path: /healthz#health_path: healthz#'
mutate "catch_up not a boolean" "catch_up 'yes' must be true or false" 's/catch_up: true/catch_up: yes/'
mutate "catch_up as a string" "catch_up must be an unquoted value" 's/catch_up: true/catch_up: "true"/'
mutate "jobs as a scalar" "indented under a scalar value" 's/^jobs:$/jobs: nope/'
mutate "jobs with plain items" "key after a list item" 's/^  - name: daily-digest/  - daily-digest/'
mutate "jobs empty" "jobs is present but has no entries" '/^  - name:/,$d'
mutate "email list in access" "access 'family, bob" "s/^access: family/access: family, bob${at}home/"

# ---- volumes: the example plus an appended volumes block ----

# volcase <label> <reason|-> <block>: expect rc 1 and the reason (rc 0 and no output when the reason is "-").
volcase() {
  local label="$1" reason="$2" block="$3" f="$cases/chores/app.yaml"
  rm -rf "${cases:?}/chores"
  mkdir -p "$cases/chores"
  { cat "$example"; printf '%s\n' "$block"; } > "$f"
  run_cmd "$validator" "$f"
  if [ "$reason" = "-" ]; then
    expect_rc "$label: rc" 0
    expect_eq "$label: prints nothing" "$out" ""
  else
    expect_rc "$label: rc" 1
    expect_out_has "$label: reason" "$reason"
  fi
}
v1=$'volumes:\n  - name: files\n    path: /data/files'
volcase "one volume" - "$v1"
volcase "four volumes with dots, dashes and depth" - $'volumes:\n  - name: a\n    path: /data/a\n  - name: b-1\n    path: /data/x.y-z_1/deep\n  - name: c\n    path: /data/..hidden\n  - name: d\n    path: /data/.cfg'
volcase "path outside /data" "must be absolute under /data" $'volumes:\n  - name: a\n    path: /tmp/x'
volcase "path /dataset is not under /data" "must be absolute under /data" $'volumes:\n  - name: a\n    path: /dataset'
volcase "relative path" "must be absolute under /data" $'volumes:\n  - name: a\n    path: data/x'
volcase "dotdot segment" "must not contain a . or .. segment" $'volumes:\n  - name: a\n    path: /data/../etc'
volcase "dot segment" "must not contain a . or .. segment" $'volumes:\n  - name: a\n    path: /data/./x'
volcase "trailing dotdot" "must not contain a . or .. segment" $'volumes:\n  - name: a\n    path: /data/x/..'
volcase "uppercase in path" "must be absolute under /data" $'volumes:\n  - name: a\n    path: /data/Files'
volcase "trailing slash" "must be absolute under /data" $'volumes:\n  - name: a\n    path: /data/files/'
volcase "bad volume name" "name 'A_b' must match" $'volumes:\n  - name: A_b\n    path: /data/x'
volcase "underscore in volume name" "name 'a_b' must match" $'volumes:\n  - name: a_b\n    path: /data/x'
volcase "duplicate name" "duplicate volume name 'a'" $'volumes:\n  - name: a\n    path: /data/a\n  - name: a\n    path: /data/b'
volcase "duplicate path" "duplicate volume path '/data/a'" $'volumes:\n  - name: a\n    path: /data/a\n  - name: b\n    path: /data/a'
volcase "path inside another" "volume path '/data/a/b' is inside volume path '/data/a'" $'volumes:\n  - name: a\n    path: /data/a\n  - name: b\n    path: /data/a/b'
volcase "a sibling with a shared prefix is not nested" - $'volumes:\n  - name: a\n    path: /data/a\n  - name: b\n    path: /data/ab'
volcase "fifth volume" "volumes has 5 entries, the maximum is 4" $'volumes:\n  - name: a\n    path: /data/a\n  - name: b\n    path: /data/b\n  - name: c\n    path: /data/c\n  - name: d\n    path: /data/d\n  - name: e\n    path: /data/e'
volcase "unknown entry key" "volumes[0] has unknown key 'size'" $'volumes:\n  - name: a\n    path: /data/a\n    size: 1'
volcase "entry missing path" "volumes[0] is missing required key 'path'" $'volumes:\n  - name: a'
volcase "entry missing name" "volumes[0] is missing required key 'name'" $'volumes:\n  - path: /data/a'
volcase "volumes empty" "volumes is present but has no entries" 'volumes:'
volcase "volumes plain items" "volumes items must be maps" $'volumes:\n  - a'
volcase "nested entry value" "must be a scalar" $'volumes:\n  - name: a\n    path:\n      x: 1'
volcase "path as a quoted string with spaces" "must be absolute under /data" $'volumes:\n  - name: a\n    path: "/data/a b"'

# Optional keys really are optional.
f="$cases/minimal/app.yaml"
mkdir -p "$cases/minimal"
{
  echo "schema_version: 1"
  echo "name: minimal"
  echo "owner: family"
  echo "purpose: Smallest valid file"
  echo "template: flask"
  echo "memory_cap: 16m"
  echo "port: 1"
} > "$f"
run_cmd "$validator" "$f"
expect_rc "minimal file (no optional keys) validates" 0

f="$cases/maxed/app.yaml"
mkdir -p "$cases/maxed"
sed -e 's/^name: chores/name: maxed/' -e 's/^memory_cap: 64m/memory_cap: 512m/' -e 's/^port: 8080/port: 65535/' \
  -e 's/timeout: 2m/timeout: 1h/' -e 's/timeout: 30s/timeout: 3600s/' "$example" > "$f"
run_cmd "$validator" "$f"
expect_rc "upper bounds validate" 0

# Extra spaces after the job dash must not hide an unquoted cron.
f="$cases/dash/app.yaml"
mkdir -p "$cases/dash"
sed -e 's/^name: chores/name: dash/' -e '/^jobs:/,$d' "$example" > "$f"
printf 'jobs:\n  -   schedule: 0 7 1 1 1\n      name: a\n      timeout: 1m\n' >> "$f"
run_cmd "$validator" "$f"
expect_rc "unquoted cron after a wide dash fails" 1
expect_out_has "unquoted cron after a wide dash: reason" "schedule must be a quoted cron string"

# A symlinked app.yaml is refused, even when its target is valid and named like its own directory.
mkdir -p "$cases/xy" "$cases/evil"
sed -e 's/^name: chores/name: xy/' "$example" > "$cases/xy/app.yaml"
ln -sf ../xy/app.yaml "$cases/evil/app.yaml"
run_cmd "$validator" "$cases/xy/app.yaml"
expect_rc "the symlink target itself validates" 0
run_cmd "$validator" "$cases/evil/app.yaml"
expect_rc "symlinked app.yaml fails" 1
expect_out_has "symlinked app.yaml: reason" "must be a regular file, not a symlink"

mutate "purpose only whitespace" "purpose must not be only whitespace" 's/^purpose: .*/purpose: "   "/'
mutate "cron of bare dashes" "is not a cron field" 's/schedule: "0 7 \* \* \*"/schedule: "- - - - -"/'
mutate "cron of bare commas" "is not a cron field" 's/schedule: "0 7 \* \* \*"/schedule: ",,,,,"/'
mutate "health_path with a space" "health_path '/a b' may only contain" 's#^health_path: /healthz#health_path: "/a b"#'
mutate "health_path with a query" "may only contain" 's#^health_path: /healthz#health_path: /h?x=1#'

f="$cases/cronok/app.yaml"
mkdir -p "$cases/cronok"
sed -e 's/^name: chores/name: cronok/' -e 's#schedule: "0 7 \* \* \*"#schedule: "*/15 1-5,9 * 1,6 1-5/2"#' "$example" > "$f"
run_cmd "$validator" "$f"
expect_rc "cron with lists, ranges and steps validates" 0

# ---- the shared cron fixture (the Go parser reads the same table) ----

# cron_row <verdict> <cron> <note>: one table row against the validator, via a scratch copy of the example.
cron_row() {
  local verdict="$1" cron="$2" note="$3" d="$cases/cronrow"
  rm -rf "$d"
  mkdir -p "$d"
  sed -e 's/^name: chores/name: cronrow/' -e "s|schedule: \"0 7 \\* \\* \\*\"|schedule: \"$cron\"|" "$example" > "$d/app.yaml"
  run_cmd "$validator" "$d/app.yaml"
  if [ "$verdict" = valid ]; then
    expect_rc "cron table: valid \"$cron\" ($note)" 0
  else
    expect_rc "cron table: invalid \"$cron\" ($note)" 1
    expect_out_has "cron table: invalid \"$cron\" names a schedule problem" "schedule"
  fi
}

table="$here/cron-cases.table"
hint='expected valid|invalid<TAB>"<5 fields>"<TAB><note> (tab separators, quoted cron, # comments and blank lines allowed)'
tab=$'\t'
rows=0
problems=()

# read_cron_table <file> [run]: the table reader. Skips zero-length lines and lines starting with # (no trimming),
# collects one entry in the global `problems` per malformed row (naming "line N" and the shape hint) and, when
# there are no data rows, one more. Sets the global `rows`. With a second argument it also runs cron_row on each
# good row. Returns 1 when `problems` is not empty.
read_cron_table() {
  local file="$1" run="${2:-}" line verdict cron note extra tabs lineno=0
  rows=0
  problems=()
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in '' | '#'*) continue ;; esac
    IFS="$tab" read -r verdict cron note extra <<< "$line"
    tabs="${line//[^$tab]/}"
    if [ "${#tabs}" -ne 2 ] || [[ "$line" == *$'\r'* ]] || [ -n "${extra:-}" ] || { [ "$verdict" != valid ] && [ "$verdict" != invalid ]; } \
      || ! [[ "$cron" =~ ^\"[^\"]*\"$ ]] || [ -z "$note" ]; then
      problems+=("cron-cases.table line $lineno is malformed: $hint")
      continue
    fi
    rows=$((rows + 1))
    if [ -n "$run" ]; then
      cron="${cron#\"}"
      cron="${cron%\"}"
      cron_row "$verdict" "$cron" "$note"
    fi
  done < "$file"
  if [ "$rows" -eq 0 ]; then problems+=("cron-cases.table has no data rows"); fi
  [ "${#problems[@]}" -eq 0 ]
}

read_cron_table "$table" run
for p in "${problems[@]+"${problems[@]}"}"; do _fail "$p"; done
if [ "$rows" -ge 30 ]; then _pass; else _fail "cron-cases.table has $rows data rows, need at least 30"; fi

# Named-field reasons, and the reserved app name.
mutate "cron minute 99 names the field" "schedule minute field '99'" 's/schedule: "0 7 \* \* \*"/schedule: "99 * * * *"/'
mutate "cron step zero names the field" "schedule minute field '*/0' has a step of zero" 's/schedule: "0 7 \* \* \*"/schedule: "*\/0 * * * *"/'
mutate "cron reversed range names the field" "schedule minute field '5-1' has a reversed range" 's/schedule: "0 7 \* \* \*"/schedule: "5-1 * * * *"/'
mutate "cron hour 24 names the field" "schedule hour field '24'" 's/schedule: "0 7 \* \* \*"/schedule: "0 24 * * *"/'
mutate "cron day-of-month 0 names the field" "schedule day-of-month field '0'" 's/schedule: "0 7 \* \* \*"/schedule: "0 0 0 * *"/'
mutate "reserved name jobs" "name 'jobs' is reserved" 's/^name: chores/name: jobs/' jobs

# The real reader on bad tables (no run mode, so nothing reaches _fail): every case must be reported.
# bad_table <label> <expected "line N" or text> <content printf-format>
bad_table() {
  local label="$1" want="$2" f="$T_TMP/badtable.table"
  printf '%b' "$3" > "$f"
  rc=0
  read_cron_table "$f" || rc=$?
  out="$(printf '%s\n' "${problems[@]+"${problems[@]}"}")"
  expect_rc "bad table, $label: rejected" 1
  expect_out_has "bad table, $label: reports $want" "$want"
}
bad_table "comments only" "has no data rows" '# only a comment\n\n'
bad_table "empty file" "has no data rows" ''
bad_table "one tab" "line 2" '# c\nvalid\t"0 7 * * *"\n'
bad_table "three tabs" "line 1" 'valid\t"0 7 * * *"\tnote\textra\n'
bad_table "unquoted cron" "line 1" 'valid\t0 7 * * *\tnote\n'
bad_table "verdict maybe" "line 1" 'maybe\t"0 7 * * *"\tnote\n'
bad_table "empty note" "line 1" 'valid\t"0 7 * * *"\t\n'
bad_table "whitespace-only line" "line 2" 'valid\t"0 7 * * *"\tnote\n   \n'
bad_table "indented comment" "line 2" 'valid\t"0 7 * * *"\tnote\n # indented\n'
bad_table "CRLF line end" "line 1" 'valid\t"0 7 * * *"\tnote\r\n'
bad_table "hint shape" 'valid|invalid<TAB>"<5 fields>"<TAB><note>' 'valid\t"0 7 * * *"\n'
bad_table "hint line number" "line 3" '# c\n\nbogus\n'
# A good table is accepted and counted.
printf 'valid\t"0 7 * * *"\tnote\n# c\n\ninvalid\t"60 * * * *"\tnote\n' > "$T_TMP/goodtable.table"
rc=0
# shellcheck disable=SC2034
read_cron_table "$T_TMP/goodtable.table" || rc=$?
expect_rc "good table accepted" 0
expect_eq "good table row count" "$rows" "2"

# A reserved-names file with no entries fails closed.
mkdir -p "$T_TMP/emptyreserved" "$T_TMP/emptyreserved-lib"
emptyreserved="$T_TMP/emptyreserved/platform/registry"
mkdir -p "$emptyreserved" "$T_TMP/emptyreserved/platform/lib"
cp "$validator" "$emptyreserved/validate-app-yaml.sh"
cp "$root/platform/lib/yaml-subset.sh" "$T_TMP/emptyreserved/platform/lib/yaml-subset.sh"
printf '# only a comment\n\n' > "$emptyreserved/reserved-names.txt"
run_cmd "$emptyreserved/validate-app-yaml.sh" "$(put chores)"
expect_rc "empty reserved-names.txt fails closed" 1
expect_out_has "empty reserved-names.txt: reason" "reserved-names.txt has no entries"

# A reserved-names file that is gone fails closed.
scratch_validator="$T_TMP/noreserved/validate-app-yaml.sh"
mkdir -p "$T_TMP/noreserved" "$T_TMP/lib"
cp "$validator" "$scratch_validator"
cp "$root/platform/lib/yaml-subset.sh" "$T_TMP/lib/yaml-subset.sh"
run_cmd "$scratch_validator" "$(put chores)"
expect_rc "missing reserved-names.txt fails closed" 1
expect_out_has "missing reserved-names.txt: reason" "reserved-names.txt is missing"

# ---- fixtures stay clean ----

if grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$example" "$here/reserved-names.txt"; then
  _fail "no IPv4 literal in the example or the reserved names"
else
  _pass
fi
if grep -q "$at" "$example"; then _fail "no email in the example"; else _pass; fi

# ---- make lint wiring: validate-tracked.sh over a scratch git repo ----

if grep -A8 '^lint:' "$root/Makefile" | grep -qE '^	@?platform/registry/validate-tracked\.sh'; then
  _pass
else
  _fail "make lint runs validate-tracked.sh"
fi

repo="$T_TMP/repo"
mkdir -p "$repo/platform"
cp -r "$root/platform/registry" "$repo/platform/registry"
cp -r "$root/platform/lib" "$repo/platform/lib"
git -C "$repo" init -q
tracked="$repo/platform/registry/validate-tracked.sh"

run_cmd bash -c "cd '$repo' && '$tracked'"
expect_rc "zero apps passes vacuously" 0

mkdir -p "$repo/apps/chores"
cp "$example" "$repo/apps/chores/app.yaml"
git -C "$repo" add apps/chores/app.yaml
run_cmd bash -c "cd '$repo' && '$tracked'"
expect_rc "one valid tracked app passes" 0

mkdir -p "$repo/apps/x"
printf 'schema_version: 1\nname: x\ncolour: red\n' > "$repo/apps/x/app.yaml"
run_cmd bash -c "cd '$repo' && '$tracked'"
expect_rc "an untracked invalid app.yaml is not scanned" 0
git -C "$repo" add apps/x/app.yaml
run_cmd bash -c "cd '$repo' && '$tracked'"
expect_rc "a tracked invalid app.yaml fails" 1
expect_out_has "tracked invalid: reason" "unknown key 'colour'"
expect_out_has "tracked invalid: names the file" "apps/x/app.yaml: "

t_finish
