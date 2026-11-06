#!/usr/bin/env bash
# Sequential test runner: `run.sh [FILE...]`, run from the repo root (it cd's there itself).
#   no arguments: discover platform/**/test_*.sh and apps/<name>/test_*.sh (either directory may be absent), sorted
#   FILE...:      run exactly those files, in the given order
# Each file runs as `bash <file>`; a failure does not stop the run. Prints `== <file>` before each file's output and
# `-- <file> rc=<n> <secs>s` after it. At the end it prints `-- timings (slowest first)` (one `<secs>s <file>` line per
# file that ran) and `-- total <secs>s wall, <n> files, <f> failed`. Timing never changes the exit status: 1 if any
# file failed. A no-argument run that finds nothing prints `no test_*.sh found` to stderr and exits 1.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/../.." || { echo "run.sh: cannot enter the repo root" >&2; exit 1; }

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  if [ -d platform ]; then
    while IFS= read -r f; do files+=("$f"); done < <(find platform -name 'test_*.sh' | LC_ALL=C sort)
  fi
  if [ -d apps ]; then
    while IFS= read -r f; do files+=("$f"); done < <(find apps -mindepth 2 -maxdepth 2 -name 'test_*.sh' | LC_ALL=C sort)
  fi
  if [ "${#files[@]}" -eq 0 ]; then
    echo "no test_*.sh found" >&2
    exit 1
  fi
fi

# us_to_secs <microseconds>: seconds with one decimal.
us_to_secs() { printf '%d.%d' "$(($1 / 1000000))" "$(($1 % 1000000 / 100000))"; }
# now_us: the clock in microseconds ($EPOCHREALTIME is "<s>.<us>").
now_us() { local t="$EPOCHREALTIME"; echo "$((10#${t%.*}${t#*.}))"; }

rc=0
failed=0
timings=()
run_start="$(now_us)"
for t in "${files[@]}"; do
  echo "== $t"
  start="$(now_us)"
  frc=0
  bash "$t" || frc=$?
  elapsed=$(($(now_us) - start))
  if [ "$frc" -ne 0 ]; then
    rc=1
    failed=$((failed + 1))
  fi
  secs="$(us_to_secs "$elapsed")"
  echo "-- $t rc=$frc ${secs}s"
  timings+=("$secs $t")
done
total="$(us_to_secs $(($(now_us) - run_start)))"
echo "-- timings (slowest first)"
printf '%s\n' "${timings[@]}" | sort -rn -k1,1 | while read -r secs f; do echo "${secs}s $f"; done
echo "-- total ${total}s wall, ${#files[@]} files, $failed failed"
exit "$rc"
