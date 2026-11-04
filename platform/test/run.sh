#!/usr/bin/env bash
# Sequential test runner: `run.sh [FILE...]`, run from the repo root (it cd's there itself).
#   no arguments: discover platform/**/test_*.sh and apps/<name>/test_*.sh (either directory may be absent), sorted
#   FILE...:      run exactly those files, in the given order
# Each file runs as `bash <file>`; a failure does not stop the run. Prints `== <file>` per file and exits 1 if any
# failed. A no-argument run that finds nothing prints `no test_*.sh found` to stderr and exits 1.
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

rc=0
for t in "${files[@]}"; do
  echo "== $t"
  bash "$t" || rc=1
done
exit "$rc"
