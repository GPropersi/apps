#!/usr/bin/env bash
# Parallel test runner: `run.sh [FILE...]`, run from the repo root (it cd's there itself).
#   no arguments: discover platform/**/test_*.sh and apps/<name>/test_*.sh (either directory may be absent), sorted
#   FILE...:      run exactly those files
# Each file runs as `bash <file>` in its own process group, its output buffered to <logdir>/<path with / as __>.log.
# When a file finishes it prints `== <file> ok <secs>s` or `== <file> FAIL rc=<n> <secs>s` (or
# `== <file> FAIL timeout after <secs>s`), followed by the buffered output when it failed or TEST_VERBOSE=1; a passing
# file's `SKIPPED:` lines are always printed. At the end: `-- timings (slowest first)`, `-- total <secs>s wall, <n> files,
# <f> failed`, one `FAILED: <file>` line per failed file. Exit status: 1 if any file failed, 2 on an invalid knob or an
# unknown test class, 130/143/129 after INT/TERM/HUP. A no-argument run that finds nothing prints
# `no test_*.sh found` to stderr and exits 1.
#
# Knobs (environment):
#   TEST_JOBS         files run at once, integer 1-64 (default 1)
#   TEST_DOCKER_JOBS  at most this many files of class `docker`, and separately of class `heavy`, at once; integer 1-64
#                     (default 1). Explicitly above an explicit TEST_JOBS is an error; above a defaulted TEST_JOBS it is
#                     clamped to it.
#   TEST_VERBOSE      1: print every file's buffered output, not only failures'
#   TEST_FILE_TIMEOUT per-file limit in seconds, 1-3600 (default 1800): TERM, then KILL after the 20 s kill grace
#   TEST_LOG_DIR      keep the per-file logs there (default: a temp dir, removed after an all-pass run)
# A file's class is read from a `# test-class: docker|heavy` marker in its first 10 lines (unmarked = mocked; any other
# value is an error naming the file). Docker and heavy files are queued ahead of mocked ones, each group in the given
# order, so TEST_JOBS=1 runs unmarked files in the given order, after any docker/heavy-marked files (themselves in the
# given order).
# INT, TERM or HUP sends TERM to every running file's process group, waits up to the kill grace (20 s, shorter than
# hostq's TimeoutStopSec=30) for their EXIT traps, KILLs what is left, and exits. PLATFORM_TEST_KILL_GRACE overrides the
# grace for tests only. Children see PLATFORM_TEST_RUNNER=1.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/../.." || { echo "run.sh: cannot enter the repo root" >&2; exit 1; }

die() { echo "run.sh: $*" >&2; exit 2; }
# valid_int <v> <min> <max>
valid_int() { [[ "$1" =~ ^[1-9][0-9]{0,3}$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }

jobs=1
jobs_explicit=0
if [ -n "${TEST_JOBS+x}" ]; then
  valid_int "$TEST_JOBS" 1 64 || die "TEST_JOBS must be 1-64, got '$TEST_JOBS'"
  jobs="$TEST_JOBS"
  jobs_explicit=1
fi
djobs=1
if [ -n "${TEST_DOCKER_JOBS+x}" ]; then
  valid_int "$TEST_DOCKER_JOBS" 1 64 || die "TEST_DOCKER_JOBS must be 1-64, got '$TEST_DOCKER_JOBS'"
  djobs="$TEST_DOCKER_JOBS"
  if [ "$djobs" -gt "$jobs" ]; then
    [ "$jobs_explicit" -eq 1 ] && die "TEST_DOCKER_JOBS ($djobs) must not exceed TEST_JOBS ($jobs)"
    djobs="$jobs"
  fi
fi
file_timeout=1800
if [ -n "${TEST_FILE_TIMEOUT+x}" ]; then
  valid_int "$TEST_FILE_TIMEOUT" 1 3600 || die "TEST_FILE_TIMEOUT must be 1-3600, got '$TEST_FILE_TIMEOUT'"
  file_timeout="$TEST_FILE_TIMEOUT"
fi
grace=20
if [[ "${PLATFORM_TEST_KILL_GRACE:-}" =~ ^[0-9]{1,4}$ ]]; then grace=$((10#$PLATFORM_TEST_KILL_GRACE)); fi
verbose=0
[ "${TEST_VERBOSE:-}" = "1" ] && verbose=1

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

# Class of every file, read before anything runs so a bad marker cannot slip past.
classes=()
for f in "${files[@]}"; do
  cls=mocked
  while IFS= read -r line; do
    if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*test-class:[[:space:]]*(.*)$ ]]; then
      val="${BASH_REMATCH[1]}"
      val="${val%"${val##*[![:space:]]}"}"
      case "$val" in
        docker | heavy) cls="$val" ;;
        *) die "unknown test class '$val' in $f" ;;
      esac
      break
    fi
  done < <(head -n 10 -- "$f" 2>/dev/null)
  classes+=("$cls")
done

# us_to_secs <microseconds>: seconds with one decimal.
us_to_secs() { printf '%d.%d' "$(($1 / 1000000))" "$(($1 % 1000000 / 100000))"; }
# now_us: the clock in microseconds ($EPOCHREALTIME is "<s>.<us>").
now_us() { local t="$EPOCHREALTIME"; echo "$((10#${t%.*}${t#*.}))"; }

keep_logs=0
if [ -n "${TEST_LOG_DIR:-}" ]; then
  logdir="$TEST_LOG_DIR"
  mkdir -p -- "$logdir" || die "cannot create TEST_LOG_DIR '$logdir'"
  keep_logs=1
else
  logdir="$(mktemp -d)" || die "cannot create a log directory"
fi
statedir="$(mktemp -d)" || die "cannot create a state directory"
trap 'rm -rf -- "$statedir"' EXIT

export PLATFORM_TEST_RUNNER=1

# Queue: docker/heavy files first, then mocked, each group in the given order.
queue=()
for i in "${!files[@]}"; do [ "${classes[$i]}" != mocked ] && queue+=("$i"); done
for i in "${!files[@]}"; do [ "${classes[$i]}" = mocked ] && queue+=("$i"); done

declare -A r_sub r_start r_pgid r_termat r_killed r_timeout
running=()
fails=()
timings=()
nfailed=0
run_start="$(now_us)"

log_of() { local n="${files[$1]//\//__}"; echo "$logdir/$n.log"; }

# group_pid <i>: sets PG to the process group id (the test's pid), read from the pid file once it exists. Called without
# a command substitution so the cached r_pgid survives.
PG=""
group_pid() {
  local i="$1" n=0
  if [ -z "${r_pgid[$i]:-}" ]; then
    while [ ! -s "$statedir/$i.pid" ] && [ "$n" -lt 100 ]; do sleep 0.02; n=$((n + 1)); done
    if [ -s "$statedir/$i.pid" ]; then r_pgid[$i]="$(cat -- "$statedir/$i.pid")"; fi
  fi
  PG="${r_pgid[$i]:-}"
}
group_alive() { [ -n "$1" ] && kill -0 -- "-$1" 2>/dev/null; }

start_file() {
  local i="$1" log
  log="$(log_of "$i")"
  (
    # shellcheck disable=SC2016  # the wrapper's own $$ and positional parameters, expanded by the inner bash
    setsid bash -c 'echo "$$" > "$1"; exec bash "$2"' _ "$statedir/$i.pid" "${files[$i]}" > "$log" 2>&1
    echo "$?" > "$statedir/$i.rc.tmp"
    mv -- "$statedir/$i.rc.tmp" "$statedir/$i.rc"
  ) &
  r_sub[$i]=$!
  r_start[$i]="$(now_us)"
  r_termat[$i]=0
  r_killed[$i]=0
  r_timeout[$i]=0
  running+=("$i")
}

report_done() {
  local i="$1" frc elapsed secs log
  frc="$(cat -- "$statedir/$i.rc")"
  elapsed=$(($(now_us) - r_start[$i]))
  secs="$(us_to_secs "$elapsed")"
  log="$(log_of "$i")"
  if [ "${r_timeout[$i]}" -eq 1 ]; then
    echo "== ${files[$i]} FAIL timeout after ${file_timeout}s"
    cat -- "$log"
    fails+=("${files[$i]}")
    nfailed=$((nfailed + 1))
  elif [ "$frc" -ne 0 ]; then
    echo "== ${files[$i]} FAIL rc=$frc ${secs}s"
    cat -- "$log"
    fails+=("${files[$i]}")
    nfailed=$((nfailed + 1))
  else
    echo "== ${files[$i]} ok ${secs}s"
    if [ "$verbose" -eq 1 ]; then cat -- "$log"; else grep -F 'SKIPPED:' -- "$log"; fi
  fi
  timings+=("$secs ${files[$i]}")
}

# on_signal <rc>: stop every running file cleanly, then exit.
# shellcheck disable=SC2329  # invoked through the signal traps below
on_signal() {
  local code="$1" i pg deadline
  trap '' INT TERM HUP
  for i in "${running[@]}"; do
    group_pid "$i"
    [ -n "$PG" ] && kill -TERM -- "-$PG" 2>/dev/null
  done
  deadline=$(($(now_us) + grace * 1000000))
  while [ "$(now_us)" -lt "$deadline" ]; do
    local alive=0
    for i in "${running[@]}"; do group_alive "${r_pgid[$i]:-}" && alive=1; done
    [ "$alive" -eq 0 ] && break
    sleep 0.1
  done
  for i in "${running[@]}"; do
    group_alive "${r_pgid[$i]:-}" && kill -KILL -- "-${r_pgid[$i]}" 2>/dev/null
  done
  for i in "${running[@]}"; do wait "${r_sub[$i]}" 2>/dev/null; done
  echo "run.sh: interrupted, stopped ${#running[@]} running file(s)" >&2
  echo "run.sh: logs in $logdir" >&2
  exit "$code"
}
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP

count_class() { # class: number of running files of that class
  local c=0 i
  for i in "${running[@]}"; do [ "${classes[$i]}" = "$1" ] && c=$((c + 1)); done
  echo "$c"
}

while [ "${#queue[@]}" -gt 0 ] || [ "${#running[@]}" -gt 0 ]; do
  # Start whatever fits.
  started=1
  while [ "$started" -eq 1 ] && [ "${#queue[@]}" -gt 0 ] && [ "${#running[@]}" -lt "$jobs" ]; do
    started=0
    for qi in "${!queue[@]}"; do
      i="${queue[$qi]}"
      cls="${classes[$i]}"
      if [ "$cls" != mocked ] && [ "$(count_class "$cls")" -ge "$djobs" ]; then continue; fi
      queue=("${queue[@]:0:$qi}" "${queue[@]:$((qi + 1))}")
      start_file "$i"
      started=1
      break
    done
  done

  sleep 0.1

  # Reap finished files, enforce timeouts.
  still=()
  for i in "${running[@]}"; do
    now="$(now_us)"
    if [ -f "$statedir/$i.rc" ]; then
      pg="${r_pgid[$i]:-}"
      # A timed-out file may have left group members behind: KILL them.
      if [ "${r_termat[$i]}" -ne 0 ] && group_alive "$pg"; then kill -KILL -- "-$pg" 2>/dev/null; fi
      wait "${r_sub[$i]}" 2>/dev/null
      report_done "$i"
      continue
    fi
    if [ "${r_termat[$i]}" -eq 0 ]; then
      if [ $((now - r_start[$i])) -ge $((file_timeout * 1000000)) ]; then
        group_pid "$i"
        [ -n "$PG" ] && kill -TERM -- "-$PG" 2>/dev/null
        r_termat[$i]="$now"
        r_timeout[$i]=1
      fi
    elif [ "${r_killed[$i]}" -eq 0 ] && [ $((now - r_termat[$i])) -ge $((grace * 1000000)) ]; then
      pg="${r_pgid[$i]:-}"
      [ -n "$pg" ] && kill -KILL -- "-$pg" 2>/dev/null
      r_killed[$i]=1
    fi
    still+=("$i")
  done
  running=("${still[@]}")
done

total="$(us_to_secs $(($(now_us) - run_start)))"
echo "-- timings (slowest first)"
printf '%s\n' "${timings[@]}" | sort -rn -k1,1 | while read -r secs f; do echo "${secs}s $f"; done
echo "-- total ${total}s wall, ${#files[@]} files, $nfailed failed"
for f in "${fails[@]}"; do echo "FAILED: $f"; done

if [ "$nfailed" -eq 0 ] && [ "$keep_logs" -eq 0 ]; then
  rm -rf -- "$logdir"
  exit 0
fi
echo "run.sh: logs in $logdir"
[ "$nfailed" -eq 0 ] && exit 0
exit 1
