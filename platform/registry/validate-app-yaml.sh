#!/usr/bin/env bash
# validate-app-yaml.sh: fail-closed validator for the per-app registry file apps/<name>/app.yaml.
#
#   platform/registry/validate-app-yaml.sh <file>...
#
# Exit 0: every file is valid. Exit 1: at least one problem; one "file: reason" line per problem on stdout.
# Exit 2: usage (no file given). The schema is documented in platform/registry/README.md; anything it does not
# list is an error (unknown key, wrong type, bad value, reserved name), never a guess.
#
# The file is read with platform/lib/yaml-subset.sh, so it must stay in that small YAML subset. Cron schedules
# must be quoted (a leading "*" is otherwise a YAML alias, which the subset refuses).
# shellcheck disable=SC1091
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/yaml-subset.sh
. "$here/../lib/yaml-subset.sh"

APP_RE='^[a-z][a-z0-9-]{1,30}$'
HANDLE_RE='^[a-z][a-z0-9-]{1,30}$'
JOB_RE='^[a-z][a-z0-9_-]{0,62}$'
TEMPLATES=" go-react go-htmx fastapi-react flask node-hono "
TOP_KEYS=" schema_version name owner purpose template memory_cap port health_path access jobs "
TOP_REQUIRED="schema_version name owner purpose template memory_cap port"
JOB_KEYS=" name schedule timeout catch_up "
RESERVED_FILE="$here/reserved-names.txt"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <app.yaml>..." >&2
  exit 2
fi

problems=0
file=""
flat=""
stderr_file=""
reserved=""
trap 'rm -f "$flat" "$stderr_file"' EXIT

err() {
  printf '%s: %s\n' "$file" "$1"
  problems=$((problems + 1))
}

# reserved_names: the names in reserved-names.txt (comments and blank lines dropped).
reserved_names() {
  awk '{ sub(/^[ \t]+/, ""); sub(/[ \t]+$/, ""); if ($0 != "" && $0 !~ /^#/) print }' "$RESERVED_FILE"
}

# top_keys: the distinct top-level keys of the flattened file.
top_keys() { awk -F '\t' '{ p = $1; sub(/[\/\[].*/, "", p); if (p != "" && !(p in s)) { s[p] = 1; print p } }' "$flat"; }

# has_below <path>: some flattened path sits under <path> (a child key, a list item).
has_below() { awk -F '\t' -v a="$1/" -v b="$1[" 'index($1, a) == 1 || index($1, b) == 1 { f = 1 } END { exit f ? 0 : 1 }' "$flat"; }

# job_indexes: the distinct N of jobs[N] paths.
job_indexes() { awk -F '\t' '$1 ~ /^jobs\[[0-9]+\]/ { p = $1; sub(/^jobs\[/, "", p); sub(/\].*/, "", p); if (!(p in s)) { s[p] = 1; print p } }' "$flat"; }

# job_keys <n>: the rest of every path under jobs[n]/ (a key, or key/deeper for a nested value).
job_keys() { awk -F '\t' -v p="jobs[$1]/" 'index($1, p) == 1 { print substr($1, length(p) + 1) }' "$flat"; }

# raw_checks: type checks the flattened form cannot make because quoting is gone after flattening.
raw_checks() {
  local line
  while IFS= read -r line; do
    [ -n "$line" ] && err "$line"
  done < <(awk '
    {
      s = $0
      sub(/^[ ]*(-[ ]+)?/, "", s)
      if (match(s, /^(port|schema_version|catch_up):[ ]*["\047]/)) {
        k = s; sub(/:.*/, "", k)
        printf("%s must be an unquoted value, not a string (line %d)\n", k, NR)
      }
      if (match(s, /^schedule:[ ]*[^ "\047]/)) {
        printf("schedule must be a quoted cron string (line %d)\n", NR)
      }
    }' "$file")
}

# cron_field_ok <field>: a comma list of items; item = "*", a number or a range, with an optional /step.
CRON_ITEM='(\*|[0-9]+(-[0-9]+)?)(/[0-9]+)?'
CRON_RE="^${CRON_ITEM}(,${CRON_ITEM})*\$"
cron_field_ok() { [[ "$1" =~ $CRON_RE ]]; }

check_schedule() {
  local where="$1" sched="$2" f
  local -a fields
  read -r -a fields <<< "$sched"
  for f in "${fields[@]}"; do
    cron_field_ok "$f" || { err "$where schedule field '$f' is not a cron field"; return; }
  done
  [ "${#fields[@]}" -eq 5 ] || err "$where schedule must have exactly 5 fields"
}

check_timeout() {
  local where="$1" v="$2" n unit
  if ! [[ "$v" =~ ^[0-9]{1,6}(s|m|h)$ ]]; then
    err "$where timeout '$v' must look like 30s, 2m or 1h"
    return
  fi
  unit="${v: -1}"
  n=$((10#${v%?}))
  [ "$n" -ge 1 ] || { err "$where timeout must be greater than zero"; return; }
  case "$unit" in
    s) [ "$n" -le 3600 ] || err "$where timeout '$v' is over the 1h maximum" ;;
    m) [ "$n" -le 60 ] || err "$where timeout '$v' is over the 1h maximum" ;;
    h) [ "$n" -le 1 ] || err "$where timeout '$v' is over the 1h maximum" ;;
    *) err "$where timeout '$v' has an unknown unit" ;;
  esac
}

check_name() {
  local name="$1" dir pg
  if ! [[ "$name" =~ $APP_RE ]]; then
    err "name '$name' must match $APP_RE"
    return
  fi
  dir="$(basename "$(cd "$(dirname "$file")" && pwd -L)")"
  [ "$name" = "$dir" ] || err "name '$name' must equal the parent directory name '$dir'"
  if grep -qxF -- "$name" <<< "$reserved"; then
    err "name '$name' is reserved"
  fi
  pg="${name//-/_}"
  case "$pg" in
    pg_* | postgres | template0 | template1 | public)
      err "name '$name' maps to the refused Postgres identifier '$pg'"
      ;;
    *) ;;
  esac
}

check_job() {
  local i="$1" k rest v where
  local seen_keys=" "
  where="jobs[$i]"
  while IFS= read -r rest; do
    k="${rest%%/*}"
    if [ "$k" != "$rest" ]; then
      err "$where/$k must be a scalar"
      continue
    fi
    case "$JOB_KEYS" in
      *" $k "*) ;;
      *) err "$where has unknown key '$k'"; continue ;;
    esac
    seen_keys="$seen_keys$k "
  done < <(job_keys "$i")
  case "$seen_keys" in *" name "*) ;; *) err "$where is missing required key 'name'" ;; esac
  case "$seen_keys" in *" timeout "*) ;; *) err "$where is missing required key 'timeout'" ;; esac
  case "$seen_keys" in
    *" name "*)
      v="$(ys_get "$flat" "jobs[$i]/name")"
      [[ "$v" =~ $JOB_RE ]] || err "$where name '$v' must match $JOB_RE"
      ;;
    *) ;;
  esac
  case "$seen_keys" in
    *" timeout "*) check_timeout "$where" "$(ys_get "$flat" "jobs[$i]/timeout")" ;;
    *) ;;
  esac
  case "$seen_keys" in
    *" schedule "*)
      v="$(ys_get "$flat" "jobs[$i]/schedule")"
      if [ -n "$v" ]; then check_schedule "$where" "$v"; else err "$where schedule must not be empty"; fi
      ;;
    *) ;;
  esac
  case "$seen_keys" in
    *" catch_up "*)
      v="$(ys_get "$flat" "jobs[$i]/catch_up")"
      case "$v" in true | false) ;; *) err "$where catch_up '$v' must be true or false" ;; esac
      ;;
    *) ;;
  esac
}

check_jobs() {
  local i names="" n
  if [ -n "$(ys_get "$flat" jobs)" ]; then
    err "jobs must be a list of maps, not a scalar"
    return
  fi
  if ys_has "$flat" "jobs[]"; then
    err "jobs items must be maps (name, schedule, timeout, catch_up), not plain values"
  fi
  if [ -z "$(job_indexes)" ]; then
    err "jobs is present but has no entries (omit the key instead)"
    return
  fi
  for i in $(job_indexes); do
    check_job "$i"
    names="$names$(ys_get "$flat" "jobs[$i]/name")"$'\n'
  done
  n="$(printf '%s' "$names" | grep -v '^$' | sort | uniq -d)"
  [ -z "$n" ] || err "duplicate job name '$(echo "$n" | head -n 1)'"
}

check_scalar_keys() {
  local k v
  for k in $TOP_KEYS; do
    [ "$k" = jobs ] && continue
    ys_has "$flat" "$k" || continue
    if has_below "$k"; then
      err "$k must be a scalar value"
      continue
    fi
    v="$(ys_get "$flat" "$k")"
    [ -n "$v" ] || { err "$k must not be empty"; continue; }
    case "$k" in
      schema_version) [ "$v" = 1 ] || err "schema_version '$v' must be 1" ;;
      name) check_name "$v" ;;
      owner)
        if [[ "$v" == *@* ]]; then
          err "owner must be a short handle, not an email address"
        elif ! [[ "$v" =~ $HANDLE_RE ]]; then
          err "owner '$v' must match $HANDLE_RE"
        fi
        ;;
      purpose)
        if [[ "$v" =~ ^[[:space:]]*$ ]]; then
          err "purpose must not be only whitespace"
        elif [ "${#v}" -gt 120 ]; then
          err "purpose is ${#v} characters, the maximum is 120"
        fi
        ;;
      template)
        case "$TEMPLATES" in *" $v "*) ;; *) err "template '$v' is not one of:$TEMPLATES" ;; esac
        ;;
      memory_cap)
        if ! [[ "$v" =~ ^[1-9][0-9]{0,2}m$ ]]; then
          err "memory_cap '$v' must be a number of MiB with the unit m, like 64m"
        elif [ "${v%m}" -lt 16 ] || [ "${v%m}" -gt 512 ]; then
          err "memory_cap '$v' must be between 16m and 512m"
        fi
        ;;
      port)
        if ! [[ "$v" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$v" -gt 65535 ]; then
          err "port '$v' must be an integer from 1 to 65535"
        fi
        ;;
      health_path)
        if [[ "$v" != /* ]]; then
          err "health_path '$v' must start with /"
        elif ! [[ "$v" =~ ^/[A-Za-z0-9._~/%-]*$ ]]; then
          err "health_path '$v' may only contain letters, digits and . _ ~ / % -"
        fi
        ;;
      access)
        case "$v" in family | public | restricted) ;; *) err "access '$v' must be family, public or restricted" ;; esac
        ;;
      *) err "internal: no rule for key $k" ;;
    esac
  done
}

validate_one() {
  local k rc=0
  file="$1"
  if [ -L "$file" ]; then
    err "must be a regular file, not a symlink"
    return
  fi
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    err "not a readable file"
    return
  fi
  if [ ! -r "$RESERVED_FILE" ]; then
    err "reserved-names.txt is missing, cannot validate (fails closed)"
    return
  fi
  reserved="$(reserved_names)"
  if [ -z "$reserved" ]; then
    err "reserved-names.txt has no entries, cannot validate (fails closed)"
    return
  fi
  raw_checks
  flat="$(mktemp)"
  stderr_file="$(mktemp)"
  ys_flatten < "$file" > "$flat" 2> "$stderr_file" || rc=$?
  if [ "$rc" -ne 0 ]; then
    err "not valid app.yaml syntax: $(head -n 1 "$stderr_file")"
    rm -f "$flat" "$stderr_file"
    return
  fi
  rm -f "$stderr_file"
  for k in $(top_keys); do
    case "$TOP_KEYS" in *" $k "*) ;; *) err "unknown key '$k'" ;; esac
  done
  for k in $TOP_REQUIRED; do
    ys_has "$flat" "$k" || err "missing required key '$k'"
  done
  check_scalar_keys
  if ys_has "$flat" jobs; then check_jobs; fi
  rm -f "$flat"
}

for f in "$@"; do
  validate_one "$f"
done

[ "$problems" -eq 0 ]
