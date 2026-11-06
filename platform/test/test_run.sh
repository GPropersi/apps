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

# Every scratch run starts from a clean slate of outer runner/hostq/knob variables; each case sets only what it needs.
ENVU=(env -u PLATFORM_TEST_RUNNER -u HOSTQ_JOB_ID -u HOSTQ_SLOTS -u TEST_JOBS -u TEST_DOCKER_JOBS -u TEST_VERBOSE
  -u TEST_LOG_DIR -u TEST_FILE_TIMEOUT -u PLATFORM_TEST_KILL_GRACE -u PLATFORM_TEST_NPROC -u PLATFORM_TEST_MEMINFO
  -u PLATFORM_TEST_CGROUP_DIR -u PLATFORM_TEST_CGROUP_FILE -u PLATFORM_TEST_CGROUP_ROOT)

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

run_cmd "${ENVU[@]}" bash "$R" apps/foo/test_c.sh platform/a/test_a.sh
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
run_cmd "${ENVU[@]}" bash "$R" platform/a/test_m1.sh platform/a/test_m2.sh platform/a/test_h1.sh platform/a/test_d1.sh
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
run_cmd "${ENVU[@]}" env TEST_DOCKER_JOBS=3 bash "$R"
expect_rc "an explicit docker cap above a defaulted job count is clamped" 0
pd="$(peak docker)"
if [ "${pd:-0}" -eq 1 ]; then _pass; else _fail "the clamped run is serial" "peak=${pd:-none}"; fi

# The outer runner/hostq variables do not change the expected concurrency.
clear_tests
reset_probe
for n in 1 2 3 4; do probe_fake "platform/a/test_m$n.sh" - 0.5; done
run_cmd env PLATFORM_TEST_RUNNER=1 HOSTQ_JOB_ID=x HOSTQ_SLOTS=2 TEST_JOBS=3 bash "$R"
expect_rc "a run inside a runner and a hostq job passes" 0
p="$(peak all)"
if [ "${p:-0}" -le 3 ] && [ "${p:-0}" -ge 2 ]; then _pass; else _fail "outer runner/hostq variables do not change concurrency" "peak=${p:-none}"; fi

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
bad_knob "TEST_JOBS=0" "run.sh: TEST_JOBS must be 1-64, got '0'" TEST_JOBS=0
bad_knob "TEST_JOBS=65" "run.sh: TEST_JOBS must be 1-64, got '65'" TEST_JOBS=65
bad_knob "TEST_JOBS=abc" "run.sh: TEST_JOBS must be 1-64, got 'abc'" TEST_JOBS=abc
bad_knob "TEST_DOCKER_JOBS=0" "run.sh: TEST_DOCKER_JOBS must be 1-64, got '0'" TEST_DOCKER_JOBS=0
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
