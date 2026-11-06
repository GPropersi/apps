#!/usr/bin/env bash
# Tests for run.sh (output format, exit codes, ordering, concurrency caps, timeouts, signals, log dir) on a scratch root
# that holds a copy of run.sh and fake test files.
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh. SC2016: the fake files' bodies
# are single-quoted on purpose ($C expands when the fake file runs).
# shellcheck disable=SC1091,SC2154,SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"

t_init
S="$T_TMP/repo"
C="$T_TMP/probe"
mkdir -p "$S/platform/test" "$S/platform/a" "$S/platform/b" "$S/apps/foo" "$C"
cp -- "$here/run.sh" "$S/platform/test/run.sh"
R="$S/platform/test/run.sh"
export C

# ENVU (from lib.sh) gives every scratch run a clean slate of outer runner/hostq/knob variables; each case sets only what it needs.

# The probe records how many files (overall and of its class) run at this moment, then sleeps.
cat > "$C/probe.sh" <<'EOF'
#!/usr/bin/env bash
cls="$1" dur="$2"
touch "$C/all.$$" "$C/$cls.$$"
ls "$C"/all.* | wc -l >> "$C/peak_all"
ls "$C/$cls".* | wc -l >> "$C/peak_$cls"
sleep "$dur"
rm -f "$C/all.$$" "$C/$cls.$$"
EOF

peak() { sort -rn "$C/peak_$1" 2>/dev/null | head -n 1; }
reset_probe() { rm -f "$C"/all.* "$C"/mocked.* "$C"/docker.* "$C"/heavy.* "$C"/peak_*; }
clear_tests() { rm -f "$S"/platform/*/test_*.sh "$S"/apps/*/test_*.sh; }

# fake <path> <class|-> <body...>: a fake test file; class - means unmarked.
fake() {
  local path="$S/$1" cls="$2"
  shift 2
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$cls" != "-" ]; then printf '# test-class: %s\n' "$cls"; fi
    printf '%s\n' "$@"
  } > "$path"
}
# probe_fake <path> <class|-> <secs>
probe_fake() { fake "$1" "$2" "bash \"\$C/probe.sh\" ${2/-/mocked} $3"; }

# gone <pid>: bounded poll until the process no longer exists.
gone() {
  local n=0
  while kill -0 "$1" 2>/dev/null && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  ! kill -0 "$1" 2>/dev/null
}
# wait_file <path>: bounded poll until the file exists.
wait_file() {
  local n=0
  while [ ! -e "$1" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n + 1)); done
  [ -e "$1" ]
}

# --- Output format, exit codes, summary ---
fake platform/a/test_a.sh - 'exit 0'
fake platform/b/test_b.sh - 'sleep 0.2' 'echo b-line-1' 'echo b-line-2' 'exit 1'
fake apps/foo/test_c.sh - 'echo quiet-noise' 'echo "SKIPPED: no docker"' 'exit 0'

run_cmd "${ENVU[@]}" bash "$R"
expect_rc "a failing file gives rc 1" 1
expect_out_has "all files still run (first)" "== platform/a/test_a.sh"
expect_out_has "all files still run (last)" "== apps/foo/test_c.sh"
expect_out_has "the failing file is named with its rc" "== platform/b/test_b.sh FAIL rc=1 "
expect_out_has "the passing file reports ok" "== platform/a/test_a.sh ok "
expect_out_has "the summary header" "-- timings (slowest first)"
expect_out_has "the total line counts files and failures" " wall, 3 files, 1 failed"
expect_out_has "a FAILED line follows the total" "FAILED: platform/b/test_b.sh"
expect_out_lacks "no old per-file rc line" "-- platform/a/test_a.sh rc="

if grep -qE '^== platform/a/test_a\.sh ok [0-9]+\.[0-9]s$' <<<"$out"; then _pass; else _fail "the ok line matches the pattern"; fi
if grep -qE '^== platform/b/test_b\.sh FAIL rc=1 [0-9]+\.[0-9]s$' <<<"$out"; then _pass; else _fail "the FAIL line matches the pattern"; fi
if grep -qE '^-- total [0-9]+\.[0-9]s wall, 3 files, 1 failed$' <<<"$out"; then _pass; else _fail "the total line matches the pattern"; fi

# A failing file's output follows its FAIL line contiguously; a passing file's is hidden except its SKIPPED: line.
if grep -A2 -F '== platform/b/test_b.sh FAIL' <<<"$out" | sed -n '2,3p' | paste -sd' ' - | grep -qF 'b-line-1 b-line-2'; then
  _pass
else
  _fail "a failing file's output is printed contiguously after its FAIL line"
fi
expect_out_lacks "a passing file's output is not printed" "quiet-noise"
expect_out_has "a passing file's SKIPPED: line is printed" "SKIPPED: no docker"
run_cmd "${ENVU[@]}" env TEST_VERBOSE=1 bash "$R"
expect_out_has "TEST_VERBOSE=1 prints a passing file's output" "quiet-noise"

# The slowest file (sleeps 0.2 s) is listed first after the header.
first="$(sed -n '/^-- timings/{n;p;}' <<<"$out")"
case "$first" in
  *" platform/b/test_b.sh") _pass ;;
  *) _fail "the summary is sorted slowest first" "first timing line: $first" ;;
esac
if grep -qE '^[0-9]+\.[0-9]s platform/' <<<"$first"; then _pass; else _fail "the timing line has the secs-then-file shape" "line: $first"; fi

run_cmd "${ENVU[@]}" env TEST_JOBS=1 bash "$R" apps/foo/test_c.sh platform/a/test_a.sh
expect_rc "explicit passing files give rc 0" 0
order="$(grep -E '^== ' <<<"$out" | sed -E 's/^(== [^ ]+) .*/\1/' | paste -sd' ' -)"
expect_eq "explicit args run exactly those files in order" "$order" "== apps/foo/test_c.sh == platform/a/test_a.sh"
expect_out_lacks "the summary names only files that ran" "test_b.sh"
expect_out_has "the total counts only the files run" " wall, 2 files, 0 failed"

# --- Ordering: docker/heavy-marked files first, each group in the given order ---
clear_tests
fake platform/a/test_m1.sh - 'exit 0'
fake platform/a/test_m2.sh - 'exit 0'
fake platform/a/test_d1.sh docker 'exit 0'
fake platform/a/test_h1.sh heavy 'exit 0'
run_cmd "${ENVU[@]}" env TEST_JOBS=1 bash "$R" platform/a/test_m1.sh platform/a/test_m2.sh platform/a/test_h1.sh platform/a/test_d1.sh
expect_rc "ordering run passes" 0
order="$(grep -E '^== ' <<<"$out" | sed -E 's/^== ([^ ]+) .*/\1/' | paste -sd' ' -)"
expect_eq "TEST_JOBS=1 runs marked files first (given order), then unmarked (given order)" "$order" \
  "platform/a/test_h1.sh platform/a/test_d1.sh platform/a/test_m1.sh platform/a/test_m2.sh"

# --- Concurrency caps ---
clear_tests
reset_probe
for n in 1 2 3 4 5 6; do probe_fake "platform/a/test_m$n.sh" - 0.5; done
run_cmd "${ENVU[@]}" env TEST_JOBS=3 bash "$R"
expect_rc "TEST_JOBS=3 run passes" 0
p="$(peak all)"
if [ "${p:-0}" -le 3 ] && [ "${p:-0}" -ge 2 ]; then _pass; else _fail "peak concurrency is between 2 and TEST_JOBS (3)" "peak=${p:-none}"; fi

clear_tests
reset_probe
for n in 1 2 3 4; do probe_fake "platform/a/test_d$n.sh" docker 0.5; done
for n in 1 2 3 4; do probe_fake "platform/b/test_h$n.sh" heavy 0.5; done
for n in 1 2; do probe_fake "platform/a/test_m$n.sh" - 0.5; done
run_cmd "${ENVU[@]}" env TEST_JOBS=10 TEST_DOCKER_JOBS=2 bash "$R"
expect_rc "docker-capped run passes" 0
pd="$(peak docker)" ph="$(peak heavy)" pa="$(peak all)"
if [ "${pd:-0}" -le 2 ] && [ "${pd:-0}" -ge 2 ]; then _pass; else _fail "docker peak is exactly TEST_DOCKER_JOBS" "peak=${pd:-none}"; fi
if [ "${ph:-0}" -le 2 ] && [ "${ph:-0}" -ge 2 ]; then _pass; else _fail "heavy peak is exactly TEST_DOCKER_JOBS" "peak=${ph:-none}"; fi
if [ "${pa:-0}" -le 10 ] && [ "${pa:-0}" -ge 2 ]; then _pass; else _fail "overall peak is within TEST_JOBS" "peak=${pa:-none}"; fi

# A docker cap with TEST_JOBS left at its default is clamped to it, not an error.
clear_tests
reset_probe
for n in 1 2 3; do probe_fake "platform/a/test_d$n.sh" docker 0.2; done
run_cmd "${ENVU[@]}" env PLATFORM_TEST_NPROC=1 TEST_DOCKER_JOBS=3 bash "$R"
expect_rc "an explicit docker cap above a defaulted job count is clamped" 0
pd="$(peak docker)"
if [ "${pd:-0}" -eq 1 ]; then _pass; else _fail "the clamped run is serial" "peak=${pd:-none}"; fi

# --- Automatic job count: fake probes, each case asserts the decision line and the peak concurrency ---
MIB=1048576
cg="$T_TMP/cg"
mem16="$T_TMP/mem16" mem4="$T_TMP/mem4"
mk_mem() { printf 'MemTotal:       %d kB\nMemFree:        1 kB\nMemAvailable:   %d kB\n' $(($1 * 1024)) $(($2 * 1024)) > "$3"; }
mk_mem 16384 16384 "$mem16"
mk_mem 4096 4096 "$mem4"
newcg() { rm -rf "$cg"; mkdir -p "$cg/root"; }
# setlim <dir> <file> <MiB|max|raw text>
setlim() { mkdir -p "$1"; if [[ "$3" =~ ^[0-9]+$ ]]; then echo $(($3 * MIB)) > "$1/$2"; else echo "$3" > "$1/$2"; fi; }
# auto_case <label> <expected decision line after "run.sh: "> <max peak> <env assignments...>
auto_case() {
  local label="$1" want="$2" pmax="$3" pmin=2 pk
  shift 3
  [ "$pmax" -lt 2 ] && pmin=1
  clear_tests
  reset_probe
  for n in 1 2 3 4 5 6; do probe_fake "platform/a/test_m$n.sh" - 0.4; done
  run_cmd "${ENVU[@]}" env "$@" bash "$R"
  expect_rc "$label: the run passes" 0
  expect_eq "$label: decision line" "$(grep -m1 '^run.sh: jobs=' <<<"$out")" "run.sh: $want"
  pk="$(peak all)"
  if [ "${pk:-0}" -le "$pmax" ] && [ "${pk:-0}" -ge "$pmin" ]; then _pass; else _fail "$label: peak concurrency in $pmin..$pmax" "peak=${pk:-none}"; fi
}
base16="cpus=4 mem_usable=10444MiB"
# 16 GiB: min(16384*0.70, 16384*0.90) - 1024 = 10444 MiB usable.
auto_case "a CPU-bound host" "jobs=4 docker_jobs=3 $base16 binding=cpu files=6" 4 PLATFORM_TEST_NPROC=4 PLATFORM_TEST_MEMINFO="$mem16"
# 4 GiB: min(2867, 3686) - 1024 = 1843 MiB usable, so 7 jobs and 1 docker job.
auto_case "a memory-bound host" "jobs=7 docker_jobs=1 cpus=16 mem_usable=1843MiB binding=memory files=6" 6 PLATFORM_TEST_NPROC=16 PLATFORM_TEST_MEMINFO="$mem4"

# cgroup v2: a 3072 MiB limit with 1024 MiB used leaves 2048 MiB of headroom, so usable is 2048*0.9 - 1024 = 819 MiB.
lim819="jobs=3 docker_jobs=1 cpus=16 mem_usable=819MiB binding=memory files=6"
cgenv=(PLATFORM_TEST_NPROC=16 PLATFORM_TEST_MEMINFO="$mem16" PLATFORM_TEST_CGROUP_FILE="$cg.file" PLATFORM_TEST_CGROUP_ROOT="$cg/root")
printf '0::/g\n' > "$cg.file"
newcg
setlim "$cg/root/g" memory.max 3072
setlim "$cg/root/g" memory.current 1024
auto_case "a cgroup limit below MemAvailable" "$lim819" 3 "${cgenv[@]}"

newcg
setlim "$cg/root/g" memory.max max
setlim "$cg/root/g" memory.current 1024
auto_case "memory.max set to max" "jobs=16 docker_jobs=3 cpus=16 mem_usable=10444MiB binding=cpu files=6" 6 "${cgenv[@]}"

newcg
mkdir -p "$cg/root/g"
auto_case "a missing cgroup memory.max is no limit" "jobs=16 docker_jobs=3 cpus=16 mem_usable=10444MiB binding=cpu files=6" 6 "${cgenv[@]}"

newcg
setlim "$cg/root/g" memory.max "not-a-number"
auto_case "a garbage cgroup memory.max" "jobs=1 docker_jobs=1 cpus=16 mem_usable=n/a binding=probe-failed files=6 unreadable=$cg/root/g/memory.max" 1 "${cgenv[@]}"

# The hostq unit: a fake /proc/self/cgroup path resolves to a scratch directory holding the limit (the own cgroup is read, not the root).
printf '0::/hostq.slice/unit.service\n' > "$cg.file"
newcg
setlim "$cg/root/hostq.slice/unit.service" memory.max 3072
setlim "$cg/root/hostq.slice/unit.service" memory.current 1024
auto_case "a hostq unit cgroup limit" "jobs=3 docker_jobs=1 cpus=8 mem_usable=819MiB binding=memory files=6" 3 "${cgenv[@]}" HOSTQ_JOB_ID=x HOSTQ_SLOTS=2
printf '0::/g\n' > "$cg.file"

# Walk-up cases (the limit is the minimum over the own cgroup and every ancestor up to the root).
printf '0::/p/c\n' > "$cg.file"
newcg
setlim "$cg/root/p" memory.max 3072
setlim "$cg/root/p/c" memory.max 8192
setlim "$cg/root/p/c" memory.current 1024
auto_case "a tighter parent memory.max binds" "$lim819" 3 "${cgenv[@]}"

newcg
setlim "$cg/root/p" memory.max 8192
setlim "$cg/root/p/c" memory.max 3072
setlim "$cg/root/p/c" memory.current 1024
auto_case "a tighter child memory.max binds (the minimum, not the outermost)" "$lim819" 3 "${cgenv[@]}"

newcg
setlim "$cg/root/p/c" memory.max 8192
setlim "$cg/root/p/c" memory.high 3072
setlim "$cg/root/p/c" memory.current 1024
auto_case "memory.high tighter than memory.max binds" "$lim819" 3 "${cgenv[@]}"

newcg
setlim "$cg/root/p" memory.max max
setlim "$cg/root/p/c" memory.max max
setlim "$cg/root/p/c" memory.high max
setlim "$cg/root/p/c" memory.current 1024
auto_case "max at every level is no limit" "jobs=16 docker_jobs=3 cpus=16 mem_usable=10444MiB binding=cpu files=6" 6 "${cgenv[@]}"

newcg
setlim "$cg/root/p" memory.max 3072
setlim "$cg/root/p/c" memory.current 1024
auto_case "PLATFORM_TEST_CGROUP_DIR as the start still climbs to a limit in its parent" "$lim819" 3 "${cgenv[@]}" PLATFORM_TEST_CGROUP_FILE="$T_TMP/none.file" PLATFORM_TEST_CGROUP_DIR="$cg/root/p/c"

newcg
setlim "$cg/root/p" memory.high "garbage"
setlim "$cg/root/p/c" memory.current 1024
auto_case "a garbage memory.high in a parent" "jobs=1 docker_jobs=1 cpus=16 mem_usable=n/a binding=probe-failed files=6 unreadable=$cg/root/p/memory.high" 1 "${cgenv[@]}"

newcg
setlim "$cg/root/p" memory.max 3072
setlim "$cg/root/p" memory.current 3000
setlim "$cg/root/p/c" memory.current 1024
auto_case "only the own memory.current is used for the headroom" "$lim819" 3 "${cgenv[@]}"

newcg
setlim "$cg/root/p" memory.max 3072
auto_case "a missing memory.current is no limit" "jobs=16 docker_jobs=3 cpus=16 mem_usable=10444MiB binding=cpu files=6" 6 "${cgenv[@]}"

# A limit in a parent of the cgroup root is ignored: the walk stops at the root.
newcg
setlim "$cg" memory.max 1
mkdir -p "$cg/root/p/c"
setlim "$cg/root/p/c" memory.current 1024
auto_case "a limit above the cgroup root is ignored" "jobs=16 docker_jobs=3 cpus=16 mem_usable=10444MiB binding=cpu files=6" 6 "${cgenv[@]}"

# cgroup v1 (no 0:: line): a binding memory.max in the root directory is not misread.
printf '12:memory:/g\n1:name=systemd:/g\n' > "$cg.file"
newcg
setlim "$cg/root" memory.max 1
auto_case "a v1 file is no limit even with a memory.max in the root" "jobs=16 docker_jobs=3 cpus=16 mem_usable=10444MiB binding=cpu files=6" 6 "${cgenv[@]}"

# Hostq share, nested default, unreadable probes, overrides, docker clamp, the outer-environment case.
auto_case "the hostq share" "jobs=4 docker_jobs=3 $base16 binding=hostq files=6" 4 PLATFORM_TEST_NPROC=8 PLATFORM_TEST_MEMINFO="$mem16" HOSTQ_JOB_ID=x HOSTQ_SLOTS=2
auto_case "the hostq share defaults to 2 slots" "jobs=4 docker_jobs=3 $base16 binding=hostq files=6" 4 PLATFORM_TEST_NPROC=8 PLATFORM_TEST_MEMINFO="$mem16" HOSTQ_JOB_ID=x
auto_case "a nested runner uses 1" "jobs=1 docker_jobs=1 $base16 binding=nested files=6" 1 PLATFORM_TEST_NPROC=4 PLATFORM_TEST_MEMINFO="$mem16" PLATFORM_TEST_RUNNER=1
auto_case "an unreadable meminfo" "jobs=1 docker_jobs=1 cpus=4 mem_usable=n/a binding=probe-failed files=6 unreadable=$T_TMP/no-meminfo" 1 PLATFORM_TEST_NPROC=4 PLATFORM_TEST_MEMINFO="$T_TMP/no-meminfo"
printf 'MemTotal: lots kB\nMemAvailable: 5 kB\n' > "$T_TMP/bad-meminfo"
auto_case "a non-numeric meminfo value" "jobs=1 docker_jobs=1 cpus=4 mem_usable=n/a binding=probe-failed files=6 unreadable=$T_TMP/bad-meminfo" 1 PLATFORM_TEST_NPROC=4 PLATFORM_TEST_MEMINFO="$T_TMP/bad-meminfo"
auto_case "an unreadable nproc" "jobs=1 docker_jobs=1 cpus=n/a mem_usable=10444MiB binding=probe-failed files=6 unreadable=PLATFORM_TEST_NPROC" 1 PLATFORM_TEST_NPROC=abc PLATFORM_TEST_MEMINFO="$mem16"
auto_case "an explicit TEST_JOBS wins over auto" "jobs=2 docker_jobs=2 $base16 binding=override files=6" 2 PLATFORM_TEST_NPROC=4 PLATFORM_TEST_MEMINFO="$mem16" TEST_JOBS=2
auto_case "an explicit docker cap above an auto job count is clamped and printed" "jobs=2 docker_jobs=2 cpus=2 mem_usable=10444MiB binding=cpu files=6 docker_clamped=3->2" 2 PLATFORM_TEST_NPROC=2 PLATFORM_TEST_MEMINFO="$mem16" TEST_DOCKER_JOBS=3
# The outer-environment case: runner and hostq variables set outside, an explicit TEST_JOBS still wins.
auto_case "outer runner/hostq variables with an explicit TEST_JOBS" "jobs=3 docker_jobs=1 cpus=2 mem_usable=10444MiB binding=override files=6" 3 PLATFORM_TEST_NPROC=4 PLATFORM_TEST_MEMINFO="$mem16" PLATFORM_TEST_RUNNER=1 HOSTQ_JOB_ID=x HOSTQ_SLOTS=2 TEST_JOBS=3
# An invalid HOSTQ_SLOTS is probe-failed (1 job) before the nested and override rules.
for bad in abc 0 -1 ""; do
  auto_case "HOSTQ_SLOTS='$bad'" "jobs=1 docker_jobs=1 cpus=n/a mem_usable=n/a binding=probe-failed files=6 unreadable=HOSTQ_SLOTS" 1 PLATFORM_TEST_NPROC=4 PLATFORM_TEST_MEMINFO="$mem16" HOSTQ_JOB_ID=x HOSTQ_SLOTS="$bad"
done
auto_case "a bad HOSTQ_SLOTS ignores an explicit TEST_JOBS" "jobs=1 docker_jobs=1 cpus=n/a mem_usable=n/a binding=probe-failed files=6 unreadable=HOSTQ_SLOTS" 1 PLATFORM_TEST_NPROC=4 PLATFORM_TEST_MEMINFO="$mem16" HOSTQ_JOB_ID=x HOSTQ_SLOTS=abc TEST_JOBS=4
auto_case "a bad HOSTQ_SLOTS beats a nested runner" "jobs=1 docker_jobs=1 cpus=n/a mem_usable=n/a binding=probe-failed files=6 unreadable=HOSTQ_SLOTS" 1 PLATFORM_TEST_NPROC=4 PLATFORM_TEST_MEMINFO="$mem16" HOSTQ_JOB_ID=x HOSTQ_SLOTS=0 PLATFORM_TEST_RUNNER=1

# Admission: B is held while A runs and memory is low, A raises MemAvailable, then B starts; the hold prints once.
clear_tests
reset_probe
memlive="$T_TMP/memlive"
mk_mem 16384 1200 "$memlive"
rm -f "$C/mem_raised" "$C/b_early"
export memlive
fake platform/a/test_a.sh - 'sleep 1' 'touch "$C/mem_raised"' \
  "printf 'MemTotal: 16777216 kB\nMemAvailable: 8192000 kB\n' > \"\$memlive\"" 'sleep 1'
fake platform/b/test_b.sh - '[ -e "$C/mem_raised" ] || touch "$C/b_early"' 'exit 0'
run_cmd "${ENVU[@]}" env TEST_JOBS=2 TEST_DOCKER_JOBS=1 PLATFORM_TEST_NPROC=4 PLATFORM_TEST_MEMINFO="$memlive" bash "$R"
expect_rc "an admission-hold run passes" 0
expect_out_has "a low-memory reading holds the file" "run.sh: memory low (1200 MiB available), holding platform/b/test_b.sh"
held="$(grep -c 'memory low' <<<"$out")"
expect_eq "the hold is printed once" "$held" "1"
if [ -e "$C/b_early" ]; then _fail "the held file does not start before memory recovers"; else _pass; fi
expect_out_has "the held file runs after memory recovers" "== platform/b/test_b.sh ok "

# Low memory throughout never deadlocks: each file starts only when nothing runs, so the peak stays 1.
clear_tests
reset_probe
mk_mem 16384 100 "$memlive"
for n in 1 2 3; do probe_fake "platform/a/test_m$n.sh" - 0.3; done
run_cmd "${ENVU[@]}" env TEST_JOBS=2 TEST_DOCKER_JOBS=1 PLATFORM_TEST_NPROC=4 PLATFORM_TEST_MEMINFO="$memlive" bash "$R"
expect_rc "a permanently low-memory run still completes" 0
expect_out_has "the low-memory run holds files" "run.sh: memory low (100 MiB available), holding "
expect_out_lacks "no file fails under the hold" "FAIL"
pk="$(peak all)"
if [ "${pk:-0}" -eq 1 ]; then _pass; else _fail "held files run one at a time" "peak=${pk:-none}"; fi

# --- Invalid knobs fail closed before anything runs ---
clear_tests
fake platform/a/test_a.sh - "touch \"$T_TMP/ran\"" 'exit 0'
rm -f "$T_TMP/ran"
bad_knob() { # label, message-fragment, env assignments...
  local label="$1" frag="$2"
  shift 2
  run_cmd "${ENVU[@]}" env "$@" bash "$R"
  expect_rc "$label exits 2" 2
  expect_out_has "$label names the knob" "$frag"
  if [ -e "$T_TMP/ran" ]; then _fail "$label runs nothing" "a test file ran"; else _pass; fi
}
bad_knob "TEST_JOBS=0" "run.sh: TEST_JOBS must be auto or 1-64, got '0'" TEST_JOBS=0
bad_knob "TEST_JOBS=65" "run.sh: TEST_JOBS must be auto or 1-64, got '65'" TEST_JOBS=65
bad_knob "TEST_JOBS=abc" "run.sh: TEST_JOBS must be auto or 1-64, got 'abc'" TEST_JOBS=abc
bad_knob "TEST_DOCKER_JOBS=0" "run.sh: TEST_DOCKER_JOBS must be auto or 1-64, got '0'" TEST_DOCKER_JOBS=0
bad_knob "an explicit docker cap above an explicit job count" "TEST_DOCKER_JOBS (3) must not exceed TEST_JOBS (2)" TEST_JOBS=2 TEST_DOCKER_JOBS=3
bad_knob "TEST_FILE_TIMEOUT=0" "run.sh: TEST_FILE_TIMEOUT must be 1-3600, got '0'" TEST_FILE_TIMEOUT=0
bad_knob "TEST_FILE_TIMEOUT=3601" "run.sh: TEST_FILE_TIMEOUT must be 1-3600, got '3601'" TEST_FILE_TIMEOUT=3601
bad_knob "TEST_FILE_TIMEOUT=abc" "run.sh: TEST_FILE_TIMEOUT must be 1-3600, got 'abc'" TEST_FILE_TIMEOUT=abc

# An unknown marker value is a run-time error naming the file, and nothing runs.
fake platform/b/test_bad.sh bogus 'exit 0'
run_cmd "${ENVU[@]}" bash "$R"
expect_rc "an unknown class exits 2" 2
expect_out_has "an unknown class names the file" "platform/b/test_bad.sh"
if [ -e "$T_TMP/ran" ]; then _fail "an unknown class runs nothing" "a test file ran"; else _pass; fi
rm -f "$S/platform/b/test_bad.sh"

# --- Timeouts ---
clear_tests
fake platform/a/test_slow.sh - 'sleep 30'
fake platform/a/test_after.sh - 'exit 0'
run_cmd "${ENVU[@]}" env TEST_FILE_TIMEOUT=1 bash "$R"
expect_rc "a timed-out file fails the run" 1
expect_out_has "a sleeping file past the timeout is reported" "== platform/a/test_slow.sh FAIL timeout after 1s"
expect_out_has "the run continues after a timeout" "== platform/a/test_after.sh ok "

# A file that ignores TERM is KILLed after the grace; nothing is left behind.
clear_tests
rm -f "$C/ign.pid"
fake platform/a/test_ign.sh - "trap '' TERM" "echo \$\$ > \"\$C/ign.pid\"" 'while :; do sleep 0.2; done'
fake platform/a/test_after.sh - 'exit 0'
start="$SECONDS"
run_cmd "${ENVU[@]}" env TEST_FILE_TIMEOUT=1 PLATFORM_TEST_KILL_GRACE=1 bash "$R"
elapsed=$((SECONDS - start))
expect_rc "a TERM-ignoring file fails the run" 1
expect_out_has "a TERM-ignoring file is reported as a timeout" "== platform/a/test_ign.sh FAIL timeout after 1s"
expect_out_has "the run continues after a KILL" "== platform/a/test_after.sh ok "
if [ "$elapsed" -le 15 ]; then _pass; else _fail "the KILL lands after the short grace" "took ${elapsed}s"; fi
ign="$(cat "$C/ign.pid" 2>/dev/null)"
if [ -n "$ign" ] && gone "$ign"; then _pass; else _fail "no TERM-ignoring process is left behind" "pid=$ign"; fi

# The default grace is 20 s: strictly below hostq's TimeoutStopSec=30.
if grep -qE '^grace=20$' "$here/run.sh"; then _pass; else _fail "the default kill grace is 20 (must stay below 30)"; fi

# --- Signals: a TERM to the runner reaches the running file, whose trap runs; nothing is left ---
clear_tests
rm -f "$C/term" "$C/started" "$C/sig.pid"
fake platform/a/test_sig.sh - "trap 'echo t > \"\$C/term\"; exit 0' TERM" "echo \$\$ > \"\$C/sig.pid\"" \
  'touch "$C/started"' 'sleep 30 & wait'
"${ENVU[@]}" bash "$R" > "$T_TMP/sig.out" 2>&1 &
rpid=$!
if wait_file "$C/started"; then _pass; else _fail "the signal fixture file started"; fi
kill -TERM "$rpid"
wait "$rpid"
rrc=$?
expect_eq "a TERM to the runner exits 143" "$rrc" "143"
if wait_file "$C/term"; then _pass; else _fail "the file's TERM trap ran"; fi
sig="$(cat "$C/sig.pid" 2>/dev/null)"
if [ -n "$sig" ] && gone "$sig"; then _pass; else _fail "no fake-file process remains after TERM" "pid=$sig"; fi

# The same with a file that ignores TERM: the runner escalates to KILL after the grace.
clear_tests
rm -f "$C/started" "$C/ign.pid"
fake platform/a/test_ign.sh - "trap '' TERM" "echo \$\$ > \"\$C/ign.pid\"" 'touch "$C/started"' 'while :; do sleep 0.2; done'
"${ENVU[@]}" env PLATFORM_TEST_KILL_GRACE=1 bash "$R" > "$T_TMP/sig.out" 2>&1 &
rpid=$!
if wait_file "$C/started"; then _pass; else _fail "the TERM-ignoring fixture started"; fi
kill -TERM "$rpid"
wait "$rpid"
rrc=$?
expect_eq "a TERM to the runner exits 143 after escalation" "$rrc" "143"
ign="$(cat "$C/ign.pid" 2>/dev/null)"
if [ -n "$ign" ] && gone "$ign"; then _pass; else _fail "the TERM-ignoring file is KILLed on the signal path" "pid=$ign"; fi

# --- Signals during prewarm: a TERM stops prewarm's whole process group (child included) and exits 143 ---
clear_tests
rm -f "$C/pw.started" "$C/pw.pid" "$C/pw.child" "$C/ran"
fake platform/a/test_d.sh docker 'touch "$C/ran"'
printf '%s\n' '#!/usr/bin/env bash' 'echo $$ > "$C/pw.pid"' 'sleep 30 &' 'echo $! > "$C/pw.child"' 'touch "$C/pw.started"' 'wait' \
  > "$S/platform/test/prewarm.sh"
"${ENVU[@]}" bash "$R" > "$T_TMP/pw.out" 2>&1 &
rpid=$!
if wait_file "$C/pw.started"; then _pass; else _fail "the fake prewarm started"; fi
kill -TERM "$rpid"
wait "$rpid"
rrc=$?
expect_eq "a TERM during prewarm exits 143" "$rrc" "143"
pwp="$(cat "$C/pw.pid" 2>/dev/null)"
pwc="$(cat "$C/pw.child" 2>/dev/null)"
if [ -n "$pwp" ] && gone "$pwp"; then _pass; else _fail "the prewarm process is gone after TERM" "pid=$pwp"; fi
if [ -n "$pwc" ] && gone "$pwc"; then _pass; else _fail "prewarm's child is gone after TERM" "pid=$pwc"; fi
if [ ! -e "$C/ran" ]; then _pass; else _fail "no test file ran after a TERM during prewarm"; fi
rm -f "$S/platform/test/prewarm.sh"

# --- Log dir ---
clear_tests
fake platform/a/test_a.sh - 'exit 0'
fake platform/b/test_b.sh - 'echo from-b' 'exit 1'
mkdir -p "$T_TMP/tmpd"
run_cmd "${ENVU[@]}" env TMPDIR="$T_TMP/tmpd" bash "$R" platform/a/test_a.sh
expect_rc "an all-pass run passes" 0
expect_out_lacks "an all-pass run without TEST_LOG_DIR names no log dir" "logs in"
if [ -z "$(ls -A "$T_TMP/tmpd")" ]; then _pass; else _fail "the log dir is removed after an all-pass run"; fi

run_cmd "${ENVU[@]}" env TMPDIR="$T_TMP/tmpd" bash "$R"
expect_rc "a failing run fails" 1
expect_out_has "a failing run names its log dir" "run.sh: logs in $T_TMP/tmpd/"
if ls "$T_TMP"/tmpd/*/platform__b__test_b.sh.log > /dev/null 2>&1; then _pass; else _fail "the failing run's log is kept as <path with / as __>.log"; fi

run_cmd "${ENVU[@]}" env TEST_LOG_DIR="$T_TMP/logs" bash "$R" platform/a/test_a.sh
expect_rc "an all-pass run with TEST_LOG_DIR passes" 0
expect_out_has "TEST_LOG_DIR is kept and named" "run.sh: logs in $T_TMP/logs"
if [ -e "$T_TMP/logs/platform__a__test_a.sh.log" ]; then _pass; else _fail "TEST_LOG_DIR holds the log"; fi

# --- No files ---
clear_tests
run_cmd "${ENVU[@]}" bash "$R"
expect_rc "no files gives rc 1" 1
expect_out_has "no files is named" "no test_*.sh found"

t_finish
