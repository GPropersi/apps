#!/usr/bin/env bash
# Offline tests for backup.sh (Step 1 framework: env, lock, logging, notify, state file, window, deadline).
# Every case runs backup.sh SOURCED in a fresh real bash (so set -e and the traps behave as in production) with the
# shared PLATFORM_BACKUP_* overrides pointing into a per-case temp dir, stubs for restic, docker and curl on PATH,
# and a stubbed clock (now_epoch, now_hhmm, window_file) injected through the BASH_SOURCE source guard. The deadline,
# clamp and TERM/INT cases drive the real timed/phase runner with test-only dummy phases (PHASES is replaced in the
# case body; no dummy phase ships in backup.sh). The lock is the real flock.
#
# No real credentials: every secret below is a fake marker string.
# SC2016: stub and case bodies are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# SC2154: $out and $rc are set by run_cmd in lib.sh. SC2034: some fixture variables are only read by sub-functions.
# shellcheck disable=SC1091,SC2016,SC2034,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
SCRIPT="$here/backup.sh"
export SCRIPT

t_init

if command -v flock > /dev/null 2>&1; then _pass; else _fail "flock is available for the lock tests"; fi
HAVE_PY=1
if ! command -v python3 > /dev/null 2>&1; then
  HAVE_PY=0
  if [ "${REQUIRE_DOCKER:-}" = "1" ]; then _fail "python3 is available (REQUIRE_DOCKER=1)"; else echo "SKIP: python3 absent, JSON parser check skipped"; fi
fi

PW_SECRET='Pw+/=Zq9xSecretMarker'
AWS_SECRET='sk+/=testsecretmarker0002'
HOOK_SECRET='https://discord.example.test/api/webhooks/111/tokenmarker'

# ---- stubs ----

# curl: logs argv, copies the --data-binary @file payload and the -K config for inspection, and fails (exit 22,
# stderr from $CASE_DIR/curl.fail) when that file exists.
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl' >> "$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
prev=""
for a in "$@"; do
  case "$a" in @*) cp "${a#@}" "$CASE_DIR/payload.json" ;; esac
  if [ "$prev" = "-K" ]; then cp "$a" "$CASE_DIR/curl.cfg"; fi
  prev="$a"
done
if [ -f "$CASE_DIR/curl.fail" ]; then cat "$CASE_DIR/curl.fail" >&2; exit 22; fi
exit 0
EOF
chmod +x "$STUB_BIN/curl"

# restic: logs argv, records the password it saw, prints an error containing secrets and exits 1.
cat > "$STUB_BIN/restic" <<'EOF'
#!/usr/bin/env bash
printf 'restic' >> "$CALL_LOG"
for a in "$@"; do printf ' %s' "$a" >> "$CALL_LOG"; done
printf '\n' >> "$CALL_LOG"
printf '%s' "$RESTIC_PASSWORD" > "$CASE_DIR/restic-saw"
echo "Fatal: wrong password $RESTIC_PASSWORD for repo $RESTIC_REPOSITORY using key $AWS_SECRET_ACCESS_KEY id $AWS_ACCESS_KEY_ID" >&2
exit 1
EOF
chmod +x "$STUB_BIN/restic"
t_stub docker 0

# ---- per-case fixtures ----

ncase=0
mkenv() { # [skip-key...]: a complete valid backup.env minus the named keys
  local f="$C/backup.env" kv key skip
  : > "$f"
  for kv in \
    "RESTIC_REPOSITORY=s3:https://acct.example.test/bucket" \
    "RESTIC_PASSWORD=$PW_SECRET" \
    "AWS_ACCESS_KEY_ID=TESTKEYIDMARKER0001" \
    "AWS_SECRET_ACCESS_KEY=$AWS_SECRET" \
    "AWS_DEFAULT_REGION=auto" \
    "DISCORD_WEBHOOK=$HOOK_SECRET"; do
    key="${kv%%=*}"
    for skip in "$@"; do if [ "$key" = "$skip" ]; then continue 2; fi; done
    printf '%s\n' "$kv" >> "$f"
  done
  chmod 600 "$f"
}

new_case() {
  ncase=$((ncase + 1))
  C="$T_TMP/case$ncase"
  mkdir -p "$C"
  t_reset_calls
  export C CASE_DIR="$C" CLK="$C/clock" HHMM="$C/hhmm" WINF="$C/window.env"
  export PLATFORM_BACKUP_ENV_FILE="$C/backup.env"
  OWNER_NOW="$(id -u):$(id -g)"
  export PLATFORM_BACKUP_ENV_OWNER="$OWNER_NOW"
  export PLATFORM_BACKUP_ROOT="$C/root"
  export PLATFORM_BACKUP_STATE_DIR="$C/status"
  export PLATFORM_BACKUP_LOG_DIR="$C/logs"
  export PLATFORM_BACKUP_LOCK="$C/lock"
  export PLATFORM_BACKUP_SECRETS_ROOT="$C/secrets"
  export PLATFORM_BACKUP_PG_ADMIN_FILE="$C/pg.pw"
  export PLATFORM_BACKUP_REDIS_ADMIN_FILE="$C/redis.pw"
  unset PLATFORM_BACKUP_DEADLINE_SECS PLATFORM_BACKUP_PG_CONTAINER PLATFORM_BACKUP_REDIS_CONTAINER
  export ADV_TO=1000 HHMM_TO=04:00
  printf '1000' > "$CLK"
  printf '04:00' > "$HHMM"
  printf 'BACKUP_WINDOW_START=03:30\nBACKUP_WINDOW_END=05:00\nBACKUP_WINDOW_TZ=America/Chicago\n' > "$WINF"
  mkenv
}

PRELUDE="$(
  cat <<'EOF'
now_epoch() { cat "$CLK"; }
now_hhmm() { cat "$HHMM"; }
window_file() { printf '%s' "$WINF"; }
ph_ok() { timed ph_ok 10 true; }
ph_adv() { printf '%s' "$ADV_TO" > "$CLK"; }
ph_never() { : > "$C/never-ran"; }
ph_slow() { timed ph_slow 60 sleep 30; }
ph_selfkill() { kill -TERM "$BASHPID"; sleep 2; }
ph_restic() { timed ph_restic 10 restic backup; }
ph_clamp() { timed ph_clamp 600 sleep 5; }
ph_noclamp() { timed ph_noclamp 60 true; }
ph_fastclamp() { timed ph_fastclamp 600 true; }
ph_hhmm() { printf '%s' "$HHMM_TO" > "$HHMM"; }
ph_dump() { printf '%s' "$RESTIC_PASSWORD" > "$C/pw"; }
EOF
)"
export PRELUDE

# run_case <body>: backup.sh sourced into a fresh bash, then the body (usually "PHASES=(...); main nightly").
run_case() {
  rc=0
  out="$(env CASE_BODY="$1" bash -c '. "$SCRIPT"; eval "$PRELUDE"; eval "$CASE_BODY"' 2>&1)" || rc=$?
}

# run_bg <body>: the same in the background (job control on, so INT is not ignored); sets BGPID, output in $C/bg.out.
run_bg() {
  set -m
  env CASE_BODY="$1" bash -c '. "$SCRIPT"; eval "$PRELUDE"; eval "$CASE_BODY"' > "$C/bg.out" 2>&1 &
  BGPID=$!
  set +m
}

wait_for_text() { # <file> <fixed-string>
  local i
  for i in $(seq 1 100); do
    if grep -qF -- "$2" "$1" 2> /dev/null; then return 0; fi
    sleep 0.1
  done
  return 1
}

state() { awk -F'\t' -v n="$1" '{print $n}' "$C/status/last-run.tsv" 2> /dev/null; }
ncurl() { grep -c '^curl ' "$CALL_LOG" || true; }
payload() { cat "$C/payload.json" 2> /dev/null || true; }
logtext() { cat "$C"/logs/*.log 2> /dev/null || true; }
expect_absent() { if [ ! -e "$2" ]; then _pass; else _fail "$1" "unexpectedly exists: $2"; fi; }
expect_present() { if [ -e "$2" ]; then _pass; else _fail "$1" "missing: $2"; fi; }
expect_absent_or_empty() { if [ ! -s "$2" ]; then _pass; else _fail "$1" "not empty: $2"; fi; }
expect_text_has() { # <label> <text> <fixed>
  if grep -qF -- "$3" <<< "$2"; then _pass; else _fail "$1" "lacks: $3"; fi
}
expect_text_lacks() { # <label> <text> <fixed>
  if grep -qF -- "$3" <<< "$2"; then _fail "$1" "unexpectedly has: $3"; else _pass; fi
}

# ---------------------------------------------------------------------------------------------------------------
# 0. Source guard, usage, positive baseline
new_case
run_case 'echo sourced-ok'
expect_rc "sourcing runs no main" 0
expect_out_has "sourcing prints only the case output" "sourced-ok"
expect_out_lacks "sourcing starts no run" "run start"
expect_absent "sourcing writes no state" "$C/status/last-run.tsv"

run_case 'main'
expect_rc "no mode is a usage error" 2
run_case 'main bogus'
expect_rc "unknown mode is a usage error" 2

new_case
run_case 'PHASES=(ph_ok); main nightly'
expect_rc "clean nightly run with one phase" 0
expect_eq "state result ok" "$(state 3)" "ok"
expect_eq "state snapshot is - when empty" "$(state 4)" "-"
expect_eq "state failed_phase is - when empty" "$(state 5)" "-"
if [[ "$(state 1)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && [[ "$(state 2)" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then _pass; else _fail "state times are ISO-8601 Z"; fi
expect_eq "one success notify" "$(ncurl)" "1"
expect_out_has "phase start logged" "phase=ph_ok start timeout=10s"
expect_out_has "phase end logged with rc and duration" "phase=ph_ok end rc=0 dur="
expect_eq "dated log file holds the same run" "$(grep -c 'run start mode=nightly' <<< "$(logtext)")" "1"
expect_eq "log dir mode 0750" "$(stat -c %a "$C/logs")" "750"
expect_eq "log file mode 0640" "$(stat -c %a "$C"/logs/*.log)" "640"
expect_eq "state dir mode 0755" "$(stat -c %a "$C/status")" "755"
expect_eq "state file mode 0644" "$(stat -c %a "$C/status/last-run.tsv")" "644"
expect_absent "state is not under the 0700 backup root" "$C/root/last-run.tsv"
expect_calls_has "curl is the webhook path" "curl -fsS --max-time 30"
expect_calls_lacks "webhook URL never on argv" "tokenmarker"
if grep -qF "tokenmarker" "$C/curl.cfg"; then _pass; else _fail "webhook URL reaches curl through the config file"; fi

# ---------------------------------------------------------------------------------------------------------------
# 1. Missing keys
new_case
mkenv RESTIC_PASSWORD
run_case 'PHASES=(ph_never); main nightly'
expect_rc "missing key exits 2" 2
expect_out_has "message names the missing key" "FATAL: missing required env var(s): RESTIC_PASSWORD"
expect_eq "state failed" "$(state 3)" "failed"
expect_eq "state failed_phase=env" "$(state 5)" "env"
expect_eq "no webhook call" "$(ncurl)" "0"
expect_absent_or_empty "no stub is called on an env failure" "$CALL_LOG"
expect_absent "no phase runs after an env failure" "$C/never-ran"

new_case
mkenv RESTIC_REPOSITORY DISCORD_WEBHOOK
run_case 'main nightly'
expect_rc "two missing keys exit 2" 2
expect_out_has "message lists every missing key" "FATAL: missing required env var(s): RESTIC_REPOSITORY DISCORD_WEBHOOK"

new_case
mkenv RESTIC_PASSWORD
rc=0
out="$(RESTIC_PASSWORD=fromcaller env CASE_BODY='main nightly' bash -c '. "$SCRIPT"; eval "$PRELUDE"; eval "$CASE_BODY"' 2>&1)" || rc=$?
expect_rc "the caller's environment never supplies a key" 2
expect_out_has "caller-supplied key still reported missing" "RESTIC_PASSWORD"

new_case
run_case 'main nightly'
expect_rc "positive control: complete env accepted" 0
expect_eq "positive control: webhook called on success" "$(ncurl)" "1"

# ---------------------------------------------------------------------------------------------------------------
# 2. Literal reader
new_case
marker="$C/marker"
{
  printf '# comment line\n\n'
  printf 'RESTIC_REPOSITORY=s3:https://acct.example.test/bucket\n'
  printf 'RESTIC_PASSWORD=a=b/c+d$(touch %s)`touch %s.bt`\n' "$marker" "$marker"
  printf 'AWS_ACCESS_KEY_ID=TESTKEYIDMARKER0001\nAWS_SECRET_ACCESS_KEY=%s\nAWS_DEFAULT_REGION=auto\nDISCORD_WEBHOOK=%s\n' "$AWS_SECRET" "$HOOK_SECRET"
} > "$C/backup.env"
chmod 600 "$C/backup.env"
run_case 'PHASES=(ph_dump); main nightly'
expect_rc "literal reader accepts =, /, +, \$( and backticks in a value" 0
expect_absent "planted \$(...) substitution did not execute" "$marker"
expect_absent "planted backtick substitution did not execute" "$marker.bt"
expect_eq "value passes through byte-exact (split at first =)" "$(cat "$C/pw")" "a=b/c+d\$(touch $marker)\`touch $marker.bt\`"

new_case
ln -s "$C/real.env" "$C/linked.env"
mkenv
mv "$C/backup.env" "$C/real.env"
chmod 600 "$C/real.env"
export PLATFORM_BACKUP_ENV_FILE="$C/linked.env"
run_case 'main nightly'
expect_rc "symlinked env file refused" 2
expect_eq "symlink: failed_phase=env" "$(state 5)" "env"
expect_eq "symlink: no webhook" "$(ncurl)" "0"

new_case
chmod 640 "$C/backup.env"
run_case 'main nightly'
expect_rc "mode 0640 refused" 2
expect_eq "mode: failed_phase=env" "$(state 5)" "env"
chmod 600 "$C/backup.env"
run_case 'main nightly'
expect_rc "positive control: mode 0600 accepted" 0

new_case
if [ "$(id -u):$(id -g)" = "0:0" ]; then
  if [ "${REQUIRE_DOCKER:-}" = "1" ]; then _fail "unset-owner refusal is exercisable (running as 0:0 under REQUIRE_DOCKER=1)"; else echo "SKIP: running as 0:0, the unset-owner refusal cannot be exercised"; fi
else
  unset PLATFORM_BACKUP_ENV_OWNER
  run_case 'main nightly'
  expect_rc "owner unset: a file owned by another user is refused" 2
  expect_out_has "owner refusal names the expected owner" "owner is not 0:0"
fi
for bad in "abc" "1:" "" "1:2:3" "root:root"; do
  new_case
  export PLATFORM_BACKUP_ENV_OWNER="$bad"
  run_case 'main nightly'
  expect_rc "malformed PLATFORM_BACKUP_ENV_OWNER '$bad' exits 2" 2
done
new_case
wrong_owner="$(($(id -u) + 1)):$(id -g)"
export PLATFORM_BACKUP_ENV_OWNER="$wrong_owner"
run_case 'main nightly'
expect_rc "owner set to a wrong uid:gid is refused" 2
expect_out_has "wrong-owner refusal names the owner check" "owner is not $PLATFORM_BACKUP_ENV_OWNER"
expect_eq "wrong owner: failed_phase=env" "$(state 5)" "env"
new_case
run_case 'main nightly'
expect_rc "owner set to the file's real uid:gid is accepted" 0

# ---------------------------------------------------------------------------------------------------------------
# 3. Grammar
bad_lines=('RESTIC_PASSWORD="quoted"' "RESTIC_PASSWORD='quoted'" 'NOT_A_KEY=1' 'RESTIC_PASSWORD=dup' 'novalueline' $'RESTIC_REPOSITORY=has-cr\r')
bad_labels=("leading double quote" "leading single quote" "unknown key" "duplicate key" "line without =" "CR in a value")
bad_msgs=("value for RESTIC_PASSWORD starts with a quote" "value for RESTIC_PASSWORD starts with a quote" "has an unknown key" "repeats key RESTIC_PASSWORD" "has no =" "contains a CR")
for i in "${!bad_lines[@]}"; do
  new_case
  mkenv
  if [ "${bad_labels[$i]}" = "leading double quote" ] || [ "${bad_labels[$i]}" = "leading single quote" ]; then mkenv RESTIC_PASSWORD; fi
  if [ "${bad_labels[$i]}" = "CR in a value" ]; then mkenv RESTIC_REPOSITORY; fi
  printf '%s\n' "${bad_lines[$i]}" >> "$C/backup.env"
  run_case 'main nightly'
  expect_rc "grammar: ${bad_labels[$i]} refused" 2
  expect_out_has "grammar: ${bad_labels[$i]} refused for the right reason" "FATAL: env file"
  expect_out_has "grammar: ${bad_labels[$i]} message" "${bad_msgs[$i]}"
  expect_eq "grammar: ${bad_labels[$i]} -> failed_phase=env" "$(state 5)" "env"
  expect_eq "grammar: ${bad_labels[$i]} -> no webhook" "$(ncurl)" "0"
done
new_case
{ printf '\n# a comment\n\n'; cat "$C/backup.env"; printf '\n# trailing comment\n'; } > "$C/with-extras.env"
mv "$C/with-extras.env" "$C/backup.env"
chmod 600 "$C/backup.env"
run_case 'main nightly'
expect_rc "positive control: blank and # lines skipped, same keys accepted" 0

# ---------------------------------------------------------------------------------------------------------------
# 4. Masking
new_case
run_case 'PHASES=(ph_restic); main nightly'
expect_rc "failing restic phase exits 1" 1
expect_eq "positive control: the stub saw the real password" "$(cat "$C/restic-saw")" "$PW_SECRET"
expect_calls_has "positive control: restic was called" "restic backup"
expect_out_has "error text is kept, masked" "Fatal: wrong password ***"
expect_out_lacks "no plain password on stdout" "$PW_SECRET"
expect_out_lacks "no plain AWS secret on stdout" "$AWS_SECRET"
expect_text_lacks "no plain password in the log file" "$(logtext)" "$PW_SECRET"
expect_text_lacks "no plain AWS secret in the log file" "$(logtext)" "$AWS_SECRET"
expect_text_has "masked text in the log file" "$(logtext)" "wrong password ***"
expect_text_lacks "no plain password in the curl payload" "$(payload)" "$PW_SECRET"
expect_text_lacks "no plain AWS secret in the curl payload" "$(payload)" "$AWS_SECRET"
expect_out_has "repository value is masked in the error text" "for repo *** using key ***"
expect_out_has "access key id is masked in the error text" "id ***"
for v in "s3:https://acct.example.test/bucket" "TESTKEYIDMARKER0001"; do
  expect_out_lacks "no plain '$v' on stdout" "$v"
  expect_text_lacks "no plain '$v' in the log file" "$(logtext)" "$v"
  expect_text_lacks "no plain '$v' in the curl payload" "$(payload)" "$v"
done
expect_text_has "masked error text reaches the Discord message" "$(payload)" "wrong password ***"
expect_text_has "failure message names the phase" "$(payload)" "FAILED at phase ph_restic"
expect_eq "state failed_phase is the restic phase" "$(state 5)" "ph_restic"
expect_eq "exactly one failure notify" "$(ncurl)" "1"

# ---------------------------------------------------------------------------------------------------------------
# 5. JSON body
new_case
if [ "$HAVE_PY" -eq 1 ]; then
  export HOOK="$HOOK_SECRET"
  export TXT=$'quote " backslash \\ newline\nline2 tab\tend @everyone ctrl\001x'
  run_case 'DISCORD_WEBHOOK="$HOOK"; WORK="$(mktemp -d)"; TIMED_LAST_FILE="$WORK/t"; notify ok "$TXT"'
  expect_rc "notify runs" 0
  rc=0
  out="$(python3 -I -c '
import json, os, sys
d = json.load(open(sys.argv[1]))
assert d["allowed_mentions"] == {"parse": []}, d
assert d["content"] == "platform-backup ok: " + os.environ["TXT"], repr(d["content"])
print("json-ok")
' "$C/payload.json" 2>&1)" || rc=$?
  expect_rc "a real JSON parser accepts the body, allowed_mentions.parse empty, text round-trips" 0
  expect_out_has "json parser verdict" "json-ok"
fi

# notify text with & (patsub_replacement) and backslash, and a webhook value with backslash and quote
new_case
export HOOK2='https://h.example.test/a\b"c' TXT2='x & y \ z &'
run_case 'DISCORD_WEBHOOK="$HOOK2"; notify ok "$TXT2"'
expect_rc "notify with & and backslash runs" 0
expect_text_has "& and backslash are escaped in the payload" "$(payload)" 'platform-backup ok: x & y \\ z &'
expect_text_has "webhook backslash and quote are escaped in the curl config" "$(cat "$C/curl.cfg" 2> /dev/null)" 'url = "https://h.example.test/a\\b\"c"'
expect_calls_lacks "webhook value never on argv" "h.example.test"

# ---------------------------------------------------------------------------------------------------------------
# 6. Webhook failure leaves the exit code alone
new_case
printf 'curl: (22) HTTP 404 for %s\n' "$HOOK_SECRET" > "$C/curl.fail"
run_case 'PHASES=(ph_ok); main nightly'
expect_rc "webhook failure does not change the exit code" 0
expect_eq "positive control: curl was called" "$(ncurl)" "1"
expect_eq "state still ok" "$(state 3)" "ok"
expect_text_has "failure logged with rc" "$(logtext)" "notify: webhook POST failed rc=22"
expect_text_has "curl error text logged, masked" "$(logtext)" "curl: (22) HTTP 404 for ***"
expect_text_lacks "webhook URL not logged in plain" "$(logtext)" "$HOOK_SECRET"
new_case
printf 'curl: (22) HTTP 404\n' > "$C/curl.fail"
run_case 'PHASES=(ph_restic); main nightly'
expect_rc "a failed run with a failed webhook still exits 1" 1

# ---------------------------------------------------------------------------------------------------------------
# 7. Lock
new_case
flock "$C/lock" sleep 30 &
holder=$!
for _ in $(seq 1 50); do flock -n "$C/lock" true 2> /dev/null || break; sleep 0.1; done
run_case 'PHASES=(ph_never); main nightly'
expect_rc "held lock exits 1" 1
expect_eq "lock: state failed" "$(state 3)" "failed"
expect_eq "lock: failed_phase=lock" "$(state 5)" "lock"
expect_out_has "lock-held logged" "state lock-held"
expect_eq "lock: exactly one notify" "$(ncurl)" "1"
expect_absent "no phase runs when the lock is held" "$C/never-ran"
pkill -P "$holder" 2> /dev/null
kill "$holder" 2> /dev/null
wait "$holder" 2> /dev/null
t_reset_calls
run_case 'PHASES=(ph_never); main nightly'
expect_rc "positive control: lock free again, run proceeds" 0
expect_present "positive control: phase ran once the lock was free" "$C/never-ran"

# ---------------------------------------------------------------------------------------------------------------
# 8. timed: timeout, rc passthrough, clamp
new_case
run_case 'RUN_START_EPOCH="$(now_epoch)"; rc=0; timed t1 1 sleep 5 || rc=$?; echo "rc=$rc"'
expect_out_has "timeout returns 124" "rc=124"
expect_out_has "TIMED OUT logged" "phase=t1 TIMED OUT after 1s"
run_case 'RUN_START_EPOCH="$(now_epoch)"; rc=0; timed t2 10 sh -c "exit 3" || rc=$?; echo "rc=$rc"'
expect_out_has "a command that exits 3 returns 3" "rc=3"
expect_out_lacks "no TIMED OUT for rc 3" "TIMED OUT"

new_case
export ADV_TO=1099 PLATFORM_BACKUP_DEADLINE_SECS=100
run_case 'PHASES=(ph_adv ph_clamp); main nightly'
expect_rc "clamped phase fails the run with exit 1" 1
expect_out_has "timeout clamped to the 1s remaining, not the phase's 600s" "phase=ph_clamp start timeout=1s"
expect_out_has "clamped expiry logged as TIMED OUT" "phase=ph_clamp TIMED OUT after 1s"
expect_out_has "clamped expiry returns 124" "phase=ph_clamp end rc=124"
expect_eq "clamp: failed_phase" "$(state 5)" "ph_clamp"
new_case
export PLATFORM_BACKUP_DEADLINE_SECS=100
run_case 'PHASES=(ph_noclamp); main nightly'
expect_rc "positive control: a command inside the remaining time" 0
expect_out_has "positive control: not clamped (60s phase timeout < 100s remaining)" "phase=ph_noclamp start timeout=60s"
new_case
export ADV_TO=1099 PLATFORM_BACKUP_DEADLINE_SECS=100
run_case 'PHASES=(ph_adv ph_fastclamp); main nightly'
expect_rc "a fast command with the clamp engaged succeeds" 0
expect_out_has "fast command: clamp engaged (1s remaining, 600s phase timeout)" "phase=ph_fastclamp start timeout=1s"
expect_out_has "fast command ends rc=0" "phase=ph_fastclamp end rc=0"
expect_out_lacks "fast command: no TIMED OUT" "TIMED OUT"
new_case
run_case 'RUN_START_EPOCH=1000; DEADLINE_SECS=100; printf 1100 > "$CLK"; rc=0; timed late 10 touch "$C/ran" || rc=$?; echo "rc=$rc"'
expect_out_has "timed with no time left returns 124" "rc=124"
expect_absent "timed with no time left does not start the command" "$C/ran"
expect_out_has "timed with no time left says why" "total deadline of 100s already reached"

# ---------------------------------------------------------------------------------------------------------------
# 9. Total deadline and exempt calls
new_case
export ADV_TO=1100 PLATFORM_BACKUP_DEADLINE_SECS=100
run_case 'PHASES=(ph_adv ph_never); main nightly'
expect_rc "deadline reached: run exits 1" 1
expect_absent "the next phase is not started past the deadline" "$C/never-ran"
expect_eq "deadline: failed_phase is the phase it would have started" "$(state 5)" "ph_never"
expect_out_has "deadline exceeded message" "deadline exceeded"
expect_eq "deadline: exactly one failure notify" "$(ncurl)" "1"
expect_out_has "exempt: notify keeps its own 30s bound with the deadline exhausted" "phase=notify start timeout=30s"
expect_eq "exempt: state still written" "$(state 3)" "failed"
expect_text_has "deadline text in the Discord message" "$(payload)" "deadline exceeded"

new_case
export ADV_TO=1050 PLATFORM_BACKUP_DEADLINE_SECS=100
run_case 'PHASES=(ph_adv ph_never); main nightly'
expect_rc "positive control: phase ending before the deadline lets the next start" 0
expect_present "positive control: the next phase ran" "$C/never-ran"

for bad in 0 abc -5 "" 1.5; do
  new_case
  export PLATFORM_BACKUP_DEADLINE_SECS="$bad"
  run_case 'main nightly'
  expect_rc "PLATFORM_BACKUP_DEADLINE_SECS '$bad' exits 2" 2
done
new_case
export PLATFORM_BACKUP_DEADLINE_SECS=4200
run_case 'main nightly'
expect_rc "positive control: valid deadline value" 0

# other override validation
new_case
export PLATFORM_BACKUP_ENV_FILE="relative/backup.env"
run_case 'main nightly'
expect_rc "relative path override exits 2" 2
new_case
export PLATFORM_BACKUP_PG_CONTAINER="bad name"
run_case 'main nightly'
expect_rc "invalid container name exits 2" 2
new_case
export PLATFORM_BACKUP_LOCK=""
run_case 'main nightly'
expect_rc "empty path override exits 2" 2

# ---------------------------------------------------------------------------------------------------------------
# 10. Signals
new_case
run_bg 'PHASES=(ph_slow); main nightly'
if wait_for_text "$C/bg.out" "phase=ph_slow start"; then _pass; else _fail "TERM case: slow phase started"; fi
kill -TERM "$BGPID"
rc=0
wait "$BGPID" || rc=$?
out="$(cat "$C/bg.out")"
expect_rc "TERM exits 1" 1
expect_eq "TERM: state failed" "$(state 3)" "failed"
expect_eq "TERM: failed_phase is the phase reached" "$(state 5)" "ph_slow"
expect_eq "TERM: exactly one notify" "$(ncurl)" "1"
expect_out_has "TERM logged" "signal TERM received during phase=ph_slow"
if flock -n "$C/lock" true; then _pass; else _fail "TERM: no lock left held"; fi

new_case
run_bg 'PHASES=(ph_slow); main nightly'
if wait_for_text "$C/bg.out" "phase=ph_slow start"; then _pass; else _fail "INT case: slow phase started"; fi
kill -INT "$BGPID"
rc=0
wait "$BGPID" || rc=$?
out="$(cat "$C/bg.out")"
expect_rc "INT exits 1" 1
expect_eq "INT: failed_phase is the phase reached" "$(state 5)" "ph_slow"
expect_eq "INT: exactly one notify" "$(ncurl)" "1"
if flock -n "$C/lock" true; then _pass; else _fail "INT: no lock left held"; fi

new_case
run_case 'PHASES=(ph_ok ph_selfkill ph_never); main nightly'
expect_rc "a run killed between phases exits 1" 1
expect_eq "killed run: state failed" "$(state 3)" "failed"
expect_eq "killed run: phase reached recorded" "$(state 5)" "ph_selfkill"
expect_absent "killed run: later phases did not run" "$C/never-ran"
expect_eq "killed run: one notify" "$(ncurl)" "1"

# ---------------------------------------------------------------------------------------------------------------
# 11. window.env and window warnings
wf="$here/window.env"
expect_eq "window.env has exactly three lines" "$(wc -l < "$wf" | tr -d ' ')" "3"
expect_eq "window.env keys" "$(cut -d= -f1 "$wf" | tr '\n' ' ')" "BACKUP_WINDOW_START BACKUP_WINDOW_END BACKUP_WINDOW_TZ "
w_start="$(sed -n 's/^BACKUP_WINDOW_START=//p' "$wf")"
w_end="$(sed -n 's/^BACKUP_WINDOW_END=//p' "$wf")"
if [[ "$w_start" < "$w_end" ]]; then _pass; else _fail "window.env START < END"; fi
expect_eq "window.env TZ" "$(sed -n 's/^BACKUP_WINDOW_TZ=//p' "$wf")" "America/Chicago"
new_case
out="$(bash -c '. "$SCRIPT"; window_file' 2>&1)"
expect_eq "window_file defaults to window.env beside backup.sh" "$out" "$here/window.env"

new_case
export HHMM_TO=02:00
printf '02:00' > "$HHMM"
run_case 'PHASES=(ph_ok); main nightly'
expect_rc "nightly outside window is still ok" 0
expect_eq "outside window: state ok" "$(state 3)" "ok"
expect_text_has "outside window: warning in notify" "$(payload)" "started outside backup window"
new_case
run_case 'PHASES=(ph_ok); main nightly'
expect_text_lacks "inside window: no start warning" "$(payload)" "started outside backup window"
expect_text_lacks "inside window: no overran warning" "$(payload)" "overran backup window"
new_case
printf '02:00' > "$HHMM"
run_case 'PHASES=(ph_ok); main manual'
expect_rc "manual outside window ok" 0
expect_text_lacks "manual: no start warning" "$(payload)" "started outside backup window"
expect_eq "manual: positive control, notify was sent" "$(ncurl)" "1"

new_case
export HHMM_TO=05:10
run_case 'PHASES=(ph_hhmm); main nightly'
expect_rc "overran nightly still ok" 0
expect_eq "overran: state ok" "$(state 3)" "ok"
expect_text_has "overran: warning in notify" "$(payload)" "overran backup window"
expect_text_lacks "overran: started inside, no start warning" "$(payload)" "started outside backup window"
for hh in 03:30 04:59; do
  new_case
  printf '%s' "$hh" > "$HHMM"
  run_case 'PHASES=(ph_ok); main nightly'
  expect_text_lacks "start at $hh (inside [03:30,05:00)): no start warning" "$(payload)" "started outside backup window"
  expect_eq "start at $hh: notify was sent" "$(ncurl)" "1"
done
for hh in 03:29 05:00; do
  new_case
  printf '%s' "$hh" > "$HHMM"
  run_case 'PHASES=(ph_ok); main nightly'
  expect_text_has "start at $hh (outside [03:30,05:00)): start warning" "$(payload)" "started outside backup window"
done
new_case
export HHMM_TO=05:00
run_case 'PHASES=(ph_hhmm); main nightly'
expect_text_has "ending exactly at END counts as overran" "$(payload)" "overran backup window"
new_case
export HHMM_TO=04:59
run_case 'PHASES=(ph_hhmm); main nightly'
expect_text_lacks "ending one minute before END: no overran warning" "$(payload)" "overran backup window"
new_case
export HHMM_TO=04:30
run_case 'PHASES=(ph_hhmm); main nightly'
expect_text_lacks "ending before END: no overran warning" "$(payload)" "overran backup window"
new_case
export HHMM_TO=05:10
run_case 'PHASES=(ph_hhmm); main manual'
expect_text_lacks "manual ending after END: no overran warning" "$(payload)" "overran backup window"
expect_eq "manual overran control: notify was sent" "$(ncurl)" "1"

# ---------------------------------------------------------------------------------------------------------------
# 12. Log pruning: newest 30 always kept, older ones only when also over 30 days old
new_case
mkdir -p "$C/logs"
for i in $(seq 1 40); do
  d="$(date -u -d "2020-01-01 +$i days" +%Y-%m-%d)"
  : > "$C/logs/$d.log"
  touch -d "$d" "$C/logs/$d.log"
done
run_case 'PHASES=(ph_ok); main nightly'
expect_rc "run with old logs present" 0
expect_eq "old logs pruned down to the newest 30 (including today's)" "$(find "$C/logs" -name '*.log' | wc -l | tr -d ' ')" "30"
new_case
mkdir -p "$C/logs"
for i in $(seq 1 40); do
  d="$(date -u -d "2020-01-01 +$i days" +%Y-%m-%d)"
  : > "$C/logs/$d.log"
done
run_case 'PHASES=(ph_ok); main nightly'
expect_eq "recent logs beyond 30 are kept (age rule)" "$(find "$C/logs" -name '*.log' | wc -l | tr -d ' ')" "41"

t_finish
