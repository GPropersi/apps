#!/usr/bin/env bash
# Stub tests for install-deploy-user.sh. Every file the installer writes lands under INSTALL_DEPLOY_ROOT, the
# privilege prefix is a logging fakesudo, and useradd/usermod/passwd/getent/id/sshd/systemctl/chown/stat/ssh are
# stateful stubs. "Root-owned" is asserted through the logged chown calls (the stat stub reports root:root unless a
# test overrides it); modes are real. No address literals: the hygiene check flags them.
# SC2016: payloads are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# shellcheck disable=SC1091,SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/install-deploy-user.sh"

t_init
STATE="$T_TMP/state"
export STATE

# ---- stubs ----

# mkstub <name>: reads the stub body from stdin; the stub first logs "<name> <argv...>" to the call log.
mkstub() {
  local name="$1"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "%%s" %q >> "$CALL_LOG"\n' "$name"
    printf 'for a in "$@"; do printf " %%s" "$a" >> "$CALL_LOG"; done\n'
    printf 'printf "\\n" >> "$CALL_LOG"\n'
    cat
  } > "$STUB_BIN/$name"
  chmod +x "$STUB_BIN/$name"
}

mkstub fakesudo <<'EOF'
exec "$@"
EOF

mkstub chown <<'EOF'
exit 0
EOF

# nosudo: a privilege prefix that always refuses (like `sudo -n` without NOPASSWD).
mkstub nosudo <<'EOF'
exit 1
EOF

mkstub logger <<'EOF'
exit 0
EOF

mkstub systemctl <<'EOF'
[ -f "$STATE/systemctl_fail" ] && exit 1
exit 0
EOF

mkstub getent <<'EOF'
case "$1 ${2:-}" in
  "group docker") [ -f "$STATE/no_docker_group" ] && exit 2; echo "docker:x:999:"; exit 0 ;;
  "passwd deploy")
    [ -f "$STATE/user_shell" ] || exit 2
    echo "deploy:x:1001:1001:platform deploy:/home/deploy:$(cat "$STATE/user_shell")"; exit 0 ;;
esac
exit 2
EOF

mkstub id <<'EOF'
if [ "$1" = "-nG" ] && [ "$2" = "deploy" ]; then cat "$STATE/user_groups"; exit 0; fi
echo "admin"; exit 0
EOF

mkstub useradd <<'EOF'
while [ $# -gt 0 ]; do
  case "$1" in
    --shell) echo "$2" > "$STATE/user_shell"; shift 2 ;;
    --groups) echo "deploy ${2//,/ }" > "$STATE/user_groups"; shift 2 ;;
    *) shift ;;
  esac
done
echo 0 > "$STATE/user_locked"
EOF

mkstub usermod <<'EOF'
while [ $# -gt 0 ]; do
  case "$1" in
    --shell) echo "$2" > "$STATE/user_shell"; shift 2 ;;
    -aG) echo "$(cat "$STATE/user_groups") ${2//,/ }" > "$STATE/user_groups"; shift 2 ;;
    *) shift ;;
  esac
done
EOF

mkstub passwd <<'EOF'
case "$1" in
  -l) echo 1 > "$STATE/user_locked" ;;
  -S) if [ "$(cat "$STATE/user_locked")" = "1" ]; then echo "deploy L 2026-10-18 0 99999 7 -1"; else echo "deploy P 2026-10-18 0 99999 7 -1"; fi ;;
esac
exit 0
EOF

# stat: real mode, owner root:root unless the test lists an override line "<path> <owner:group>" in $STATE/stat_override.
mkstub stat <<'EOF'
path="${@: -1}"
mode="$(/usr/bin/stat -c '%a' -- "$path")" || exit 1
og="root:root"
if [ -f "$STATE/stat_override" ]; then
  line="$(grep -F -- "$path " "$STATE/stat_override" | head -n1 || true)"
  [ -z "$line" ] || og="${line##* }"
fi
echo "$og $mode"
EOF

# sshd: -t exits $STATE/sshd_t_rc (default 0); -T prints a sorted-irrelevant effective config derived from the real
# drop-in under INSTALL_DEPLOY_ROOT. "leak" makes the administrator's config differ once the drop-in exists.
mkstub sshd <<'EOF'
dropin="$INSTALL_DEPLOY_ROOT/etc/ssh/sshd_config.d/20-deploy.conf"
if [ "$1" = "-t" ]; then exit "$(cat "$STATE/sshd_t_rc" 2>/dev/null || echo 0)"; fi
user=""
for a in "$@"; do case "$a" in user=*) user="${a#user=}"; user="${user%%,*}" ;; esac; done
declare -A cfg=([authorizedkeysfile]=".ssh/authorized_keys" [permittty]=yes [allowtcpforwarding]=yes
  [allowagentforwarding]=yes [x11forwarding]=yes [permittunnel]=no [permituserrc]=yes
  [allowstreamlocalforwarding]=yes [gatewayports]=yes [permituserenvironment]=yes)
if [ -f "$dropin" ] && [ "$user" = "deploy" ]; then
  in=0
  while IFS= read -r line; do
    case "$line" in
      "Match User deploy") in=1 ;;
      "    "*) if [ "$in" -eq 1 ]; then set -- $line; k="$(echo "$1" | tr A-Z a-z)"; cfg[$k]="$2"; fi ;;
    esac
  done < "$dropin"
  # "global_override": an earlier global setting wins over the Match block (sshd is first-value-wins).
  if [ -f "$STATE/global_override" ]; then cfg[allowtcpforwarding]=yes; fi
fi
if [ -f "$dropin" ] && [ "$user" != "deploy" ] && [ -f "$STATE/leak" ]; then cfg[permittty]=no; fi
if [ -f "$STATE/leak_key" ] && [ "$user" != "deploy" ] && [ -f "$dropin" ]; then cfg[authorizedkeysfile]="/etc/ssh/authorized_keys.d/deploy"; fi
for k in "${!cfg[@]}"; do echo "$k ${cfg[$k]}"; done
EOF

# ssh: keeps the streamed script so a test can compare it to the installer.
mkstub ssh <<'EOF'
cat > "$STATE/ssh_stdin"
exit 0
EOF

# ---- fixtures ----

KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFrZUtleUJ5dGVzRm9yVGVzdFVzZU9ubHkxMjM= deploy-test@laptop'
INSTALLED_DISPATCHER=/usr/local/bin/platform
INSTALLED_WRAPPER=/usr/local/bin/platform-login
KEYFILE_PATH=/etc/ssh/authorized_keys.d/deploy
DROPIN_PATH=/etc/ssh/sshd_config.d/20-deploy.conf

# fresh: a clean root and clean state for the next scenario.
fresh() {
  rm -rf "$T_TMP/root" "$STATE"
  mkdir -p "$T_TMP/root" "$STATE"
  INSTALL_DEPLOY_ROOT="$T_TMP/root"
  export INSTALL_DEPLOY_ROOT
  INSTALL_DEPLOY_SUDO=fakesudo
  export INSTALL_DEPLOY_SUDO
  t_reset_calls
  rm -f "$T_TMP/key.pub"
  printf '%s\n' "$KEY" > "$T_TMP/key.pub"
}

# inst <args...>: run the installer as the administrator account "admin".
inst() { run_cmd bash "$script" "$@" --admin-user admin; }

root() { printf '%s%s' "$T_TMP/root" "$1"; }

# nothing_written: no mutating call and no file under the root.
nothing_written() {
  local label="$1"
  if grep -qE '^(fakesudo|sudo) ' "$CALL_LOG"; then _fail "$label: privileged call made" "$(cat "$CALL_LOG")"; else _pass; fi
  expect_eq "$label: no files under the root" "$(find "$T_TMP/root" -mindepth 1 | wc -l)" "0"
  expect_calls_lacks "$label: no useradd" "useradd"
}

# non_readonly_priv_calls: logged fakesudo verbs outside the read-only allowlist (empty for a no-op run).
non_readonly_priv_calls() { grep '^fakesudo ' "$CALL_LOG" | grep -vE '^fakesudo (true|sshd -T|stat|cat|getent|id|passwd -S)( |$)' || true; }

# tree_snapshot: names, modes, sizes, mtimes and checksums of everything under the root.
tree_snapshot() {
  find "$T_TMP/root" -mindepth 1 -exec /usr/bin/stat -c '%n %a %s %Y' {} + | sort
  find "$T_TMP/root" -type f -exec cksum {} + | sort
}

# expect_calls_match <label> <ERE>: a call-log line matches.
expect_calls_match() {
  if grep -qE -- "$2" "$CALL_LOG"; then _pass; else _fail "$1" "call log has no line matching: $2"; fi
}

# no_strays <label>: no leftover .new/.bak/.backup file anywhere under the root.
no_strays() {
  expect_eq "$1: no stray .new/.bak files" "$(find "$T_TMP/root" \( -name '*.new' -o -name '*.bak' -o -name '*.backup' \) | wc -l)" "0"
}

# ---- 1. fresh install ----
fresh
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "fresh install succeeds" 0
expect_out_has "fresh install reports done" "install-deploy-user: done"
if cmp -s "$here/platform.sh" "$(root $INSTALLED_DISPATCHER)"; then _pass; else _fail "installed dispatcher bytes equal the tracked source"; fi
if cmp -s "$here/login-shell.sh" "$(root $INSTALLED_WRAPPER)"; then _pass; else _fail "installed wrapper bytes equal the tracked source"; fi
expect_eq "dispatcher mode" "$(/usr/bin/stat -c %a "$(root $INSTALLED_DISPATCHER)")" "755"
expect_eq "wrapper mode" "$(/usr/bin/stat -c %a "$(root $INSTALLED_WRAPPER)")" "755"
expect_eq "key file mode" "$(/usr/bin/stat -c %a "$(root $KEYFILE_PATH)")" "644"
expect_eq "keys dir mode" "$(/usr/bin/stat -c %a "$(dirname "$(root $KEYFILE_PATH)")")" "755"
expect_eq "drop-in mode" "$(/usr/bin/stat -c %a "$(root $DROPIN_PATH)")" "644"
for p in "$INSTALLED_DISPATCHER" "$INSTALLED_WRAPPER" "$KEYFILE_PATH" "$DROPIN_PATH"; do
  expect_calls_has "chown root:root for $p" "chown root:root $(root "$p").new"
  # the owner is set on the temp file, before the rename: never on the live path, never after the mv
  c_line="$(grep -nF -m1 -- "chown root:root $(root "$p").new" "$CALL_LOG" | cut -d: -f1)"
  m_line="$(grep -nF -m1 -- "mv -f -- $(root "$p").new $(root "$p")" "$CALL_LOG" | cut -d: -f1)"
  if [ -n "$c_line" ] && [ -n "$m_line" ] && [ "$c_line" -lt "$m_line" ]; then _pass; else _fail "chown precedes mv for $p" "chown line '$c_line', mv line '$m_line'"; fi
  expect_eq "no chown aimed at the live path $p" "$(grep -cxF "chown root:root $(root "$p")" "$CALL_LOG")" "0"
done
expect_calls_has "keys directory chown root:root" "chown root:root $(dirname "$(root $KEYFILE_PATH)")"
expect_eq "key line is exactly restrict,command + key" "$(cat "$(root $KEYFILE_PATH)")" "restrict,command=\"/usr/local/bin/platform\" $KEY"
expect_eq "no from= unless given" "$(grep -c 'from=' "$(root $KEYFILE_PATH)")" "0"
expect_calls_has "useradd shell is the wrapper" "--shell /usr/local/bin/platform-login"
expect_calls_match "useradd groups are exactly docker (rejects docker,sudo)" '^useradd .*--groups docker( |$)'
expect_calls_has "useradd creates an ordinary home" "--create-home"
expect_calls_lacks "no group list with sudo anywhere" ",sudo"
expect_eq "deploy ends up in docker and only docker" "$(cat "$STATE/user_groups")" "deploy docker"
# the drop-in sorts after 10-hardening.conf, so an operator's earlier file cannot be shadowed by name
expect_eq "drop-in file name" "$(basename "$DROPIN_PATH")" "20-deploy.conf"
if [[ "$(basename "$DROPIN_PATH")" > "10-hardening.conf" ]]; then _pass; else _fail "drop-in sorts after 10-hardening.conf"; fi
expect_calls_has "the installer writes the drop-in at that path" "$(root "$DROPIN_PATH").new"
expect_calls_has "password locked" "passwd -l deploy"

# drop-in: exactly the intended directive set, one Match block that ends at the file end.
expected_dropin="$T_TMP/expected-dropin"
cat > "$expected_dropin" <<'EOF'
# Managed by platform/host/install-deploy-user.sh. Do not edit by hand; re-run the installer.
# The Match block ends at this file's end, so it cannot swallow later directives or other drop-ins.
Match User deploy
    AuthorizedKeysFile /etc/ssh/authorized_keys.d/deploy
    PermitTTY no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    GatewayPorts no
    PermitUserRC no
    PermitUserEnvironment no
EOF
if cmp -s "$expected_dropin" "$(root $DROPIN_PATH)"; then _pass; else _fail "drop-in is exactly the intended directive set" "$(diff "$expected_dropin" "$(root $DROPIN_PATH)")"; fi
expect_eq "exactly one Match line" "$(grep -c '^Match' "$(root $DROPIN_PATH)")" "1"
expect_eq "nothing after the Match block but indented directives" "$(sed -n '/^Match/,$p' "$(root $DROPIN_PATH)" | tail -n +2 | grep -vc '^    ')" "0"
expect_eq "no global directive follows Match" "$(sed -n '/^Match/,$p' "$(root $DROPIN_PATH)" | grep -c '^[A-Za-z]')" "1"

# sshd -t runs before the reload.
t_lines="$(grep -n -E '^(fakesudo )?sshd -t|^sshd -t' "$CALL_LOG" | head -n1 | cut -d: -f1)"
r_lines="$(grep -n -E 'systemctl reload' "$CALL_LOG" | head -n1 | cut -d: -f1)"
if [ -n "$t_lines" ] && [ -n "$r_lines" ] && [ "$t_lines" -lt "$r_lines" ]; then _pass; else _fail "sshd -t precedes reload" "sshd -t line '$t_lines', reload line '$r_lines'"; fi

# ---- 2. idempotent second run ----
t_reset_calls
tree_before="$(tree_snapshot)"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "second install succeeds" 0
expect_out_has "second run reports already" "already:"
expect_out_lacks "second run changes nothing" "changed:"
expect_eq "second run leaves the whole root tree identical" "$(tree_snapshot)" "$tree_before"
expect_eq "second run makes only read-only privileged calls" "$(non_readonly_priv_calls)" ""
expect_calls_has "the read-only allowlist is not vacuous (privilege probe ran)" "fakesudo true"
no_strays "second run"
expect_calls_lacks "second run does not reload sshd" "reload"
expect_calls_lacks "second run does not run sshd -t" "sshd -t"

# ---- 3. from= goes first, in its defined position ----
fresh
inst install --pubkey-file "$T_TMP/key.pub" --from "10.*,!bad.example"
expect_rc "from= accepted" 0
expect_eq "from= prefix position" "$(cat "$(root $KEYFILE_PATH)")" "from=\"10.*,!bad.example\",restrict,command=\"/usr/local/bin/platform\" $KEY"

# ---- 4. sshd -t failure: restore, no reload, non-zero ----
fresh
echo 1 > "$STATE/sshd_t_rc"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "sshd -t failure exits non-zero" 1
expect_calls_lacks "no reload after sshd -t failure" "reload"
if [ -e "$(root $DROPIN_PATH)" ]; then _fail "new drop-in removed after sshd -t failure"; else _pass; fi
expect_eq "sshd_config.d holds no file after the failed first install" "$(find "$(dirname "$(root $DROPIN_PATH)")" -type f | wc -l)" "0"
no_strays "sshd -t failure"

fresh
mkdir -p "$(dirname "$(root $DROPIN_PATH)")"
printf '%s\n' '# previous drop-in' > "$(root $DROPIN_PATH)"
echo 1 > "$STATE/sshd_t_rc"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "sshd -t failure with a prior drop-in exits non-zero" 1
expect_calls_lacks "no reload after sshd -t failure with a prior drop-in" "reload"
expect_eq "previous drop-in content restored" "$(cat "$(root $DROPIN_PATH)")" "# previous drop-in"
expect_eq "only the previous drop-in remains" "$(find "$(dirname "$(root $DROPIN_PATH)")" -type f)" "$(root $DROPIN_PATH)"
no_strays "sshd -t failure with a prior drop-in"

# The administrator's effective config changing is treated the same way.
fresh
touch "$STATE/leak"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "changed administrator config exits non-zero" 1
expect_calls_lacks "no reload when the administrator config changed" "reload"
if [ -e "$(root $DROPIN_PATH)" ]; then _fail "drop-in removed when the administrator config changed"; else _pass; fi
no_strays "administrator config changed"

# A global setting that wins over the Match block (sshd is first-value-wins) is caught before the reload.
fresh
touch "$STATE/global_override"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "global override of a restricted directive exits non-zero" 1
expect_out_has "global override names the unmet directive" "allowtcpforwarding no"
expect_calls_lacks "no reload when a global setting overrides the drop-in" "reload"
if [ -e "$(root $DROPIN_PATH)" ]; then _fail "drop-in removed when a global setting overrides it"; else _pass; fi
no_strays "global override"

fresh
mkdir -p "$(dirname "$(root $DROPIN_PATH)")"
printf '%s\n' '# previous drop-in' > "$(root $DROPIN_PATH)"
touch "$STATE/global_override"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "global override with a prior drop-in exits non-zero" 1
expect_eq "previous drop-in restored after a global override" "$(cat "$(root $DROPIN_PATH)")" "# previous drop-in"
no_strays "global override with a prior drop-in"

# A failing reload is a failure too (not silently ignored). Both reload attempts run; the intended drop-in stays in
# place (valid, but not active) and the message says to reload by hand.
fresh
touch "$STATE/systemctl_fail"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "failing reload exits non-zero" 1
expect_calls_has "reload tried as ssh" "systemctl reload ssh"
expect_calls_has "reload retried as sshd" "systemctl reload sshd"
expect_out_has "reload failure tells the operator what to do" "reload sshd by hand"
if cmp -s "$expected_dropin" "$(root $DROPIN_PATH)"; then _pass; else _fail "the validated drop-in stays in place after a reload failure"; fi
no_strays "reload failure"

# ---- 5. key and from= input: exit 2, nothing written ----
bad_key_case() {
  local label="$1" content="$2"
  fresh
  printf '%b' "$content" > "$T_TMP/bad.pub"
  inst install --pubkey-file "$T_TMP/bad.pub"
  expect_rc "bad key: $label" 2
  nothing_written "bad key: $label"
  # the remote side receives the same payload through --key and must reject it too (printf -v keeps trailing newlines)
  local value
  printf -v value '%b' "$content"
  fresh
  inst install --key "$value"
  expect_rc "bad key via --key: $label" 2
  nothing_written "bad key via --key: $label"
}
bad_key_case "multi-line" "$KEY\n$KEY\n"
bad_key_case "trailing blank line" "$KEY\n\n"
bad_key_case "option prefix" "command=\"/bin/sh\" $KEY\n"
bad_key_case "restrict prefix" "restrict $KEY\n"
bad_key_case "quote in comment" "$KEY\"x\n"
bad_key_case "single quote in comment" "$KEY'x\n"
bad_key_case "backslash in comment" "$KEY\\\\x\n"
bad_key_case "carriage return" "$KEY\r\n"
bad_key_case "empty file" ""
bad_key_case "blank line only" "\n"
bad_key_case "unknown key type" "ssh-dss AAAAB3NzaC1kc3M= x\n"
bad_key_case "not base64" "ssh-ed25519 not*base64 x\n"
bad_key_case "missing base64" "ssh-ed25519\n"
bad_key_case "semicolon comment" "$KEY;id\n"
bad_key_case "private key header" "-----BEGIN OPENSSH PRIV""ATE KEY-----\n"

fresh
inst install --pubkey-file "$T_TMP/does-not-exist.pub"
expect_rc "missing key file" 2
nothing_written "missing key file"

if [ "$(/usr/bin/id -u)" -ne 0 ]; then
  fresh
  chmod 000 "$T_TMP/key.pub"
  inst install --pubkey-file "$T_TMP/key.pub"
  expect_rc "unreadable key file" 2
  nothing_written "unreadable key file"
fi

from_case() {
  local label="$1" value="$2"
  fresh
  inst install --pubkey-file "$T_TMP/key.pub" --from "$value"
  expect_rc "bad from=: $label" 2
  nothing_written "bad from=: $label"
  # the remote side re-validates --from on the same path
  fresh
  inst install --key "$KEY" --from "$value"
  expect_rc "bad from= via --key: $label" 2
  nothing_written "bad from= via --key: $label"
  # and the client refuses it before any ssh call
  fresh
  run_cmd bash "$script" install --host pi-test --pubkey-file "$T_TMP/key.pub" --from "$value"
  expect_rc "bad from= under --host: $label" 2
  expect_calls_lacks "ssh not called for bad from=: $label" "ssh "
}
from_case "double quote" 'a"b'
from_case "single quote" "a'b"
from_case "space" 'a b'
from_case "semicolon" 'a;b'
from_case "newline" $'a\nb'
from_case "backslash" 'a\b'
from_case "dollar" '$x'
from_case "backtick" '`x`'
from_case "command option" 'a",command="/bin/sh'
from_case "empty" ''

fresh
inst install
expect_rc "install without a key" 2
nothing_written "install without a key"

fresh
inst install --key "command=\"/bin/sh\" $KEY"
expect_rc "remote-side --key re-validates an option prefix" 2
nothing_written "remote-side --key option prefix"

fresh
inst install --key "$KEY" --pubkey-file "$T_TMP/key.pub"
expect_rc "--key and --pubkey-file together" 2

# --admin-user is interpolated into `sshd -T -C user=...,host=...`: only a plain account name is accepted.
admin_case() {
  local label="$1" value="$2"
  fresh
  run_cmd bash "$script" install --pubkey-file "$T_TMP/key.pub" --admin-user "$value"
  expect_rc "bad --admin-user: $label" 2
  nothing_written "bad --admin-user: $label"
  run_cmd bash "$script" install --host pi-test --pubkey-file "$T_TMP/key.pub" --admin-user "$value"
  expect_rc "bad --admin-user under --host: $label" 2
  expect_calls_lacks "ssh not called for a bad --admin-user: $label" "ssh "
}
admin_case "criteria injection" 'x,addr=h'
admin_case "uppercase" 'Admin'
admin_case "leading digit" '1abc'
admin_case "space" 'a b'
admin_case "too long" 'abcdefghijklmnopqrstuvwxyzabcdefg'

# Privileged calls impossible (sudo -n without NOPASSWD): a clear early failure, nothing written.
fresh
INSTALL_DEPLOY_SUDO=nosudo
export INSTALL_DEPLOY_SUDO
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "install without usable privilege exits 1" 1
expect_out_has "privilege failure names NOPASSWD and the direct-run alternative" "passwordless sudo"
expect_eq "no file under the root without privilege" "$(find "$T_TMP/root" -mindepth 1 | wc -l)" "0"
expect_calls_lacks "no useradd without privilege" "useradd"
inst verify
expect_rc "verify without usable privilege exits 1" 1
expect_out_has "verify privilege failure is clear" "passwordless sudo"

fresh
inst frobnicate
expect_rc "unknown argument" 2

# ---- 6. --host: validated locally, forwarded quoted, script streamed ----
fresh
run_cmd bash "$script" install --host pi-test --pubkey-file "$T_TMP/key.pub" --from "10.*" --admin-user admin
expect_rc "--host install streams over ssh" 0
expect_calls_has "ssh batch mode" "ssh -o BatchMode=yes -- pi-test"
expect_calls_has "ssh remote command carries the quoted key" 'bash -s -- install --key ssh-ed25519\ AAAAC3NzaC1lZDI1NTE5AAAAIGFrZUtleUJ5dGVzRm9yVGVzdFVzZU9ubHkxMjM=\ deploy-test@laptop'
expect_calls_has "ssh remote command carries from=" '--from 10.\*'
if cmp -s "$script" "$STATE/ssh_stdin"; then _pass; else _fail "the installer itself is streamed to the remote bash"; fi
expect_eq "nothing was written locally under --host" "$(find "$T_TMP/root" -mindepth 1 | wc -l)" "0"

fresh
printf '%s\n' "command=\"/bin/sh\" $KEY" > "$T_TMP/bad.pub"
run_cmd bash "$script" install --host pi-test --pubkey-file "$T_TMP/bad.pub"
expect_rc "--host with a bad key" 2
expect_calls_lacks "ssh not called for a bad key" "ssh "

fresh
run_cmd bash "$script" install --host -oProxyCommand=x --pubkey-file "$T_TMP/key.pub"
expect_rc "option-looking --host refused" 2
expect_calls_lacks "ssh not called for an option-looking host" "ssh "

fresh
run_cmd bash "$script" verify --host pi-test
expect_rc "--host verify needs no key" 0
expect_calls_has "verify over ssh" "bash -s -- verify"

# ---- 7. prerequisites and existing-user handling ----
fresh
touch "$STATE/no_docker_group"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "missing docker group" 1
expect_calls_lacks "no useradd without the docker group" "useradd"

fresh
inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo "deploy docker sudo" > "$STATE/user_groups"
t_reset_calls
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "deploy in the sudo group is refused" 1
expect_out_has "sudo membership named" "sudo group"

fresh
inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo "/bin/bash" > "$STATE/user_shell"
echo "deploy" > "$STATE/user_groups"
echo 0 > "$STATE/user_locked"
t_reset_calls
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "drifted user is repaired" 0
expect_calls_has "wrong shell repaired" "usermod --shell /usr/local/bin/platform-login deploy"
expect_calls_has "missing docker group repaired" "usermod -aG docker deploy"
expect_calls_has "unlocked password re-locked" "passwd -l deploy"

# A changed key is rewritten (not "already").
fresh
inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
printf '%s\n' "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFub3RoZXJLZXlCeXRlc0ZvclRlc3RPbmx5MTIzNDU= other@laptop" > "$T_TMP/key2.pub"
inst install --pubkey-file "$T_TMP/key2.pub"
expect_rc "a different key is installed" 0
expect_out_has "key file changed" "changed: $(root $KEYFILE_PATH)"
expect_out_lacks "new key content replaces the old" "deploy-test@laptop"
expect_eq "key file holds the new key" "$(grep -c 'other@laptop' "$(root $KEYFILE_PATH)")" "1"

# ---- 8. verify / status ----
fresh
inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
inst verify
expect_rc "verify passes after install" 0
expect_out_lacks "verify has no FAIL after install" "FAIL"

# Negative cases: each tamper must turn verify red and status stays exit 0.
tamper_case() {
  local label="$1" want="$2"
  inst verify
  expect_rc "verify fails: $label" 1
  expect_out_has "verify names the problem: $label" "$want"
  inst status
  expect_rc "status exits 0 even when a check fails: $label" 0
  expect_out_has "status reports the failure: $label" "FAIL"
}

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
printf '%s %s\n' "$(root $KEYFILE_PATH)" "deploy:deploy" > "$STATE/stat_override"
tamper_case "key file owned by deploy" "key file owner/mode"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
chmod 664 "$(root $KEYFILE_PATH)"
tamper_case "key file group-writable" "key file owner/mode"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
printf '%s %s\n' "$(dirname "$(root $KEYFILE_PATH)")" "deploy:root" > "$STATE/stat_override"
tamper_case "keys directory owned by deploy" "keys directory owner/mode"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
printf '%s %s\n' "$(root $INSTALLED_DISPATCHER)" "deploy:deploy" > "$STATE/stat_override"
tamper_case "dispatcher owned by deploy" "dispatcher owner/mode"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
printf '%s %s\n' "$(root $INSTALLED_WRAPPER)" "deploy:deploy" > "$STATE/stat_override"
tamper_case "wrapper owned by deploy" "login wrapper owner/mode"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
printf '\n# tampered\n' >> "$(root $INSTALLED_DISPATCHER)"
tamper_case "dispatcher bytes altered" "dispatcher bytes differ"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
printf '\n# tampered\n' >> "$(root $INSTALLED_WRAPPER)"
tamper_case "wrapper bytes altered" "login wrapper bytes differ"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
printf 'command="/bin/sh" %s\n' "$KEY" > "$(root $KEYFILE_PATH)"
tamper_case "key line without restrict,command" "key file is not exactly one"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
printf '%s\nrestrict,command="/usr/local/bin/platform" %s\n' "$KEY" "$KEY" > "$(root $KEYFILE_PATH)"
tamper_case "key file with two lines" "key file is not exactly one"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
sed -i '/AllowTcpForwarding/d;/PermitTTY/d' "$(root $DROPIN_PATH)"
tamper_case "drop-in missing the no-forwarding lines" "drop-in content differs"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
sed -i '/AllowTcpForwarding/d' "$(root $DROPIN_PATH)"
inst verify
expect_out_has "effective forwarding check also fails" "effective 'allowtcpforwarding no'"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
rm -f "$(root $DROPIN_PATH)"
tamper_case "drop-in removed" "sshd drop-in missing"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo "deploy docker sudo" > "$STATE/user_groups"
tamper_case "deploy in sudo" "deploy is in the sudo group"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
# the realistic regression: sudo smuggled in through the comma-separated useradd/usermod group list
"$STUB_BIN/useradd" --groups docker,sudo deploy
expect_eq "the group stub splits on commas like id -nG" "$(cat "$STATE/user_groups")" "deploy docker sudo"
t_reset_calls
tamper_case "useradd --groups docker,sudo" "deploy is in the sudo group"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
sed -i '/AllowStreamLocalForwarding/d' "$(root $DROPIN_PATH)"
inst verify
expect_out_has "effective stream-local forwarding is asserted" "effective 'allowstreamlocalforwarding no'"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
sed -i '/GatewayPorts/d' "$(root $DROPIN_PATH)"
inst verify
expect_out_has "effective gatewayports is asserted" "effective 'gatewayports no'"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
sed -i '/PermitUserEnvironment/d' "$(root $DROPIN_PATH)"
inst verify
expect_out_has "effective permituserenvironment is asserted" "effective 'permituserenvironment no'"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo "deploy" > "$STATE/user_groups"
tamper_case "deploy not in docker" "deploy is not in the docker group"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo "/bin/bash" > "$STATE/user_shell"
tamper_case "login shell is a real shell" "login shell is '/bin/bash'"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo 0 > "$STATE/user_locked"
tamper_case "password unlocked" "password is not locked"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
rm -f "$STATE/user_shell"
tamper_case "user missing" "user deploy does not exist"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
touch "$STATE/leak_key"
tamper_case "administrator config references the deploy key file" "administrator's effective sshd config references"

fresh; inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
ln -sf "$T_TMP/elsewhere" "$(root $KEYFILE_PATH).link"
rm -f "$(root $KEYFILE_PATH)"
printf '%s\n' "$KEY" > "$T_TMP/elsewhere"
ln -s "$T_TMP/elsewhere" "$(root $KEYFILE_PATH)"
tamper_case "key file is a symlink" "key file is a symlink"

t_finish
