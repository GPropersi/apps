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
#   TEST_JOBS         files run at once: `auto` (default) or an integer 1-64
#   TEST_DOCKER_JOBS  at most this many files of class `docker`, and separately of class `heavy`, at once: `auto`
#                     (default) or an integer 1-64. An explicit value above an explicit TEST_JOBS is an error; above an
#                     auto-resolved TEST_JOBS it is clamped to it and the decision line shows `docker_clamped=<asked>-><n>`.
# `auto` sizes the counts from the host and prints one decision line before any file starts:
#   run.sh: jobs=<n> docker_jobs=<d> cpus=<c> mem_usable=<m>MiB binding=<cpu|memory|override|nested|hostq|probe-failed> files=<N>
# cpus is nproc, or max(1, nproc / HOSTQ_SLOTS) (HOSTQ_SLOTS default 2) inside a hostq job (HOSTQ_JOB_ID set; binding=hostq
# when that share limits the count). Usable memory is min(MemTotal * 0.70, min(MemAvailable, cgroup headroom) * 0.90) minus a
# 1024 MiB reserve. The cgroup v2 limit is the minimum numeric memory.max and memory.high over the own cgroup (from
# /proc/self/cgroup) and every ancestor up to the cgroup root, so the app.slice cap above a hostq unit is seen; headroom is
# that limit minus the own memory.current (no 0:: line = cgroup v1 = no limit; `max` or a missing file = no limit at that
# level). TEST_JOBS=auto is clamp(1, min(cpus, usable / 256 MiB), 32); TEST_DOCKER_JOBS=auto is
# clamp(1, min(jobs, usable / 1536 MiB), 3). Inside a runner (PLATFORM_TEST_RUNNER=1) both are 1 (binding=nested). An
# unreadable nproc or meminfo, a garbage cgroup value, or an invalid HOSTQ_SLOTS (checked first whenever HOSTQ_JOB_ID is
# set, even under an explicit TEST_JOBS) gives 1 job, binding=probe-failed and ` unreadable=<path>`.
# Memory admission: while a file is running, a file whose class weight (mocked 256, heavy 1024, docker 1536 MiB) plus the
# reserve exceeds the current MemAvailable is held (`run.sh: memory low (<n> MiB available), holding <file>`, once) until a
# running file finishes; with nothing running a file always starts, so a run cannot deadlock.
# Test-only probe overrides: PLATFORM_TEST_NPROC, PLATFORM_TEST_MEMINFO, PLATFORM_TEST_CGROUP_FILE, PLATFORM_TEST_CGROUP_ROOT,
# PLATFORM_TEST_CGROUP_DIR (the own-cgroup start directory; the walk still climbs to the root).
#   TEST_VERBOSE      1: print every file's buffered output, not only failures'
#   TEST_FILE_TIMEOUT per-file limit in seconds, 1-3600 (default 1800): TERM, then KILL after the 20 s kill grace
#   TEST_LOG_DIR      keep the per-file logs there (default: a temp dir, removed after an all-pass run)
# A file's class is read from a `# test-class: docker|heavy` marker in its first 10 lines (unmarked = mocked; any other
# value is an error naming the file). Docker and heavy files are queued ahead of mocked ones, each group in the given
# order, so TEST_JOBS=1 runs unmarked files in the given order, after any docker/heavy-marked files (themselves in the
# given order).
# Before any file starts (and not inside a nested runner) it calls platform/test/prewarm.sh, when that exists, with `images`
# (any selected file is class docker) and/or `go` (any docker or heavy file, or any file that mentions go-env.sh or
# check-go.sh); no docker file and no Go use means no call. The summary then has a `-- prewarm <secs>s (<targets>)` line.
# INT, TERM or HUP sends TERM to every running file's process group, waits up to the kill grace (20 s, shorter than
# hostq's TimeoutStopSec=30) for their EXIT traps, KILLs what is left, and exits. PLATFORM_TEST_KILL_GRACE overrides the
# grace for tests only. Children see PLATFORM_TEST_RUNNER=1.
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
cd "$here/../.." || { echo "run.sh: cannot enter the repo root" >&2; exit 1; }

die() { echo "run.sh: $*" >&2; exit 2; }
# valid_int <v> <min> <max>
valid_int() { [[ "$1" =~ ^[1-9][0-9]{0,3}$ ]] && [ "$1" -ge "$2" ] && [ "$1" -le "$3" ]; }

# Test-only probe overrides and the nesting flag, read once here and nowhere else.
nested=0
[ "${PLATFORM_TEST_RUNNER:-}" = "1" ] && nested=1
nproc_set=0 nproc_ov=""
if [ -n "${PLATFORM_TEST_NPROC+x}" ]; then nproc_set=1 nproc_ov="$PLATFORM_TEST_NPROC"; fi
meminfo_file="${PLATFORM_TEST_MEMINFO:-/proc/meminfo}"
cg_file="${PLATFORM_TEST_CGROUP_FILE:-/proc/self/cgroup}"
cg_root="${PLATFORM_TEST_CGROUP_ROOT:-/sys/fs/cgroup}"
cg_dir_set=0 cg_dir=""
if [ -n "${PLATFORM_TEST_CGROUP_DIR:-}" ]; then cg_dir_set=1 cg_dir="$PLATFORM_TEST_CGROUP_DIR"; fi

jobs_req=auto
if [ -n "${TEST_JOBS+x}" ]; then
  if [ "$TEST_JOBS" != auto ]; then valid_int "$TEST_JOBS" 1 64 || die "TEST_JOBS must be auto or 1-64, got '$TEST_JOBS'"; fi
  jobs_req="$TEST_JOBS"
fi
djobs_req=auto
if [ -n "${TEST_DOCKER_JOBS+x}" ]; then
  if [ "$TEST_DOCKER_JOBS" != auto ]; then
    valid_int "$TEST_DOCKER_JOBS" 1 64 || die "TEST_DOCKER_JOBS must be auto or 1-64, got '$TEST_DOCKER_JOBS'"
  fi
  djobs_req="$TEST_DOCKER_JOBS"
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

# --- Job counts from the host (TEST_JOBS / TEST_DOCKER_JOBS = auto) ---
mem_reserve=1024 # MiB kept free for the rest of the host
# class_weight <class>: MiB one file of that class is assumed to need.
class_weight() {
  case "$1" in
    docker) echo 1536 ;;
    heavy) echo 1024 ;;
    *) echo 256 ;;
  esac
}
# read_meminfo: sets MI_TOTAL and MI_AVAIL (MiB); returns 1 and sets MI_ERR (the path) when unreadable.
MI_TOTAL="" MI_AVAIL="" MI_ERR=""
read_meminfo() {
  local k v total="" avail=""
  MI_ERR="$meminfo_file"
  [ -r "$meminfo_file" ] || return 1
  while read -r k v _ || [ -n "$k" ]; do
    case "$k" in
      MemTotal:) total="$v" ;;
      MemAvailable:) avail="$v" ;;
    esac
  done < "$meminfo_file"
  [[ "$total" =~ ^[0-9]{1,15}$ ]] && [[ "$avail" =~ ^[0-9]{1,15}$ ]] || return 1
  MI_TOTAL=$((10#$total / 1024))
  MI_AVAIL=$((10#$avail / 1024))
  MI_ERR=""
}
# cg_limit: the cgroup v2 memory ceiling. Sets CG_LIMIT (bytes, empty = none) and CG_CUR (own memory.current); returns 1
# and sets CG_ERR (the path) when a present file holds garbage. The own cgroup comes from the `0::<path>` line of
# /proc/self/cgroup (none = cgroup v1 = no limit); the limit is the minimum numeric memory.max and memory.high at the own
# cgroup and every ancestor up to the cgroup root (`max` or a missing file = no limit at that level); memory.current is read
# from the own cgroup only (missing = no limit).
CG_LIMIT="" CG_CUR="" CG_ERR=""
cg_limit() {
  local start="" root line path d f v
  CG_LIMIT="" CG_CUR="" CG_ERR=""
  root="${cg_root%/}"
  [ -z "$root" ] && root=/
  if [ "$cg_dir_set" -eq 1 ]; then
    start="$cg_dir"
  else
    [ -r "$cg_file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" == 0::* ]]; then
        path="${line#0::}"
        path="${path%" (deleted)"}"
        start="${root%/}/${path#/}"
        break
      fi
    done < "$cg_file"
    [ -n "$start" ] || return 0
  fi
  start="${start%/}"
  [ -z "$start" ] && start=/
  d="$start"
  while :; do
    for f in memory.max memory.high; do
      [ -e "$d/$f" ] || continue
      v=""
      read -r v < "$d/$f" 2> /dev/null
      v="${v//[[:space:]]/}"
      if [ "$v" = max ]; then
        continue
      elif [[ "$v" =~ ^[0-9]{1,19}$ ]]; then
        v=$((10#$v))
        if [ -z "$CG_LIMIT" ] || [ "$v" -lt "$CG_LIMIT" ]; then CG_LIMIT="$v"; fi
      else
        CG_ERR="$d/$f"
        return 1
      fi
    done
    [ "$d" = "$root" ] && break
    [ "$d" = / ] && break
    d="${d%/*}"
    [ -z "$d" ] && d=/
  done
  [ -n "$CG_LIMIT" ] || return 0
  if [ ! -e "$start/memory.current" ]; then
    CG_LIMIT=""
    return 0
  fi
  v=""
  read -r v < "$start/memory.current" 2> /dev/null
  v="${v//[[:space:]]/}"
  if [[ "$v" =~ ^[0-9]{1,19}$ ]]; then
    CG_CUR=$((10#$v))
  else
    CG_ERR="$start/memory.current"
    return 1
  fi
}

# resolve_jobs: sets jobs, djobs, binding, cpus_s, mem_s, clamp_note, unreadable from the knobs and the host.
jobs=1 djobs=1 binding=override cpus_s="n/a" mem_s="n/a" clamp_note="" unreadable=""
resolve_jobs() {
  local slots=1 hostq=0 nproc_raw probe_err="" cpus=0 usable=0 avail_eff headroom jb db mem_n j
  if [ -n "${HOSTQ_JOB_ID+x}" ]; then
    hostq=1
    slots=2
    if [ -n "${HOSTQ_SLOTS+x}" ]; then slots="$HOSTQ_SLOTS"; fi
    if ! valid_int "$slots" 1 9999; then
      jobs=1 djobs=1 binding=probe-failed unreadable=HOSTQ_SLOTS
      return 0
    fi
  fi

  # Probes (best effort; a failure only matters when an `auto` value needs them).
  if [ "$nproc_set" -eq 1 ]; then
    nproc_raw="$nproc_ov"
    [[ "$nproc_raw" =~ ^[1-9][0-9]{0,5}$ ]] || { probe_err="PLATFORM_TEST_NPROC"; nproc_raw=""; }
  else
    nproc_raw="$(nproc 2> /dev/null)"
    [[ "$nproc_raw" =~ ^[1-9][0-9]{0,5}$ ]] || { probe_err="nproc"; nproc_raw=""; }
  fi
  if [ -n "$nproc_raw" ]; then
    cpus="$nproc_raw"
    if [ "$hostq" -eq 1 ]; then
      cpus=$((cpus / slots))
      [ "$cpus" -lt 1 ] && cpus=1
    fi
    cpus_s="$cpus"
  fi
  if read_meminfo; then
    avail_eff="$MI_AVAIL"
    if cg_limit; then
      if [ -n "$CG_LIMIT" ]; then
        headroom=$(((CG_LIMIT - CG_CUR) / 1048576))
        [ "$headroom" -lt 0 ] && headroom=0
        [ "$headroom" -lt "$avail_eff" ] && avail_eff="$headroom"
      fi
      usable=$((MI_TOTAL * 70 / 100))
      [ $((avail_eff * 90 / 100)) -lt "$usable" ] && usable=$((avail_eff * 90 / 100))
      usable=$((usable - mem_reserve))
      [ "$usable" -lt 0 ] && usable=0
      mem_s="$usable"
    else
      [ -z "$probe_err" ] && probe_err="$CG_ERR"
    fi
  else
    [ -z "$probe_err" ] && probe_err="$MI_ERR"
  fi

  # TEST_JOBS
  if [ "$jobs_req" != auto ]; then
    jobs="$jobs_req"
    jb=override
  elif [ "$nested" -eq 1 ]; then
    jobs=1
    jb=nested
  elif [ -n "$probe_err" ]; then
    jobs=1
    jb=probe-failed
  else
    mem_n=$((usable / 256))
    j="$cpus"
    jb=cpu
    [ "$hostq" -eq 1 ] && jb=hostq
    if [ "$mem_n" -lt "$j" ]; then
      j="$mem_n"
      jb=memory
    fi
    [ "$j" -gt 32 ] && j=32
    [ "$j" -lt 1 ] && j=1
    jobs="$j"
  fi
  # TEST_DOCKER_JOBS
  db=""
  if [ "$djobs_req" != auto ]; then
    djobs="$djobs_req"
    if [ "$djobs" -gt "$jobs" ]; then
      [ "$jobs_req" != auto ] && die "TEST_DOCKER_JOBS ($djobs) must not exceed TEST_JOBS ($jobs)"
      clamp_note=" docker_clamped=$djobs->$jobs"
      djobs="$jobs"
    fi
  elif [ "$nested" -eq 1 ]; then
    djobs=1
  elif [ -n "$probe_err" ]; then
    djobs=1
    db=probe-failed
  else
    j=$((usable / 1536))
    [ "$jobs" -lt "$j" ] && j="$jobs"
    [ "$j" -gt 3 ] && j=3
    [ "$j" -lt 1 ] && j=1
    djobs="$j"
  fi
  binding="$jb"
  [ "$jobs_req" != auto ] && [ -n "$db" ] && binding="$db"
  [ -n "$probe_err" ] && [ "$binding" = probe-failed ] && unreadable="$probe_err"
  return 0
}
resolve_jobs
mem_field="n/a"
[ "$mem_s" != "n/a" ] && mem_field="${mem_s}MiB"
echo "run.sh: jobs=$jobs docker_jobs=$djobs cpus=$cpus_s mem_usable=$mem_field binding=$binding files=${#files[@]}$clamp_note${unreadable:+ unreadable=$unreadable}"

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

# Prewarm, once, before the fan-out (a nested runner skips it: the outer run already warmed). `images` when any selected
# file is class docker; `go` when any is docker or heavy, or (any class) mentions go-env.sh or check-go.sh. No docker file
# and no Go use means no call. Only when prewarm.sh exists (scratch trees have none). It never fails the run.
prewarm_secs=""
prewarm_targets=()
if [ "$nested" -eq 0 ] && [ -f "$here/prewarm.sh" ]; then
  want_images=0 want_go=0
  for i in "${!files[@]}"; do
    case "${classes[$i]}" in
      docker) want_images=1 want_go=1 ;;
      heavy) want_go=1 ;;
      *) if grep -qE 'go-env\.sh|check-go\.sh' -- "${files[$i]}" 2> /dev/null; then want_go=1; fi ;;
    esac
  done
  [ "$want_images" -eq 1 ] && prewarm_targets+=(images)
  [ "$want_go" -eq 1 ] && prewarm_targets+=(go)
  if [ "${#prewarm_targets[@]}" -gt 0 ]; then
    pw_start="$(now_us)"
    bash "$here/prewarm.sh" "${prewarm_targets[@]}"
    prewarm_secs="$(us_to_secs $(($(now_us) - pw_start)))"
  fi
fi

# Queue: docker/heavy files first, then mocked, each group in the given order.
queue=()
for i in "${!files[@]}"; do [ "${classes[$i]}" != mocked ] && queue+=("$i"); done
for i in "${!files[@]}"; do [ "${classes[$i]}" = mocked ] && queue+=("$i"); done

declare -A r_sub r_start r_pgid r_termat r_killed r_timeout r_held
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
      # Admission: with something already running, hold a file the free memory cannot take. With nothing running it
      # starts anyway, so a run cannot deadlock. An unreadable meminfo never holds.
      if [ "${#running[@]}" -gt 0 ] && read_meminfo && [ "$MI_AVAIL" -lt $(($(class_weight "$cls") + mem_reserve)) ]; then
        if [ -z "${r_held[$i]:-}" ]; then
          r_held[$i]=1
          echo "run.sh: memory low (${MI_AVAIL} MiB available), holding ${files[$i]}"
        fi
        continue
      fi
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
if [ -n "$prewarm_secs" ]; then echo "-- prewarm ${prewarm_secs}s (${prewarm_targets[*]})"; fi
echo "-- total ${total}s wall, ${#files[@]} files, $nfailed failed"
for f in "${fails[@]}"; do echo "FAILED: $f"; done

if [ "$nfailed" -eq 0 ] && [ "$keep_logs" -eq 0 ]; then
  rm -rf -- "$logdir"
  exit 0
fi
echo "run.sh: logs in $logdir"
[ "$nfailed" -eq 0 ] && exit 0
exit 1
