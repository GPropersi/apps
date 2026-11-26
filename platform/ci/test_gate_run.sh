#!/usr/bin/env bash
# Executable test of the deploy job's `Check host installers` gate: the step's real run: text is extracted from
# .github/workflows/app-deploy-one.yml and run under `bash -e` (the Actions default) from the repo root with a
# PATH-stubbed `tailscale`. The decision script's exit code and refusal text must reach the step's exit status, so a
# swallowed exit (an added `|| true`, a lost `-e`) fails here.
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
repo="$(cd "$here/../.." && pwd)"
workflow="$repo/.github/workflows/app-deploy-one.yml"

t_init
tab=$'\t'
names=(deploy-user data ingress jobs)

# gate_run: the run: block of the step named `Check host installers`, dedented by its 10-space content indent.
gate_run() {
  awk '
    /^      - name: Check host installers$/ { instep = 1; next }
    instep && /^      - / { exit }
    instep && /^        run: \|$/ { inrun = 1; next }
    inrun { if ($0 ~ /^          /) { sub(/^          /, ""); print } else if ($0 !~ /^[ ]*$/) exit }
  ' "$workflow"
}

script="$T_TMP/gate-step.sh"
gate_run > "$script"
if [ ! -s "$script" ]; then
  echo "FAIL: could not extract the Check host installers run: text from $workflow"
  exit 1
fi

# stub_tailscale <rc> <stdout>: a tailscale that prints a canned output and exits with a canned status.
stub_tailscale() {
  printf '#!/usr/bin/env bash\nprintf "%%s" %q\nexit %q\n' "$2" "$1" > "$STUB_BIN/tailscale"
  chmod +x "$STUB_BIN/tailscale"
}

# run_gate: the step under bash -e from the repo root, DEPLOY_HOST set.
run_gate() {
  run_cmd env DEPLOY_HOST=host.invalid bash -e -c 'cd "$1" && bash -e "$2"' _ "$repo" "$script"
}

# host_matching: the four lines a host holding exactly this checkout's installers prints.
host_matching() {
  local n s o=""
  for n in "${names[@]}"; do
    s="$(sed -n 's/^readonly INSTALLER_STAMP=//p' "$repo/platform/host/install-$n.sh")"
    o+="$n$tab$s"$'\n'
  done
  printf '%s' "$o"
}

stub_tailscale 0 "$(host_matching)"
run_gate
expect_rc "matching stamps: the step passes" 0
expect_out_has "matching stamps: the success line" "check-installer-stamps: host installers match this commit"

stub_tailscale 2 ""
run_gate
if [ "$rc" -ne 0 ]; then _pass; else _fail "rc 2: the step must fail" "rc=$rc"; fi
expect_out_has "rc 2: the dispatcher line" "the host dispatcher has no 'stamps' command"

stub_tailscale 255 ""
run_gate
if [ "$rc" -ne 0 ]; then _pass; else _fail "rc 255: the step must fail" "rc=$rc"; fi
expect_out_has "rc 255: the refusing-blind line" "refusing to deploy blind"

drifted="$(host_matching | sed "s/^data${tab}.*/data${tab}0123456789abcdef/")"
stub_tailscale 0 "$drifted"
run_gate
if [ "$rc" -ne 0 ]; then _pass; else _fail "drifted output: the step must fail" "rc=$rc"; fi
expect_out_has "drifted output: the differs line" "host installer data differs from this commit"
expect_out_has "drifted output: the newer-main line" "if the host installer is already from a newer main, re-run the latest deploy instead"

stub_tailscale 0 "not four lines"
run_gate
if [ "$rc" -ne 0 ]; then _pass; else _fail "garbled output: the step must fail" "rc=$rc"; fi
expect_out_has "garbled output: the differs line" "differs from this commit"

# Host-controlled text never reaches the log (the decision script prints it as `unparsed`).
expect_out_lacks "garbled output: host text is never echoed" "not four lines"

t_finish
