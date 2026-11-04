#!/usr/bin/env bash
# Parser and matcher for platform/test/areas.map. Source it (select.sh and test_areas_map.sh do); do not run it.
#
# Map format: one row per line, `<globs>\t<targets>`; blank lines and lines starting with # are skipped. <globs> is one
# or more space-separated globs; first matching row wins. Glob semantics are the push gate's: anchored; `**/` is zero or
# more directories; a trailing `/**` is everything beneath; `*` and `?` stop at `/`.

# SC2034: the AM_* variables are the library's output, read by the scripts that source it.
# shellcheck disable=SC2034
AM_GLOBS=()
AM_TARGETS=()
AM_ERR=""
AM_ROW=-1
AM_RESULT=""

# am_glob_re <glob>: prints the anchored extended regex for the glob.
am_glob_re() {
  local g="$1" re="" i=0 c n=${#1}
  while [ "$i" -lt "$n" ]; do
    c="${g:i:1}"
    if [ "$c" = "*" ]; then
      if [ "${g:i:2}" = "**" ]; then
        if [ "${g:i+2:1}" = "/" ]; then
          re+='(.*/)?'
          i=$((i + 3))
        else
          re+='.*'
          i=$((i + 2))
        fi
        continue
      fi
      re+='[^/]*'
    elif [ "$c" = "?" ]; then
      re+='[^/]'
    else
      case "$c" in
        [a-zA-Z0-9_/-]) re+="$c" ;;
        *) re+="\\$c" ;;
      esac
    fi
    i=$((i + 1))
  done
  printf '^%s$' "$re"
}

# am_load <map-file>: fills AM_GLOBS and AM_TARGETS; returns 1 and sets AM_ERR when unreadable or malformed.
am_load() {
  local file="$1" line g t extra n=0
  AM_GLOBS=()
  AM_TARGETS=()
  AM_ERR=""
  if [ ! -r "$file" ]; then
    AM_ERR="cannot read $file"
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in '' | '#'*) continue ;; esac
    extra=""
    IFS=$'\t' read -r g t extra <<<"$line"
    if [ -z "$g" ] || [ -z "$t" ] || [ -n "$extra" ]; then
      AM_ERR="$file line $n is not '<globs><TAB><targets>'"
      return 1
    fi
    case "$t" in *' '* | ,* | *, | *,,*)
      AM_ERR="$file line $n has malformed targets '$t'"
      return 1
      ;;
    esac
    AM_GLOBS+=("$g")
    AM_TARGETS+=("$t")
  done <"$file"
  if [ "${#AM_GLOBS[@]}" -eq 0 ]; then
    AM_ERR="$file has no rows"
    return 1
  fi
  return 0
}

# am_lookup <path>: sets AM_ROW (index) and AM_RESULT (targets) of the first matching row; returns 1 when none match.
am_lookup() {
  local path="$1" i g re
  local -a gl
  AM_ROW=-1
  AM_RESULT=""
  for i in "${!AM_GLOBS[@]}"; do
    read -ra gl <<<"${AM_GLOBS[$i]}"
    for g in "${gl[@]}"; do
      re="$(am_glob_re "$g")"
      if [[ "$path" =~ $re ]]; then
        AM_ROW="$i"
        AM_RESULT="${AM_TARGETS[$i]}"
        return 0
      fi
    done
  done
  return 1
}
