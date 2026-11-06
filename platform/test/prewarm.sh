#!/usr/bin/env bash
# Prewarm: `prewarm.sh <target>...` with targets `images` and `go`, run once by run.sh before the test files fan out, so
# the files do not each pull the same images or download the same Go toolchain at the same moment.
#   images: when `docker info` succeeds, pull (3 at a time, `timeout 300` each) every image pinned in the data, jobs and
#           ingress compose files (read with platform/lib/yaml-subset.sh) and the FROM images of the jobs Dockerfiles,
#           skipping any that `docker image inspect` finds already present and any reference with a variable in it
#           (the locally built runner image).
#   go:     source platform/jobs/go-env.sh in a subshell, which downloads the pinned toolchain into the module cache.
# One line per item: `prewarm: <item> rc=<n> <secs>s`, followed on failure by `: <error text>` (the item is the image
# reference or `go`). A failure is logged and never fails the run: prewarm always exits 0, so the tests' own pull, skip
# or REQUIRE_DOCKER failure still decides.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="$(mktemp -d)" || { echo "prewarm: cannot create a scratch directory" >&2; exit 0; }
trap 'rm -rf -- "$work"' EXIT

want_images=0 want_go=0
for t in "$@"; do
  case "$t" in
    images) want_images=1 ;;
    go) want_go=1 ;;
    *) echo "prewarm: unknown target '$t' (ignored)" >&2 ;;
  esac
done

# report <item> <rc> <start-us> <error-file>: the per-item log line, written in one printf so concurrent items never mix.
now_us() { local t="$EPOCHREALTIME"; echo "$((10#${t%.*}${t#*.}))"; }
report() {
  local item="$1" rc="$2" start="$3" errf="$4" us secs msg=""
  us=$(($(now_us) - start))
  secs="$((us / 1000000)).$((us % 1000000 / 100000))"
  if [ "$rc" -ne 0 ] && [ -s "$errf" ]; then
    msg=": $(tr '\n' ' ' < "$errf" | cut -c 1-400)"
  fi
  printf 'prewarm: %s rc=%s %ss%s\n' "$item" "$rc" "$secs" "$msg"
}

# image_refs: every image reference to pull, one per line, sorted and unique.
image_refs() {
  local f flat df
  # shellcheck disable=SC1091  # sourced by a computed path
  source "$root/platform/lib/yaml-subset.sh" || return 1
  for f in data jobs ingress; do
    flat="$work/flat.$f"
    if ! ys_flatten < "$root/platform/$f/compose.yaml" > "$flat"; then
      echo "prewarm: cannot read platform/$f/compose.yaml" >&2
      continue
    fi
    awk -F'\t' '$1 ~ /^services\/[^\/]+\/image$/ { print $2 }' "$flat"
  done
  for df in "$root/platform/jobs/Dockerfile" "$root/platform/jobs/Dockerfile.testapp"; do
    [ -f "$df" ] || continue
    # FROM [--platform=x] <ref> [AS <alias>]; a later FROM that names an earlier alias is not an image.
    awk '
      toupper($1) == "FROM" {
        i = 2
        while (i <= NF && $i ~ /^--/) i++
        ref = $i
        if (!(ref in alias) && ref != "scratch") print ref
        if (toupper($(i + 1)) == "AS") alias[$(i + 2)] = 1
      }' "$df"
  done
}

pull_one() { # <ref>: pull unless present
  local ref="$1" start rc errf
  if docker image inspect "$ref" > /dev/null 2>&1; then return 0; fi
  start="$(now_us)"
  errf="$work/pull.$$.${RANDOM}"
  timeout 300 docker pull "$ref" > "$errf" 2>&1
  rc=$?
  report "$ref" "$rc" "$start" "$errf"
}

prewarm_images() {
  local errf ref refs pid pulls=() live=()
  errf="$work/images.err"
  if ! docker info > "$errf" 2>&1; then
    echo "prewarm: images rc=0 0.0s skipped, docker info failed: $(tr '\n' ' ' < "$errf" | cut -c 1-200)"
    return 0
  fi
  refs="$(image_refs 2> "$work/refs.err" | grep -v '[$]' | LC_ALL=C sort -u)"
  if [ -s "$work/refs.err" ]; then cat -- "$work/refs.err"; fi
  # At most 3 pulls at a time. Count only the pull PIDs (not `jobs -rp`), so the background go prewarm never takes a slot.
  for ref in $refs; do
    while :; do
      live=()
      for pid in "${pulls[@]}"; do
        if kill -0 "$pid" 2> /dev/null; then live+=("$pid"); fi
      done
      pulls=("${live[@]}")
      [ "${#pulls[@]}" -lt 3 ] && break
      wait -n || true
    done
    pull_one "$ref" &
    pulls+=("$!")
  done
  wait
}

prewarm_go() {
  local start rc errf
  start="$(now_us)"
  errf="$work/go.err"
  # shellcheck disable=SC2016  # the inner bash expands $1, the go-env.sh path
  timeout 600 bash -c '. "$1"' _ "$root/platform/jobs/go-env.sh" > "$errf" 2>&1
  rc=$?
  report "go" "$rc" "$start" "$errf"
}

if [ "$want_go" -eq 1 ]; then prewarm_go & fi
if [ "$want_images" -eq 1 ]; then prewarm_images; fi
wait
exit 0
