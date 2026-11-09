#!/usr/bin/env bash
# check-test-classes.sh: the test-class completeness check `make lint` enforces. Each problem prints
# `<path>: <reason>` on stdout and the script exits 1 (2 on usage).
#
#   platform/lint/check-test-classes.sh [--root DIR]      DIR is the repo root (default: the git top level)
#
# `platform/test/run.sh` reads a `# test-class: docker|heavy` marker from the first 10 lines of a test file to cap
# real-container and CPU-heavy files separately; an unmarked file is mocked. Over every platform/**/test_*.sh and
# apps/*/test_*.sh and templates/*/test_*.sh (comment lines ignored):
#   1. a file with a real-Docker or Go probe must carry a marker. The probes are `docker info` and `go test` (a whole
#      word) at command position: line start, or after `!` `||` `&&` `;` `|` `(` `{` `$(` `then` `else` `do` `if`
#      `elif` `while` `until`. Prose such as `check-go tests:` or `main.go testapp/` does not match;
#   2. a `# test-class:` line whose value is not exactly `docker` or `heavy` fails;
#   3. more than one marker in the first 10 lines fails;
#   4. any `# test-class:` line after line 10 fails (run.sh would never see it).
# Exclusions (a mocked file that stubs or wraps a probe) live in platform/lint/test-class-exclusions.txt under the
# root, one `<path> <reason>` per line (`#` comment lines allowed). An entry whose file is missing, or no longer
# contains a probe, fails so the list cannot rot.
# Scope: detection is by the probe text, so a live test written without the standard skip preamble
# (`docker info ... || skip ...`) escapes it; the consequence is an uncapped live test, not a wrong result.
set -uo pipefail

root=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root) [ $# -ge 2 ] || { echo "missing value for --root" >&2; exit 2; }; root="$2"; shift 2 ;;
    -h | --help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$root" ] || root="$(git rev-parse --show-toplevel)" || exit 2
[ -d "$root" ] || { echo "no such directory: $root" >&2; exit 2; }

window=10
exclusions="platform/lint/test-class-exclusions.txt"
probe='(^[[:space:]]*|[!;|({][[:space:]]*|&&[[:space:]]*|(^|[^[:alnum:]_-])(then|else|do|if|elif|while|until)[[:space:]]+)(docker info|go test)([^[:alnum:]_]|$)'

problems=0
problem() {
  echo "$1: $2"
  problems=$((problems + 1))
}

# has_probe <relative path>: succeeds when a non-comment line carries a probe at command position.
has_probe() {
  grep -v -E '^[[:space:]]*#' "$root/$1" | grep -q -E "$probe"
}

excluded=" "
if [ -f "$root/$exclusions" ]; then
  while IFS= read -r entry || [ -n "$entry" ]; do
    case "$entry" in '' | '#'*) continue ;; esac
    path="${entry%% *}"
    if [ ! -f "$root/$path" ]; then
      problem "$exclusions" "entry '$path' names a file that does not exist"
    elif ! has_probe "$path"; then
      problem "$exclusions" "entry '$path' no longer contains a docker info or go test probe"
    else
      excluded="$excluded$path "
    fi
  done < "$root/$exclusions"
fi

files="$(
  {
    [ -d "$root/platform" ] && find "$root/platform" -type f -name 'test_*.sh'
    [ -d "$root/apps" ] && find "$root/apps" -mindepth 2 -maxdepth 2 -type f -name 'test_*.sh'
    [ -d "$root/templates" ] && find "$root/templates" -mindepth 2 -maxdepth 2 -type f -name 'test_*.sh'
  } | sed "s|^$root/||" | sort
)"

while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  in_window=0
  valid=0
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    n="${hit%%:*}"
    text="${hit#*:}"
    if [ "$n" -gt "$window" ]; then
      problem "$rel" "line $n: test-class marker after line $window is never read by run.sh"
      continue
    fi
    in_window=$((in_window + 1))
    if [[ "$text" =~ ^#\ test-class:\ (docker|heavy)$ ]]; then
      valid=$((valid + 1))
    else
      problem "$rel" "line $n: unknown test class (want exactly '# test-class: docker' or '# test-class: heavy')"
    fi
  done < <(grep -n -E '^[[:space:]]*#[[:space:]]*test-class:' "$root/$rel")
  if [ "$in_window" -gt 1 ]; then
    problem "$rel" "more than one test-class marker in the first $window lines"
  fi
  if [ "$valid" -eq 0 ] && has_probe "$rel"; then
    case "$excluded" in
      *" $rel "*) ;;
      *) problem "$rel" "starts real containers or runs go test but has no '# test-class:' marker in the first $window lines" ;;
    esac
  fi
done <<< "$files"

[ "$problems" -eq 0 ] || exit 1
exit 0
