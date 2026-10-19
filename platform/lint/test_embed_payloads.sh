#!/usr/bin/env bash
# Tests for embed-payloads.sh: marker-based discovery, drift detection, idempotent regeneration, bad-input exits.
# SC1091: lib.sh is sourced by relative path. SC2016: fixture payloads are single-quoted on purpose.
# SC2154: $out is assigned by lib.sh's run_cmd.
# shellcheck disable=SC1091,SC2016,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
tool="$here/embed-payloads.sh"
repo_root="$(cd "$here/../.." && pwd)"

t_init

# new_root: a scratch repo layout with two installers and three payload sources.
new_root() {
  R="$T_TMP/root"
  rm -rf "$R"
  mkdir -p "$R/platform/host"
  printf '#!/usr/bin/env bash\necho one\n\techo "tab and $dollar and `tick`"\n' > "$R/platform/host/one.sh"
  printf '#!/usr/bin/env bash\necho two\n' > "$R/platform/host/two.sh"
  printf '#!/usr/bin/env bash\necho three\n' > "$R/platform/host/three-a.b.sh"
  cat > "$R/platform/host/install-alpha.sh" <<'EOF'
#!/usr/bin/env bash
echo before
# BEGIN-PAYLOAD platform/host/one.sh
# END-PAYLOAD platform/host/one.sh
echo middle
# BEGIN-PAYLOAD platform/host/two.sh
# END-PAYLOAD platform/host/two.sh
echo after
EOF
  cat > "$R/platform/host/install-beta.sh" <<'EOF'
#!/usr/bin/env bash
# BEGIN-PAYLOAD platform/host/three-a.b.sh
# END-PAYLOAD platform/host/three-a.b.sh
EOF
  printf '#!/usr/bin/env bash\necho not an installer\n' > "$R/platform/host/other.sh"
}

gen() { run_cmd "$tool" --root "$R"; }
chk() { run_cmd "$tool" --check --root "$R"; }

new_root

# --- a fresh region set is drift until regenerated ---
chk
expect_rc "empty regions are drift" 1
expect_out_has "drift names the installer" "DRIFT platform/host/install-alpha.sh: platform/host/one.sh"
expect_out_has "drift names the second payload" "DRIFT platform/host/install-alpha.sh: platform/host/two.sh"
expect_out_has "drift in a second installer is discovered (generic markers)" "DRIFT platform/host/install-beta.sh: platform/host/three-a.b.sh"
expect_out_lacks "a non-installer file is not scanned" "other.sh"

before="$(cat "$R/platform/host/install-alpha.sh")"
chk
expect_eq "--check never rewrites" "$(cat "$R/platform/host/install-alpha.sh")" "$before"

gen
expect_rc "regenerate succeeds" 0
chk
expect_rc "check passes after regenerate" 0
expect_out_has "check reports OK with installer and region counts" "embed-payloads: OK (2 installer(s), 3 payload(s))"

# --- the embedded bytes are exactly the sources, surrounding text is preserved ---
sed -n '/^payload_one() {/,/^}/p' "$R/platform/host/install-alpha.sh" | sed '1,2d' | sed '$d' | sed '$d' > "$T_TMP/extracted"
if cmp -s "$T_TMP/extracted" "$R/platform/host/one.sh"; then _pass; else _fail "embedded payload one equals its source byte for byte"; fi
expect_eq "text before the first region is kept" "$(sed -n '1,2p' "$R/platform/host/install-alpha.sh")" "$(printf '#!/usr/bin/env bash\necho before')"
expect_eq "text between regions is kept" "$(grep -c '^echo middle$' "$R/platform/host/install-alpha.sh")" "1"
expect_eq "text after the last region is kept" "$(tail -n 1 "$R/platform/host/install-alpha.sh")" "echo after"

# --- idempotent ---
snap="$(cat "$R/platform/host/install-alpha.sh" "$R/platform/host/install-beta.sh")"
gen
expect_rc "second regenerate succeeds" 0
expect_out_lacks "second regenerate rewrites nothing" "updated"
expect_eq "second regenerate leaves bytes identical" "$(cat "$R/platform/host/install-alpha.sh" "$R/platform/host/install-beta.sh")" "$snap"

# --- altering a source makes the check fail naming the file; regenerating fixes it ---
echo '# changed' >> "$R/platform/host/two.sh"
chk
expect_rc "altered source is drift" 1
expect_out_has "altered source named" "DRIFT platform/host/install-alpha.sh: platform/host/two.sh"
expect_out_lacks "only the altered payload is named" "platform/host/one.sh"
gen
expect_rc "regenerate after source change" 0
expect_out_has "regenerate reports the rewritten installer" "updated platform/host/install-alpha.sh"
chk
expect_rc "check passes after regenerating a changed source" 0

# --- altering the embedded copy makes the check fail ---
sed -i 's/^echo two$/echo TWO/' "$R/platform/host/install-alpha.sh"
chk
expect_rc "altered embedded copy is drift" 1
expect_out_has "altered embedded copy named" "platform/host/two.sh"
gen
chk
expect_rc "regenerate restores the embedded copy" 0

# A deleted payload line and an added line are drift too.
sed -i '/^echo three$/d' "$R/platform/host/install-beta.sh"
chk
expect_rc "deleted embedded line is drift" 1
gen
printf 'extra\n' >> "$R/platform/host/three-a.b.sh"
chk
expect_rc "source gaining a line is drift" 1
gen

# --- bad input exits 2 and rewrites nothing ---
bad_case() {
  local label="$1"
  new_root
  "$2"
  snap="$(cat "$R/platform/host/install-alpha.sh")"
  gen
  expect_rc "bad input: $label" 2
  expect_eq "bad input leaves the installer untouched: $label" "$(cat "$R/platform/host/install-alpha.sh")" "$snap"
  chk
  expect_rc "bad input also fails --check: $label" 2
}
c_missing_src() { rm "$R/platform/host/two.sh"; }
c_no_newline() { printf 'no newline' > "$R/platform/host/two.sh"; }
c_delimiter() { printf 'a\nPLATFORM_PAYLOAD_EOF\nb\n' > "$R/platform/host/two.sh"; }
c_unclosed() { sed -i '/END-PAYLOAD platform\/host\/two.sh/d' "$R/platform/host/install-alpha.sh"; }
c_nested() { sed -i 's/^# END-PAYLOAD platform\/host\/one.sh$/# BEGIN-PAYLOAD platform\/host\/two.sh/' "$R/platform/host/install-alpha.sh"; }
c_traversal() { sed -i 's#platform/host/one.sh#../etc/passwd#' "$R/platform/host/install-alpha.sh"; }
c_absolute() { sed -i 's#platform/host/one.sh#/etc/passwd#' "$R/platform/host/install-alpha.sh"; }
c_odd_chars() { sed -i 's#platform/host/one.sh#platform/host/o ne;sh#' "$R/platform/host/install-alpha.sh"; }
bad_case "missing source" c_missing_src
bad_case "source without a trailing newline" c_no_newline
bad_case "source containing the heredoc delimiter" c_delimiter
bad_case "unclosed BEGIN" c_unclosed
bad_case "BEGIN before the previous END" c_nested
bad_case "path traversal" c_traversal
bad_case "absolute path" c_absolute
bad_case "unsafe characters in the path" c_odd_chars

# An installer whose markers vanished (deleted, or misspelled so they no longer match) must not pass silently.
c_zero_regions() { printf '#!/usr/bin/env bash\necho no markers left\n' > "$R/platform/host/install-beta.sh"; }
c_misspelled() { sed -i 's/^# BEGIN-PAYLOAD /# BEGIN-PAYLOAD: /' "$R/platform/host/install-beta.sh"; }
# A heredoc terminator line outside a region means a region marker was lost around an embedded payload.
c_orphan_delim() { printf 'PLATFORM_PAYLOAD_EOF\n' >> "$R/platform/host/install-alpha.sh"; }
# Marker pairs anywhere but platform/host/install-*.sh would be silently ignored, so they are refused.
c_outside_marker() { printf '# BEGIN-PAYLOAD platform/host/two.sh\n# END-PAYLOAD platform/host/two.sh\n' > "$R/platform/host/installer-gamma.sh"; }
c_outside_subdir() { mkdir -p "$R/platform/lib"; printf '# BEGIN-PAYLOAD platform/host/two.sh\n' > "$R/platform/lib/helper.sh"; }
# A source holding a marker line would end or start a region on the next scan.
c_src_end_marker() { printf 'a\n# END-PAYLOAD platform/host/two.sh\nb\n' > "$R/platform/host/two.sh"; }
c_src_begin_marker() { printf 'a\n# BEGIN-PAYLOAD platform/host/one.sh\nb\n' > "$R/platform/host/two.sh"; }
# Two payloads in one installer that map to the same function name: the later would silently win.
c_dup_name() {
  mkdir -p "$R/platform/host/sub"
  printf '#!/usr/bin/env bash\necho other one\n' > "$R/platform/host/sub/one.sh"
  printf '# BEGIN-PAYLOAD platform/host/sub/one.sh\n# END-PAYLOAD platform/host/sub/one.sh\n' >> "$R/platform/host/install-alpha.sh"
}
c_dup_punct() {
  printf '#!/usr/bin/env bash\necho dash\n' > "$R/platform/host/login-shell.sh"
  printf '#!/usr/bin/env bash\necho underscore\n' > "$R/platform/host/login_shell.sh"
  printf '# BEGIN-PAYLOAD platform/host/login-shell.sh\n# END-PAYLOAD platform/host/login-shell.sh\n# BEGIN-PAYLOAD platform/host/login_shell.sh\n# END-PAYLOAD platform/host/login_shell.sh\n' >> "$R/platform/host/install-alpha.sh"
}
bad_case "installer without any region" c_zero_regions
bad_case "misspelled marker leaves no region" c_misspelled
bad_case "orphan heredoc delimiter outside a region" c_orphan_delim
bad_case "marker pair in a non-installer file" c_outside_marker
bad_case "marker in a non-installer subdirectory" c_outside_subdir
bad_case "source containing an END marker line" c_src_end_marker
bad_case "source containing a BEGIN marker line" c_src_begin_marker
bad_case "duplicate function name (same basename)" c_dup_name
bad_case "duplicate function name (punctuation collapses)" c_dup_punct

# the failure messages say why
new_root; c_zero_regions; chk
expect_out_has "zero-region message" "no payload region found"
new_root; c_orphan_delim; chk
expect_out_has "orphan delimiter message" "outside any BEGIN-PAYLOAD region"
new_root; c_outside_marker; chk
expect_out_has "outside-marker message names the file" "installer-gamma.sh"
new_root; c_src_end_marker; chk
expect_out_has "marker-in-source message" "payload marker"
new_root; c_dup_name; chk
expect_out_has "duplicate function message" "payload_one"

# no installer at all is an error, not a pass
new_root
rm "$R"/platform/host/install-*.sh
chk
expect_rc "no installer found" 2

# --help prints the whole header, usage and exit lines included
run_cmd "$tool" --help
expect_rc "--help succeeds" 0
expect_out_has "--help shows the usage line" "Usage: embed-payloads.sh"
expect_out_has "--help shows the exit codes" "Exit: 0 in sync"
expect_out_has "--help shows the last header line" "must not start a line with"
expect_out_lacks "--help stops before the code" "set -euo"

run_cmd "$tool" --bogus
expect_rc "unknown argument" 2
run_cmd "$tool" --root
expect_rc "--root without a value" 2

# --- the real repo: embedded payloads match the tracked sources, and a drifted copy of it fails ---
run_cmd "$tool" --check --root "$repo_root"
expect_rc "the real installers are in sync" 0
if [[ "$out" =~ ([0-9]+)\ payload\(s\) ]] && [ "${BASH_REMATCH[1]}" -ge 2 ]; then _pass; else _fail "the real run discovers at least the dispatcher and wrapper regions" "$out"; fi

if [ -f "$repo_root/platform/host/install-deploy-user.sh" ]; then
  real="$T_TMP/real"
  rm -rf "$real"
  mkdir -p "$real/platform/host"
  cp "$repo_root"/platform/host/*.sh "$real/platform/host/"
  echo '# drift' >> "$real/platform/host/platform.sh"
  run_cmd "$tool" --check --root "$real"
  expect_rc "a drifted dispatcher source fails the check" 1
  expect_out_has "drift names the real installer and source" "DRIFT platform/host/install-deploy-user.sh: platform/host/platform.sh"
  run_cmd "$tool" --root "$real"
  expect_rc "regenerating the drifted copy" 0
  run_cmd "$tool" --check --root "$real"
  expect_rc "check passes after regenerating the drifted copy" 0

  # the wrapper payload is checked too, not only the dispatcher
  echo '# drift' >> "$real/platform/host/login-shell.sh"
  run_cmd "$tool" --check --root "$real"
  expect_rc "a drifted wrapper source fails the check" 1
  expect_out_has "drift names the wrapper source" "DRIFT platform/host/install-deploy-user.sh: platform/host/login-shell.sh"
  expect_out_lacks "only the wrapper drifted" "platform/host/platform.sh"
fi

t_finish
