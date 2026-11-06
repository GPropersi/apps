#!/usr/bin/env bash
# Contract tests for prewarm.sh and for how run.sh calls it, with PATH-stub docker and go and no network: a failing pull or
# a failing go-env.sh is logged and never fails the run, the set of pulled references is exactly what the compose files
# and Dockerfiles pin, an image that is already present is not pulled, and run.sh calls prewarm only for the targets the
# selected files need (and not at all without a prewarm.sh, or inside a nested runner).
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh. SC2016: the stub bodies are
# single-quoted on purpose.
# shellcheck disable=SC1091,SC2154,SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
. "$here/lib.sh"
# shellcheck source=../lib/yaml-subset.sh
. "$here/../lib/yaml-subset.sh"
jobs_dir="$here/../jobs"
data_dir="$here/../data"
ingress_dir="$here/../ingress"

t_init

# Every scratch run starts from a clean slate of outer runner/hostq/knob variables (the Step 4 environment clearing).
ENVU=(env -u PLATFORM_TEST_RUNNER -u HOSTQ_JOB_ID -u HOSTQ_SLOTS -u TEST_JOBS -u TEST_DOCKER_JOBS -u TEST_VERBOSE
  -u TEST_LOG_DIR -u TEST_FILE_TIMEOUT -u PLATFORM_TEST_KILL_GRACE -u PLATFORM_TEST_NPROC -u PLATFORM_TEST_MEMINFO
  -u PLATFORM_TEST_CGROUP_DIR -u PLATFORM_TEST_CGROUP_FILE -u PLATFORM_TEST_CGROUP_ROOT)

# --- The expected image set, read from the real files ---
expected="$T_TMP/expected"
: > "$expected"
for d in "$data_dir" "$jobs_dir" "$ingress_dir"; do
  flat="$T_TMP/flat.tsv"
  ys_flatten < "$d/compose.yaml" > "$flat"
  for svc in $(ys_children "$flat" services); do
    ref="$(ys_get "$flat" "services/$svc/image")"
    case "$ref" in *'$'*) ;; *) printf '%s\n' "$ref" >> "$expected" ;; esac
  done
done
grep -h '^FROM ' "$jobs_dir/Dockerfile" "$jobs_dir/Dockerfile.testapp" | awk '{print $2}' >> "$expected"
LC_ALL=C sort -u -o "$expected" "$expected"
if [ "$(wc -l < "$expected")" -ge 5 ]; then _pass; else _fail "the expected image set was read" "got: $(cat "$expected")"; fi

# --- A scratch tree with the real prewarm.sh, run.sh and the files prewarm reads ---
S="$T_TMP/repo"
mkdir -p "$S/platform/test" "$S/platform/lib" "$S/platform/data" "$S/platform/jobs" "$S/platform/ingress" "$S/apps"
cp -- "$here/run.sh" "$here/prewarm.sh" "$S/platform/test/"
cp -- "$here/../lib/yaml-subset.sh" "$S/platform/lib/"
cp -- "$data_dir/compose.yaml" "$S/platform/data/"
cp -- "$ingress_dir/compose.yaml" "$S/platform/ingress/"
cp -- "$jobs_dir/compose.yaml" "$jobs_dir/Dockerfile" "$jobs_dir/Dockerfile.testapp" "$jobs_dir/go-env.sh" "$jobs_dir/GO_VERSION" "$S/platform/jobs/"
R="$S/platform/test/run.sh"

PRESENT="$T_TMP/present"
: > "$PRESENT"
export PRESENT

# A docker stub: info and image inspect are configurable, pull always fails with an error text, every call is logged.
cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
# One write per call: prewarm pulls 3 at a time, and separate appends would interleave their pieces.
printf 'docker %s\n' "$*" >> "$CALL_LOG"
case "$1" in
  info) [ -z "${STUB_DOCKER_INFO_FAIL:-}" ] || { echo "Cannot connect to the Docker daemon" >&2; exit 1; } ;;
  image) grep -qxF -- "$3" "$PRESENT" ;;
  pull) echo "Error response from daemon: pull access denied for $2" >&2; exit 1 ;;
esac
EOF
# A go stub that resolves a version no GO_VERSION file names, so go-env.sh returns 1.
cat > "$STUB_BIN/go" <<'EOF'
#!/usr/bin/env bash
printf 'go %s\n' "$*" >> "$CALL_LOG"
echo "go version go0.0.1 linux/amd64"
EOF
chmod +x "$STUB_BIN/docker" "$STUB_BIN/go"

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
clear_tests() { rm -f "$S"/platform/*/test_*.sh "$S"/apps/*/test_*.sh; }

# pulled: the references the docker stub was asked to pull, sorted.
pulled() { grep '^docker pull ' "$CALL_LOG" | awk '{print $3}' | LC_ALL=C sort -u; }

# --- prewarm.sh itself: failing pulls and a failing go are logged, never fatal ---
first_ref="$(head -n 1 "$expected")"
printf '%s\n' "$first_ref" > "$PRESENT"
t_reset_calls
run_cmd "${ENVU[@]}" bash "$S/platform/test/prewarm.sh" images go
expect_rc "prewarm exits 0 although every pull and go-env fail" 0
expect_eq "the pulled set is the compose and Dockerfile set minus the present image" "$(pulled)" "$(grep -vxF -- "$first_ref" "$expected")"
expect_calls_lacks "a present image is not pulled" "docker pull $first_ref"
last_ref="$(tail -n 1 "$expected")"
expect_out_has "a failed pull is logged with its rc" "prewarm: $last_ref rc=1 "
expect_out_has "a failed pull is logged with the error text" "pull access denied for $last_ref"
expect_out_has "a failed go warm is logged with its rc" "prewarm: go rc=1 "
expect_out_has "a failed go warm is logged with the go-env error text" "go-env: go version mismatch"
expect_out_lacks "a runner image built locally is never pulled" 'RUNNER_TAG'

# Docker unreachable: nothing is pulled and the skip is logged.
t_reset_calls
run_cmd "${ENVU[@]}" env STUB_DOCKER_INFO_FAIL=1 bash "$S/platform/test/prewarm.sh" images
expect_rc "prewarm exits 0 when docker info fails" 0
expect_out_has "an unreachable docker is logged" "prewarm: images rc=0"
expect_out_has "the docker info error is logged" "Cannot connect to the Docker daemon"
expect_eq "no pull is attempted when docker info fails" "$(pulled)" ""

# Go only: no docker call at all.
t_reset_calls
run_cmd "${ENVU[@]}" bash "$S/platform/test/prewarm.sh" go
expect_rc "the go target alone exits 0" 0
expect_calls_lacks "the go target makes no docker call" "docker"

# An unknown target is ignored, still rc 0.
run_cmd "${ENVU[@]}" bash "$S/platform/test/prewarm.sh" bogus
expect_rc "an unknown target exits 0" 0

# --- run.sh with the real prewarm.sh: failures never stop the run ---
clear_tests
fake platform/test/test_dock.sh docker 'echo dock-ran' 'exit 0'
fake platform/test/test_mock.sh - 'echo mock-ran' 'exit 0'
t_reset_calls
run_cmd "${ENVU[@]}" bash "$R" platform/test/test_dock.sh platform/test/test_mock.sh
expect_rc "run.sh passes although prewarm failed on every item" 0
expect_out_has "the docker file still ran" "== platform/test/test_dock.sh ok "
expect_out_has "the mocked file still ran" "== platform/test/test_mock.sh ok "
expect_out_has "the prewarm failure is in the run output" "prewarm: go rc=1 "
expect_out_has "the summary has a prewarm line" "-- prewarm "
expect_eq "run.sh pulled exactly the expected set" "$(pulled)" "$(grep -vxF -- "$first_ref" "$expected")"

# --- run.sh target selection, with a prewarm.sh that only records its arguments ---
printf '#!/usr/bin/env bash\necho "prewarm $*" >> "$CALL_LOG"\n' > "$S/platform/test/prewarm.sh"

prewarm_calls() { grep '^prewarm ' "$CALL_LOG" | paste -sd'|' -; }

clear_tests
fake platform/test/test_a.sh - 'exit 0'
fake platform/test/test_b.sh - 'echo "no go here"' 'exit 0'
t_reset_calls
run_cmd "${ENVU[@]}" bash "$R"
expect_rc "a mocked-only selection runs" 0
expect_eq "a mocked-only selection with no Go use makes no prewarm call" "$(prewarm_calls)" ""
expect_out_lacks "no prewarm summary line without a call" "-- prewarm "

clear_tests
fake platform/test/test_a.sh - 'exit 0'
fake platform/test/test_g.sh - '# uses platform/jobs/go-env.sh' 'exit 0'
t_reset_calls
run_cmd "${ENVU[@]}" bash "$R"
expect_eq "a mocked file that sources go-env.sh triggers only go" "$(prewarm_calls)" "prewarm go"
expect_out_has "the prewarm summary line names the target" "-- prewarm "

clear_tests
fake platform/test/test_c.sh - '# runs platform/lint/check-go.sh' 'exit 0'
t_reset_calls
run_cmd "${ENVU[@]}" bash "$R"
expect_eq "a mocked file that runs check-go.sh triggers only go" "$(prewarm_calls)" "prewarm go"

clear_tests
fake platform/test/test_h.sh heavy 'exit 0'
t_reset_calls
run_cmd "${ENVU[@]}" bash "$R"
expect_eq "a heavy file triggers go, never images" "$(prewarm_calls)" "prewarm go"

clear_tests
fake platform/test/test_d.sh docker 'exit 0'
fake platform/test/test_a.sh - 'exit 0'
t_reset_calls
run_cmd "${ENVU[@]}" bash "$R"
expect_eq "a docker file triggers images and go" "$(prewarm_calls)" "prewarm images go"

t_reset_calls
run_cmd "${ENVU[@]}" env PLATFORM_TEST_RUNNER=1 bash "$R"
expect_eq "a nested runner makes no prewarm call" "$(prewarm_calls)" ""

rm -f "$S/platform/test/prewarm.sh"
t_reset_calls
run_cmd "${ENVU[@]}" bash "$R"
expect_rc "a tree with no prewarm.sh still runs" 0
expect_out_has "the docker file runs without prewarm.sh" "== platform/test/test_d.sh ok "
expect_eq "a tree with no prewarm.sh makes no call" "$(prewarm_calls)" ""

t_finish
