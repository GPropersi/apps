#!/usr/bin/env bash
# Guards platform/test/areas.map against drift: a test that reads another area must be listed in that area's row, every
# platform/<dir> with files needs its own row, and every row target must be a real area or a keyword.
# The checks run as a function over a map file, so mutated copies prove each one fires.
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=areamap-lib.sh
. "$here/areamap-lib.sh"
root="$(cd "$here/../.." && pwd)"
real_map="$here/areas.map"

t_init

# listed <targets> <area>: true when the comma list names the area or all.
listed() {
  case ",$1," in *",$2,"* | *",all,"*) return 0 ;; *) return 1 ;; esac
}

# check_map <map-file>: prints one violation per line, nothing when the map is sound.
check_map() {
  local map="$1" f area dep ref t i
  if ! am_load "$map"; then
    echo "map unusable: $AM_ERR"
    return 0
  fi

  # 1. A test reading ../<dep>/ (including ../lib/) needs dep's row to list the test's own area.
  while IFS= read -r f; do
    area="${f#"$root"/platform/}"
    area="${area%%/*}"
    # Tests in platform/test/ are checked like any other area: a read of another area's files needs that row to list test
    # (a fixture mention is rewritten, not skipped). A ../test/ mention is the area itself and is ignored below.
    while IFS= read -r ref; do
      dep="${ref#../}"
      dep="${dep%/}"
      [ "$dep" != "$area" ] && [ "$dep" != "test" ] && [ -d "$root/platform/$dep" ] || continue
      if ! am_lookup "platform/$dep/x" || ! listed "$AM_RESULT" "$area"; then
        echo "${f#"$root"/} reads ../$dep/ but the row for platform/$dep/** does not list $area"
      fi
    done < <(grep -oE '\.\./[a-z][a-z0-9_-]*/' "$f" | sort -u)
  done < <(find "$root/platform" -mindepth 2 -name 'test_*.sh' | LC_ALL=C sort)

  # 1a. A template test reading platform/<dep>/ needs dep's row to list templates.
  while IFS= read -r f; do
    while IFS= read -r ref; do
      dep="${ref#platform/}"
      dep="${dep%/}"
      [ -d "$root/platform/$dep" ] || continue
      if ! am_lookup "platform/$dep/x" || ! listed "$AM_RESULT" templates; then
        echo "${f#"$root"/} reads platform/$dep/ but the row for platform/$dep/** does not list templates"
      fi
    done < <(grep -oE 'platform/[a-z][a-z0-9_-]*/' "$f" | sort -u)
  done < <(find "$root/templates" -mindepth 2 -maxdepth 2 -name 'test_*.sh' 2> /dev/null | LC_ALL=C sort)

  # 1b. Every row that lists scaffold also lists templates (the template tests read the same inputs as the scaffold tests).
  for i in "${!AM_TARGETS[@]}"; do
    if listed "${AM_TARGETS[$i]}" scaffold && ! listed "${AM_TARGETS[$i]}" templates; then
      echo "row '${AM_GLOBS[$i]}' lists scaffold but not templates"
    fi
  done

  # 2. A platform/<dir> with any file needs a row of its own (not just the catch-all).
  for d in "$root"/platform/*/; do
    d="$(basename "$d")"
    [ -n "$(find "$root/platform/$d" -type f -print -quit)" ] || continue
    if ! am_lookup "platform/$d/x" || [ "${AM_GLOBS[$AM_ROW]}" = "**" ]; then
      echo "platform/$d has files but no areas.map row of its own"
    fi
  done

  # 3. Every target names a platform/<area> directory or a keyword.
  for i in "${!AM_TARGETS[@]}"; do
    IFS=, read -ra ts <<<"${AM_TARGETS[$i]}"
    for t in "${ts[@]}"; do
      case "$t" in
        apps | templates | none | all) ;;
        *) [ -d "$root/platform/$t" ] || echo "row '${AM_GLOBS[$i]}' names '$t', which is not a platform/ directory" ;;
      esac
    done
  done
}

violations="$(check_map "$real_map")"
expect_eq "the real areas.map has no violations" "$violations" ""

mutant="$T_TMP/areas.mutant"

# Removing an area from a dependency's row is caught (jobs reads ../data/).
sed -E 's#^(platform/data/\*\*\t)data,host,backup,jobs,#\1data,host,backup,#' "$real_map" > "$mutant"
cmp -s "$real_map" "$mutant" && _fail "mutation 1 changed nothing" "sed did not match"
violations="$(check_map "$mutant")"
case "$violations" in
  *"reads ../data/ but the row for platform/data/** does not list jobs"*) _pass ;;
  *) _fail "dropping jobs from the data row is caught" "got: $violations" ;;
esac

# Dropping lib's ingress entry is caught (ingress tests source ../lib/).
sed -E 's#,ingress,deploy,apps(,test)?$#,deploy,apps\1#' "$real_map" > "$mutant"
cmp -s "$real_map" "$mutant" && _fail "mutation 2 changed nothing" "sed did not match"
violations="$(check_map "$mutant")"
case "$violations" in
  *"reads ../lib/ but the row for platform/lib/** does not list ingress"*) _pass ;;
  *) _fail "dropping ingress from the lib row is caught" "got: $violations" ;;
esac

# Dropping deploy from the registry row is caught (the deploy tests run the registry validator from ../registry/).
sed -E 's#^(platform/registry/\*\*\t.*),deploy,apps(,test)?$#\1,apps\2#' "$real_map" > "$mutant"
cmp -s "$real_map" "$mutant" && _fail "mutation 3 changed nothing" "sed did not match"
violations="$(check_map "$mutant")"
case "$violations" in
  *"reads ../registry/ but the row for platform/registry/** does not list deploy"*) _pass ;;
  *) _fail "dropping deploy from the registry row is caught" "got: $violations" ;;
esac

# Dropping test from the data row is caught (test_prewarm.sh, an area-test file, reads ../data/).
sed -E 's#^(platform/data/\*\*\t.*),test$#\1#' "$real_map" > "$mutant"
cmp -s "$real_map" "$mutant" && _fail "mutation 4 changed nothing" "sed did not match"
violations="$(check_map "$mutant")"
case "$violations" in
  *"reads ../data/ but the row for platform/data/** does not list test"*) _pass ;;
  *) _fail "dropping test from the data row is caught" "got: $violations" ;;
esac

# Dropping templates from a row that lists scaffold is caught.
sed -E 's#^(platform/lint/\*\*\t.*),templates$#\1#' "$real_map" > "$mutant"
cmp -s "$real_map" "$mutant" && _fail "mutation 5 changed nothing" "sed did not match"
violations="$(check_map "$mutant")"
case "$violations" in
  *"row 'platform/lint/**' lists scaffold but not templates"*) _pass ;;
  *) _fail "dropping templates from a scaffold row is caught" "got: $violations" ;;
esac

# Dropping templates from a row a template test reads is caught (test_go.sh sources platform/jobs/go-env.sh).
sed -E 's#^(platform/jobs/\*\*\t.*),templates(,.*)$#\1\2#' "$real_map" > "$mutant"
cmp -s "$real_map" "$mutant" && _fail "mutation 6 changed nothing" "sed did not match"
violations="$(check_map "$mutant")"
case "$violations" in
  *"reads platform/jobs/ but the row for platform/jobs/** does not list templates"*) _pass ;;
  *) _fail "dropping templates from the jobs row is caught" "got: $violations" ;;
esac

# Removing a directory's row is caught.
grep -v '^platform/ingress/' "$real_map" > "$mutant"
violations="$(check_map "$mutant")"
case "$violations" in
  *"platform/ingress has files but no areas.map row of its own"*) _pass ;;
  *) _fail "a directory without its row is caught" "got: $violations" ;;
esac

# A target that is not an area is caught.
sed -E 's#^(platform/lint/\*\*\t)lint#\1lint,nosuchdir#' "$real_map" > "$mutant"
violations="$(check_map "$mutant")"
case "$violations" in
  *"names 'nosuchdir'"*) _pass ;;
  *) _fail "an unknown target is caught" "got: $violations" ;;
esac

# A row whose glob names a path that does not exist is allowed (docs/** has no directory here).
printf 'docs/**\tnone\n' > "$mutant"
grep -v '^#' "$real_map" >> "$mutant"
violations="$(check_map "$mutant")"
expect_eq "a row for a path that does not exist is allowed" "$violations" ""

t_finish
