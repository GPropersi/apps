#!/usr/bin/env bash
# Stub tests for install-claude-access.sh. Every file the installer writes lands under INSTALL_CLAUDE_ROOT, the
# privilege prefix is a logging fakesudo, and useradd/usermod/passwd/getent/id/sshd/systemctl/visudo/chown/stat/ssh are
# stateful stubs. "Root-owned" is asserted through the logged chown calls (the stat stub reports root:root unless a
# test overrides it); modes are real. No address literals: the hygiene check flags them.
# SC2016: payloads are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# SC2154: $out is set by run_cmd in lib.sh.
# shellcheck disable=SC1091,SC2016,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/install-claude-access.sh"

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

# visudo -cf <file>: fails when $STATE/visudo_rc says so, and prints the offending file name like the real one.
mkstub visudo <<'EOF'
rc="$(cat "$STATE/visudo_rc" 2>/dev/null || echo 0)"
if [ "$rc" -ne 0 ]; then echo "visudo: syntax error near line 2" >&2; fi
exit "$rc"
EOF

mkstub getent <<'EOF'
case "$1 ${2:-}" in
  "passwd claude")
    [ -f "$STATE/user_shell" ] || exit 2
    echo "claude:x:1002:1002:platform claude debug:/home/claude:$(cat "$STATE/user_shell")"; exit 0 ;;
esac
exit 2
EOF

mkstub id <<'EOF'
if [ "$1" = "-nG" ] && [ "$2" = "claude" ]; then cat "$STATE/user_groups"; exit 0; fi
if [ "$1" = "-u" ] && [ "$2" = "claude" ]; then cat "$STATE/user_uid" 2>/dev/null || echo 1002; exit 0; fi
echo "admin"; exit 0
EOF

mkstub useradd <<'EOF'
echo "claude" > "$STATE/user_groups"
while [ $# -gt 0 ]; do
  case "$1" in
    --shell) echo "$2" > "$STATE/user_shell"; shift 2 ;;
    --groups) echo "claude ${2//,/ }" > "$STATE/user_groups"; shift 2 ;;
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
  -S) if [ "$(cat "$STATE/user_locked")" = "1" ]; then echo "claude L 2026-10-18 0 99999 7 -1"; else echo "claude P 2026-10-18 0 99999 7 -1"; fi ;;
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

# sshd: -t exits $STATE/sshd_t_rc (default 0); -T prints an effective config derived from the real drop-ins under
# INSTALL_CLAUDE_ROOT. States: leak_admin / leak_deploy make that user's config differ once the claude drop-in exists;
# global_override makes an earlier global setting win over the claude Match block; leak_key makes the administrator's
# AuthorizedKeysFile point at the claude key file.
mkstub sshd <<'EOF'
dropin="$INSTALL_CLAUDE_ROOT/etc/ssh/sshd_config.d/30-claude.conf"
if [ "$1" = "-t" ]; then exit "$(cat "$STATE/sshd_t_rc" 2>/dev/null || echo 0)"; fi
user=""
for a in "$@"; do case "$a" in user=*) user="${a#user=}"; user="${user%%,*}" ;; esac; done
declare -A cfg=([authorizedkeysfile]=".ssh/authorized_keys" [permittty]=yes [allowtcpforwarding]=yes
  [allowagentforwarding]=yes [x11forwarding]=yes [permittunnel]=no [permituserrc]=yes
  [allowstreamlocalforwarding]=yes [gatewayports]=yes [permituserenvironment]=no
  [passwordauthentication]=yes [kbdinteractiveauthentication]=yes [authenticationmethods]=any [authorizedkeyscommand]=none)
if [ -f "$dropin" ] && [ "$user" = "claude" ]; then
  in=0
  while IFS= read -r line; do
    case "$line" in
      "Match User claude") in=1 ;;
      "    "*) if [ "$in" -eq 1 ]; then set -- $line; k="$(echo "$1" | tr A-Z a-z)"; cfg[$k]="$2"; fi ;;
    esac
  done < "$dropin"
  if [ -f "$STATE/global_override" ]; then cfg[allowtcpforwarding]=yes; fi
  if [ -f "$STATE/global_akc" ]; then cfg[authorizedkeyscommand]=/opt/global-akc; fi
fi
if [ -f "$dropin" ] && [ "$user" = "admin" ] && [ -f "$STATE/leak_admin" ]; then cfg[permittty]=no; fi
if [ -f "$dropin" ] && [ "$user" = "deploy" ] && [ -f "$STATE/leak_deploy" ]; then cfg[permittty]=no; fi
if [ -f "$dropin" ] && [ "$user" = "admin" ] && [ -f "$STATE/leak_key" ]; then cfg[authorizedkeysfile]="/etc/ssh/authorized_keys.d/claude"; fi
if [ -f "$dropin" ] && [ "$user" = "deploy" ] && [ -f "$STATE/leak_key_deploy" ]; then cfg[authorizedkeysfile]="/etc/ssh/authorized_keys.d/claude"; fi
for k in "${!cfg[@]}"; do echo "$k ${cfg[$k]}"; done
EOF

# ssh: streamed installs keep the script; the live check is emulated by the remote command / identity.
mkstub ssh <<'EOF'
last="${*: -1}"
case "$last" in
  "bash -s"*) cat > "$STATE/ssh_stdin"; exit 0 ;;
esac
claude=0
idx=0
n=0
for a in "$@"; do
  n=$((n + 1))
  [ "$a" != "-i" ] || claude=1
  [ "$a" != "--" ] || idx=$n
done
words=("${@:$((idx + 2))}")
if [ "$claude" -eq 1 ]; then
  [ ! -f "$STATE/claude_down" ] || exit 255
  # switches that make a command succeed when it must be refused (live must then fail): id_ok traefik_ok logs_99999_ok
  n=0
  [ ! -f "$STATE/claude_count" ] || n="$(cat "$STATE/claude_count")"
  n=$((n + 1))
  echo "$n" > "$STATE/claude_count"
  if [ "$n" -eq 3 ] && [ -f "$STATE/kill_on_third" ]; then
    # emulate an interrupt of the installer in the middle of the claude commands
    for _ in $(seq 1 50); do [ -f "$STATE/installer_pid" ] && break; sleep 0.1; done
    kill -TERM "$(cat "$STATE/installer_pid")"
    exit 0
  fi
  case "${words[0]}" in
    ps) [ ! -f "$STATE/ps_fail" ] || exit 1; [ -f "$STATE/ps_empty" ] || echo "platform-livetest running"; exit 0 ;;
    stats | status) exit 0 ;;
    logs) if [ "${words[2]:-}" = "99999" ] && [ ! -f "$STATE/logs_99999_ok" ]; then exit 2; fi; exit 0 ;;
    restart)
      [ "${words[1]}" = "platform-livetest" ] && exit 0
      [ ! -f "$STATE/traefik_ok" ] || exit 0
      exit 1 ;;
    id) [ ! -f "$STATE/id_ok" ] || exit 0; exit 2 ;;
    *) exit 2 ;;
  esac
fi
cmd="${words[*]}"
case "$cmd" in
  *"docker ps"*"name="*) [ ! -f "$STATE/name_taken" ] || echo "0123456789ab"; exit 0 ;;
  *"docker ps"*) cat "$STATE/existing" 2>/dev/null; exit 0 ;;
  *"docker run"*) [ ! -f "$STATE/run_fail" ] || exit 1; [ ! -f "$STATE/run_bad_id" ] || { echo "not-an-id"; exit 0; }; touch "$STATE/container_exists"; echo deadbeefcafe; exit 0 ;;
  *"docker rm"*) [ ! -f "$STATE/rm_fail" ] || exit 1; rm -f "$STATE/container_exists"; exit 0 ;;
esac
exit 0
EOF

# ---- fixtures ----

KEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFrZUtleUJ5dGVzRm9yVGVzdFVzZU9ubHkxMjM= claude-test@laptop'
INSTALLED_ACCESS=/usr/local/bin/claude-access
INSTALLED_HELPER=/usr/local/lib/platform/claude-helper
HELPER_DIR=/usr/local/lib/platform
KEYFILE_PATH=/etc/ssh/authorized_keys.d/claude
DROPIN_PATH=/etc/ssh/sshd_config.d/30-claude.conf
SUDOERS_PATH=/etc/sudoers.d/platform-claude

# fresh: a clean root and clean state for the next scenario.
fresh() {
  rm -rf "$T_TMP/root" "$STATE"
  mkdir -p "$T_TMP/root" "$STATE"
  INSTALL_CLAUDE_ROOT="$T_TMP/root"
  export INSTALL_CLAUDE_ROOT
  INSTALL_CLAUDE_SUDO=fakesudo
  export INSTALL_CLAUDE_SUDO
  unset INSTALL_CLAUDE_VISUDO
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
non_readonly_priv_calls() { grep '^fakesudo ' "$CALL_LOG" | grep -vE '^fakesudo (true|sshd -T|stat|cat|getent|id|passwd -S|test|visudo -cf)( |$)' || true; }

# tree_snapshot: names, modes, sizes, mtimes and checksums of everything under the root.
tree_snapshot() {
  find "$T_TMP/root" -mindepth 1 -exec /usr/bin/stat -c '%n %a %s %Y' {} + | sort
  find "$T_TMP/root" -type f -exec cksum {} + | sort
}

expect_calls_match() {
  if grep -qE -- "$2" "$CALL_LOG"; then _pass; else _fail "$1" "call log has no line matching: $2"; fi
}

no_strays() {
  expect_eq "$1: no stray .new/.bak/.backup files" "$(find "$T_TMP/root" \( -name '*.new' -o -name '*.bak' -o -name '*.backup' \) | wc -l)" "0"
}

# apply_printed_sudoers: do what the operator does with the printed command: write the fragment between the heredoc
# markers of the last install output to the sudoers path, root:root 0440.
apply_printed_sudoers() {
  mkdir -p "$(dirname "$(root $SUDOERS_PATH)")"
  printf '%s\n' "$out" | sed -n "/<<'SUDOERS_EOF'\$/,/^SUDOERS_EOF\$/p" | sed '1d;$d' > "$(root $SUDOERS_PATH)"
  chmod 440 "$(root $SUDOERS_PATH)"
}

# ---- 1. fresh install ----
fresh
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "fresh install succeeds" 0
expect_out_has "fresh install reports done" "install-claude-access: done"
if cmp -s "$here/claude-access.sh" "$(root $INSTALLED_ACCESS)"; then _pass; else _fail "installed wrapper bytes equal the tracked source"; fi
if cmp -s "$here/claude-helper.sh" "$(root $INSTALLED_HELPER)"; then _pass; else _fail "installed helper bytes equal the tracked source"; fi
expect_eq "wrapper mode" "$(/usr/bin/stat -c %a "$(root $INSTALLED_ACCESS)")" "755"
expect_eq "helper mode" "$(/usr/bin/stat -c %a "$(root $INSTALLED_HELPER)")" "755"
expect_eq "helper dir mode" "$(/usr/bin/stat -c %a "$(root $HELPER_DIR)")" "755"
expect_eq "key file mode" "$(/usr/bin/stat -c %a "$(root $KEYFILE_PATH)")" "644"
expect_eq "keys dir mode" "$(/usr/bin/stat -c %a "$(dirname "$(root $KEYFILE_PATH)")")" "755"
expect_eq "drop-in mode" "$(/usr/bin/stat -c %a "$(root $DROPIN_PATH)")" "644"
for p in "$INSTALLED_ACCESS" "$INSTALLED_HELPER" "$KEYFILE_PATH" "$DROPIN_PATH"; do
  expect_calls_has "chown root:root for $p" "chown root:root $(root "$p").new"
  c_line="$(grep -nF -m1 -- "chown root:root $(root "$p").new" "$CALL_LOG" | cut -d: -f1)"
  m_line="$(grep -nF -m1 -- "mv -f -- $(root "$p").new $(root "$p")" "$CALL_LOG" | cut -d: -f1)"
  if [ -n "$c_line" ] && [ -n "$m_line" ] && [ "$c_line" -lt "$m_line" ]; then _pass; else _fail "chown precedes mv for $p" "chown line '$c_line', mv line '$m_line'"; fi
  expect_eq "no chown aimed at the live path $p" "$(grep -cxF "chown root:root $(root "$p")" "$CALL_LOG")" "0"
done
expect_calls_has "helper directory chown root:root" "chown root:root $(root $HELPER_DIR)"
expect_calls_has "keys directory chown root:root" "chown root:root $(dirname "$(root $KEYFILE_PATH)")"
expect_eq "key line is exactly restrict,command + key" "$(cat "$(root $KEYFILE_PATH)")" "restrict,command=\"/usr/local/bin/claude-access\" $KEY"
expect_eq "no from= unless given" "$(grep -c 'from=' "$(root $KEYFILE_PATH)")" "0"
expect_calls_has "useradd shell is the wrapper" "--shell /usr/local/bin/claude-access"
expect_calls_lacks "useradd gives no extra groups" "--groups"
expect_calls_lacks "no docker or sudo group assignment" "docker"
expect_eq "claude ends up in no group but its own" "$(cat "$STATE/user_groups")" "claude"
expect_calls_has "password locked" "passwd -l claude"
expect_eq "drop-in file name" "$(basename "$DROPIN_PATH")" "30-claude.conf"
if [[ "$(basename "$DROPIN_PATH")" > "10-hardening.conf" ]]; then _pass; else _fail "drop-in sorts after 10-hardening.conf"; fi
# the helper and wrapper are separate payloads, separate from the deploy installer's files
if [ -e "$(root /usr/local/bin/platform)" ] || [ -e "$(root /etc/ssh/sshd_config.d/20-deploy.conf)" ]; then _fail "the claude installer does not touch the deploy files"; else _pass; fi

expected_dropin="$T_TMP/expected-dropin"
cat > "$expected_dropin" <<'EOF'
# Managed by platform/host/install-claude-access.sh. Do not edit by hand; re-run the installer.
# The Match block ends at this file's end, so it cannot swallow later directives or other drop-ins.
Match User claude
    AuthorizedKeysFile /etc/ssh/authorized_keys.d/claude
    PermitTTY no
    AllowTcpForwarding no
    AllowAgentForwarding no
    AllowStreamLocalForwarding no
    X11Forwarding no
    PermitTunnel no
    GatewayPorts no
    PermitUserRC no
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AuthenticationMethods publickey
    AuthorizedKeysCommand none
EOF
if cmp -s "$expected_dropin" "$(root $DROPIN_PATH)"; then _pass; else _fail "drop-in is exactly the intended directive set" "$(diff "$expected_dropin" "$(root $DROPIN_PATH)")"; fi
expect_eq "exactly one Match line" "$(grep -c '^Match' "$(root $DROPIN_PATH)")" "1"
for d in "PasswordAuthentication no" "KbdInteractiveAuthentication no" "AuthenticationMethods publickey" "AuthorizedKeysCommand none"; do
  expect_eq "drop-in pins: $d" "$(grep -cxF "    $d" "$(root $DROPIN_PATH)")" "1"
done
expect_eq "nothing after the Match block but indented directives" "$(sed -n '/^Match/,$p' "$(root $DROPIN_PATH)" | tail -n +2 | grep -vc '^    ')" "0"
expect_eq "no global directive follows Match" "$(sed -n '/^Match/,$p' "$(root $DROPIN_PATH)" | grep -c '^[A-Za-z]')" "1"

t_lines="$(grep -n -E '^(fakesudo )?sshd -t|^sshd -t' "$CALL_LOG" | head -n1 | cut -d: -f1)"
r_lines="$(grep -n -E 'systemctl reload' "$CALL_LOG" | head -n1 | cut -d: -f1)"
if [ -n "$t_lines" ] && [ -n "$r_lines" ] && [ "$t_lines" -lt "$r_lines" ]; then _pass; else _fail "sshd -t precedes reload" "sshd -t line '$t_lines', reload line '$r_lines'"; fi

# ---- 1b. the sudoers fragment: validated with visudo -cf, printed, never installed by the script ----
expect_calls_match "visudo -cf ran on a fragment" '^fakesudo visudo -cf '
expect_out_has "validated message" "validated: sudoers fragment"
expect_out_has "the install command is printed" "sudo install -m 0440 -o root -g root /dev/stdin /etc/sudoers.d/platform-claude"
if [ -e "$(root $SUDOERS_PATH)" ]; then _fail "the script does not install the sudoers fragment"; else _pass; fi
frag="$(printf '%s\n' "$out" | sed -n "/<<'SUDOERS_EOF'\$/,/^SUDOERS_EOF\$/p" | sed '1d;$d')"
expect_eq "fragment has exactly one non-comment line" "$(printf '%s\n' "$frag" | grep -vc '^#')" "1"
frag_rule="$(printf '%s\n' "$frag" | grep -v '^#')"
expect_eq "fragment is exactly one literal command" "$frag_rule" "claude ALL=(root) NOPASSWD: /usr/local/lib/platform/claude-helper"
cmd_part="${frag_rule#*NOPASSWD: }"
if [[ "$cmd_part" =~ ^/[A-Za-z0-9/._-]+$ ]]; then _pass; else _fail "the command part is one literal path" "$cmd_part"; fi
case "$cmd_part" in *'*'* | *ALL* | *,* | *' '*) _fail "no wildcard, ALL, list or arguments in the command part" "$cmd_part" ;; *) _pass ;; esac
expect_eq "the command is the installed helper path" "$cmd_part" "$INSTALLED_HELPER"

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

# ---- 3. from= goes first ----
fresh
inst install --pubkey-file "$T_TMP/key.pub" --from "10.*,!bad.example"
expect_rc "from= accepted" 0
expect_eq "from= prefix position" "$(cat "$(root $KEYFILE_PATH)")" "from=\"10.*,!bad.example\",restrict,command=\"/usr/local/bin/claude-access\" $KEY"
# verify accepts the from="...", form (the optional prefix branch of the key-line check)
apply_printed_sudoers
inst verify
expect_rc "verify passes after a --from install" 0
expect_out_lacks "verify has no FAIL after a --from install" "FAIL"

# ---- 4. sshd -t failure and unchanged-config guards: restore, no reload, non-zero ----
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
chmod 600 "$(root $DROPIN_PATH)"
echo 1 > "$STATE/sshd_t_rc"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "sshd -t failure with a prior drop-in exits non-zero" 1
expect_calls_has "the prior drop-in is backed up through privilege, not an unprivileged cp" "fakesudo cat -- $(root $DROPIN_PATH)"
expect_calls_lacks "no reload after sshd -t failure with a prior drop-in" "reload"
expect_eq "previous drop-in content restored" "$(cat "$(root $DROPIN_PATH)")" "# previous drop-in"
expect_eq "only the previous drop-in remains" "$(find "$(dirname "$(root $DROPIN_PATH)")" -type f)" "$(root $DROPIN_PATH)"
no_strays "sshd -t failure with a prior drop-in"

fresh
touch "$STATE/leak_admin"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "changed administrator config exits non-zero" 1
expect_calls_lacks "no reload when the administrator config changed" "reload"
if [ -e "$(root $DROPIN_PATH)" ]; then _fail "drop-in removed when the administrator config changed"; else _pass; fi
no_strays "administrator config changed"

fresh
touch "$STATE/leak_deploy"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "changed deploy config exits non-zero" 1
expect_calls_lacks "no reload when deploy's config changed" "reload"
if [ -e "$(root $DROPIN_PATH)" ]; then _fail "drop-in removed when deploy's config changed"; else _pass; fi
no_strays "deploy config changed"

fresh
touch "$STATE/global_override"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "global override of a restricted directive exits non-zero" 1
expect_out_has "global override names the unmet directive" "allowtcpforwarding no"
expect_calls_lacks "no reload when a global setting overrides the drop-in" "reload"
if [ -e "$(root $DROPIN_PATH)" ]; then _fail "drop-in removed when a global setting overrides it"; else _pass; fi
no_strays "global override"

fresh
touch "$STATE/global_akc"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "a global AuthorizedKeysCommand exits non-zero" 1
expect_out_has "global AuthorizedKeysCommand names the unmet directive" "authorizedkeyscommand none"
expect_calls_lacks "no reload when a global AuthorizedKeysCommand wins" "reload"
if [ -e "$(root $DROPIN_PATH)" ]; then _fail "drop-in removed when a global AuthorizedKeysCommand wins"; else _pass; fi

fresh
mkdir -p "$(dirname "$(root $DROPIN_PATH)")"
printf '%s\n' '# previous drop-in' > "$(root $DROPIN_PATH)"
touch "$STATE/global_override"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "global override with a prior drop-in exits non-zero" 1
expect_eq "previous drop-in restored after a global override" "$(cat "$(root $DROPIN_PATH)")" "# previous drop-in"
no_strays "global override with a prior drop-in"

fresh
touch "$STATE/systemctl_fail"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "failing reload exits non-zero" 1
expect_calls_has "reload tried as ssh" "systemctl reload ssh"
expect_calls_has "reload retried as sshd" "systemctl reload sshd"
expect_out_has "reload failure tells the operator what to do" "reload sshd by hand"
if cmp -s "$expected_dropin" "$(root $DROPIN_PATH)"; then _pass; else _fail "the validated drop-in stays in place after a reload failure"; fi

# ---- 4b. visudo failure: nothing is installed; visudo absent: reported as a skip ----
fresh
echo 1 > "$STATE/visudo_rc"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "visudo -cf failure exits non-zero" 1
expect_out_has "visudo error is printed" "syntax error"
expect_out_has "the failure says nothing was installed" "nothing was installed"
expect_eq "visudo failure: no file under the root" "$(find "$T_TMP/root" -mindepth 1 | wc -l)" "0"
expect_calls_lacks "visudo failure: no useradd" "useradd"
expect_calls_lacks "visudo failure: no sshd reload" "reload"
expect_out_lacks "visudo failure: the install command is not printed" "sudo install -m 0440"

fresh
INSTALL_CLAUDE_VISUDO=no-such-visudo-command
export INSTALL_CLAUDE_VISUDO
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "visudo absent still installs" 0
expect_out_has "visudo absence is a skip" "SKIP: visudo not found"
expect_out_lacks "visudo absence is not reported as validated" "validated: sudoers fragment"
expect_calls_lacks "visudo was not run" "visudo"
unset INSTALL_CLAUDE_VISUDO

# ---- 5. key and from= input: exit 2, nothing written ----
bad_key_case() {
  local label="$1" content="$2"
  fresh
  printf '%b' "$content" > "$T_TMP/bad.pub"
  inst install --pubkey-file "$T_TMP/bad.pub"
  expect_rc "bad key: $label" 2
  nothing_written "bad key: $label"
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
bad_key_case "four padding characters" "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFrZQ==== x\n"

# Accepted key shapes: every supported type, padded and unpadded base64, with and without a comment.
good_key_case() {
  local label="$1" value="$2"
  fresh
  printf '%s\n' "$value" > "$T_TMP/good.pub"
  inst install --pubkey-file "$T_TMP/good.pub"
  expect_rc "accepted key: $label" 0
  expect_eq "accepted key is written verbatim: $label" "$(cat "$(root $KEYFILE_PATH)")" "restrict,command=\"/usr/local/bin/claude-access\" $value"
  fresh
  inst install --key "$value"
  expect_rc "accepted key via --key: $label" 0
  apply_printed_sudoers
  inst verify
  expect_rc "verify accepts the key line: $label" 0
}
good_key_case "ssh-rsa padded with comment" "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7 user@host"
good_key_case "ssh-rsa unpadded no comment" "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC7"
good_key_case "ecdsa nistp256" "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= c"
good_key_case "ecdsa nistp384" "ecdsa-sha2-nistp384 AAAAE2VjZHNhLXNoYTItbmlzdHAzODQ="
good_key_case "ecdsa nistp521" "ecdsa-sha2-nistp521 AAAAE2VjZHNhLXNoYTItbmlzdHA1MjE== c"
good_key_case "sk-ssh-ed25519" "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29t c"
good_key_case "sk-ecdsa" "sk-ecdsa-sha2-nistp256@openssh.com AAAAInNrLWVjZHNhLXNoYTItbmlzdHAyNTZAb3BlbnNzaC5jb20="

# Accepted from= values include the punctuation / ? and :
for from_ok in 'lan.example/24' 'host?.example' 'fe80::1' 'a.example,!b.example'; do
  fresh
  inst install --pubkey-file "$T_TMP/key.pub" --from "$from_ok"
  expect_rc "accepted from=: $from_ok" 0
  apply_printed_sudoers
  inst verify
  expect_rc "verify accepts from=: $from_ok" 0
done

fresh
inst install --pubkey-file "$T_TMP/does-not-exist.pub"
expect_rc "missing key file" 2
nothing_written "missing key file"

from_case() {
  local label="$1" value="$2"
  fresh
  inst install --pubkey-file "$T_TMP/key.pub" --from "$value"
  expect_rc "bad from=: $label" 2
  nothing_written "bad from=: $label"
  fresh
  inst install --key "$KEY" --from "$value"
  expect_rc "bad from= via --key: $label" 2
  nothing_written "bad from= via --key: $label"
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
inst install --key "$KEY" --pubkey-file "$T_TMP/key.pub"
expect_rc "--key and --pubkey-file together" 2

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

fresh
INSTALL_CLAUDE_SUDO=nosudo
export INSTALL_CLAUDE_SUDO
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "install without usable privilege exits 1" 1
expect_out_has "privilege failure names NOPASSWD and the direct-run alternative" "passwordless sudo"
expect_eq "no file under the root without privilege" "$(find "$T_TMP/root" -mindepth 1 | wc -l)" "0"
expect_calls_lacks "no useradd without privilege" "useradd"
inst verify
expect_rc "verify without usable privilege exits 1" 1

fresh
inst frobnicate
expect_rc "unknown argument" 2
inst install --live --pubkey-file "$T_TMP/key.pub"
expect_rc "--live is only valid with verify" 2

# ---- 6. --host: validated locally, forwarded quoted, script streamed ----
fresh
run_cmd bash "$script" install --host pi-test --pubkey-file "$T_TMP/key.pub" --from "10.*" --admin-user admin
expect_rc "--host install streams over ssh" 0
expect_calls_has "ssh batch mode" "ssh -o BatchMode=yes -- pi-test"
expect_calls_has "ssh remote command carries the quoted key" 'bash -s -- install --key ssh-ed25519\ AAAAC3NzaC1lZDI1NTE5AAAAIGFrZUtleUJ5dGVzRm9yVGVzdFVzZU9ubHkxMjM=\ claude-test@laptop'
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

# ---- 7. existing-user handling ----
fresh
inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo "claude docker" > "$STATE/user_groups"
t_reset_calls
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "claude in the docker group is refused" 1
expect_out_has "docker membership named" "docker group"

fresh
inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo "claude sudo" > "$STATE/user_groups"
t_reset_calls
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "claude in the sudo group is refused" 1
expect_out_has "sudo membership named" "sudo group"

fresh
inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo "claude disk" > "$STATE/user_groups"
t_reset_calls
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "claude in an extra group (disk) is refused" 1
expect_out_has "extra group named" "groups other than its own"

fresh
inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo "other" > "$STATE/user_groups"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "claude whose only group is not its own is refused" 1

fresh
inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo 0 > "$STATE/user_uid"
t_reset_calls
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "claude with uid 0 is refused" 1
expect_out_has "uid 0 named" "uid is not a nonzero number"

fresh
inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
echo "/bin/bash" > "$STATE/user_shell"
echo 0 > "$STATE/user_locked"
t_reset_calls
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "drifted user is repaired" 0
expect_calls_has "wrong shell repaired" "usermod --shell /usr/local/bin/claude-access claude"
expect_calls_has "unlocked password re-locked" "passwd -l claude"

fresh
inst install --pubkey-file "$T_TMP/key.pub" >/dev/null
printf '%s\n' "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFub3RoZXJLZXlCeXRlc0ZvclRlc3RPbmx5MTIzNDU= other@laptop" > "$T_TMP/key2.pub"
inst install --pubkey-file "$T_TMP/key2.pub"
expect_rc "a different key is installed" 0
expect_out_has "key file changed" "changed: $(root $KEYFILE_PATH)"
expect_eq "key file holds the new key" "$(grep -c 'other@laptop' "$(root $KEYFILE_PATH)")" "1"
expect_eq "the old key is gone" "$(grep -c 'claude-test@laptop' "$(root $KEYFILE_PATH)")" "0"

# ---- 8. verify / status ----
fresh
inst install --pubkey-file "$T_TMP/key.pub"
apply_printed_sudoers
inst verify
expect_rc "verify passes after install and the printed sudoers install" 0
expect_out_lacks "verify has no FAIL after install" "FAIL"
expect_out_has "verify asserts claude is not in the docker group" "claude is not in the docker group"

tamper_case() {
  local label="$1" want="$2"
  inst verify
  expect_rc "verify fails: $label" 1
  expect_out_has "verify names the problem: $label" "$want"
  inst status
  expect_rc "status exits 0 even when a check fails: $label" 0
  expect_out_has "status reports the failure: $label" "FAIL"
}
# installed_fresh: install, then do what the operator does with the printed sudoers command.
installed_fresh() {
  fresh
  inst install --pubkey-file "$T_TMP/key.pub"
  apply_printed_sudoers
}

installed_fresh
inst verify
expect_rc "verify passes with the fragment in place" 0

installed_fresh
rm -f "$(root $SUDOERS_PATH)"
tamper_case "sudoers fragment not installed" "sudoers fragment missing"

installed_fresh
chmod 640 "$(root $SUDOERS_PATH)"
tamper_case "sudoers fragment mode" "sudoers fragment owner/mode"

installed_fresh
printf '%s %s\n' "$(root $SUDOERS_PATH)" "claude:claude" > "$STATE/stat_override"
tamper_case "sudoers fragment owned by claude" "sudoers fragment owner/mode"

installed_fresh
chmod 640 "$(root $SUDOERS_PATH)"
printf '%s\n' 'claude ALL=(ALL) NOPASSWD: ALL' >> "$(root $SUDOERS_PATH)"
chmod 440 "$(root $SUDOERS_PATH)"
tamper_case "sudoers fragment widened" "sudoers fragment content differs"

installed_fresh
printf '%s %s\n' "$(root $KEYFILE_PATH)" "claude:claude" > "$STATE/stat_override"
tamper_case "key file owned by claude" "key file owner/mode"

installed_fresh
chmod 664 "$(root $KEYFILE_PATH)"
tamper_case "key file group-writable" "key file owner/mode"

installed_fresh
printf '%s %s\n' "$(dirname "$(root $KEYFILE_PATH)")" "claude:root" > "$STATE/stat_override"
tamper_case "keys directory owned by claude" "keys directory owner/mode"

installed_fresh
printf '%s %s\n' "$(root $INSTALLED_ACCESS)" "claude:claude" > "$STATE/stat_override"
tamper_case "wrapper owned by claude" "access wrapper owner/mode"

installed_fresh
chmod 775 "$(root $INSTALLED_ACCESS)"
tamper_case "wrapper group-writable" "access wrapper owner/mode"

installed_fresh
printf '%s %s\n' "$(root $INSTALLED_HELPER)" "claude:claude" > "$STATE/stat_override"
tamper_case "helper owned by claude" "helper owner/mode"

installed_fresh
printf '%s %s\n' "$(root $HELPER_DIR)" "claude:claude" > "$STATE/stat_override"
tamper_case "helper directory owned by claude" "helper directory owner/mode"

installed_fresh
printf '\n# tampered\n' >> "$(root $INSTALLED_ACCESS)"
tamper_case "wrapper bytes altered" "access wrapper bytes differ"

installed_fresh
printf '\n# tampered\n' >> "$(root $INSTALLED_HELPER)"
tamper_case "helper bytes altered" "helper bytes differ"

installed_fresh
printf 'command="/bin/sh" %s\n' "$KEY" > "$(root $KEYFILE_PATH)"
tamper_case "key line without restrict,command" "key file is not exactly one"

installed_fresh
printf '%s\nrestrict,command="/usr/local/bin/claude-access" %s\n' "$KEY" "$KEY" > "$(root $KEYFILE_PATH)"
tamper_case "key file with two lines" "key file is not exactly one"

installed_fresh
printf 'restrict,command="/usr/local/bin/platform" %s\n' "$KEY" > "$(root $KEYFILE_PATH)"
tamper_case "key line forces another command" "key file is not exactly one"

installed_fresh
sed -i '/AllowTcpForwarding/d;/PermitTTY/d' "$(root $DROPIN_PATH)"
tamper_case "drop-in missing the no-forwarding lines" "drop-in content differs"

installed_fresh
sed -i '/AllowTcpForwarding/d' "$(root $DROPIN_PATH)"
inst verify
expect_out_has "effective forwarding check also fails" "effective 'allowtcpforwarding no'"

installed_fresh
sed -i '/PermitTTY/d' "$(root $DROPIN_PATH)"
inst verify
expect_out_has "effective permittty is asserted" "effective 'permittty no'"

installed_fresh
rm -f "$(root $DROPIN_PATH)"
tamper_case "drop-in removed" "sshd drop-in missing"

installed_fresh
echo "claude docker" > "$STATE/user_groups"
tamper_case "claude in docker" "claude is in the docker group"

installed_fresh
echo "claude sudo" > "$STATE/user_groups"
tamper_case "claude in sudo" "claude is in the sudo group"

installed_fresh
echo "claude disk" > "$STATE/user_groups"
tamper_case "claude in an extra group (disk)" "claude is in groups other than its own"

installed_fresh
echo 0 > "$STATE/user_uid"
tamper_case "claude with uid 0" "uid is not a nonzero number"

installed_fresh
sed -i '/PasswordAuthentication/d' "$(root $DROPIN_PATH)"
inst verify
expect_out_has "effective passwordauthentication is asserted" "effective 'passwordauthentication no'"

installed_fresh
sed -i '/KbdInteractiveAuthentication/d' "$(root $DROPIN_PATH)"
inst verify
expect_out_has "effective kbdinteractiveauthentication is asserted" "effective 'kbdinteractiveauthentication no'"

installed_fresh
sed -i '/AuthenticationMethods/d' "$(root $DROPIN_PATH)"
inst verify
expect_out_has "effective authenticationmethods is asserted" "effective 'authenticationmethods publickey'"

installed_fresh
touch "$STATE/global_akc"
tamper_case "a global AuthorizedKeysCommand wins" "effective 'authorizedkeyscommand none' is not set"

installed_fresh
echo "/bin/bash" > "$STATE/user_shell"
tamper_case "login shell is a real shell" "login shell is '/bin/bash'"

installed_fresh
echo 0 > "$STATE/user_locked"
tamper_case "password unlocked" "password is not locked"

installed_fresh
rm -f "$STATE/user_shell"
tamper_case "user missing" "user claude does not exist"

installed_fresh
touch "$STATE/leak_key"
tamper_case "administrator config references the claude key file" "administrator's effective sshd config references"

installed_fresh
touch "$STATE/leak_key_deploy"
tamper_case "deploy config references the claude key file" "deploy's effective sshd config references"

installed_fresh
ln -sf "$T_TMP/elsewhere" "$(root $KEYFILE_PATH).link"
rm -f "$(root $KEYFILE_PATH)"
printf '%s\n' "$KEY" > "$T_TMP/elsewhere"
ln -s "$T_TMP/elsewhere" "$(root $KEYFILE_PATH)"
tamper_case "key file is a symlink" "key file is a symlink"

installed_fresh
cp -- "$(root $SUDOERS_PATH)" "$T_TMP/sudoers-elsewhere"
rm -f "$(root $SUDOERS_PATH)"
ln -s "$T_TMP/sudoers-elsewhere" "$(root $SUDOERS_PATH)"
tamper_case "sudoers fragment is a symlink" "sudoers fragment is a symlink"

# Repair: an installed file with the wrong mode is rewritten by a re-run, and verify is then clean.
installed_fresh
chmod 666 "$(root $INSTALLED_ACCESS)"
chmod 600 "$(root $KEYFILE_PATH)"
inst install --pubkey-file "$T_TMP/key.pub"
expect_rc "re-install over drifted modes succeeds" 0
expect_out_has "the drifted wrapper is rewritten" "changed: $(root $INSTALLED_ACCESS)"
expect_out_has "the drifted key file is rewritten" "changed: $(root $KEYFILE_PATH)"
expect_eq "wrapper mode is repaired" "$(/usr/bin/stat -c %a "$(root $INSTALLED_ACCESS)")" "755"
expect_eq "key file mode is repaired" "$(/usr/bin/stat -c %a "$(root $KEYFILE_PATH)")" "644"
inst verify
expect_rc "verify is clean after the repair" 0
expect_out_lacks "no FAIL after the repair" "FAIL"

# ---- 9. verify --live ----
IDENT="$T_TMP/id_test"
printf 'not a real key\n' > "$IDENT"

live() { t_reset_calls; run_cmd bash "$script" verify --live --identity "$IDENT" --host pi-test; }
admin_ssh_calls() { grep '^ssh ' "$CALL_LOG" | grep -v -- ' -i ' || true; }
claude_ssh_calls() { grep '^ssh ' "$CALL_LOG" | grep -- ' -i ' || true; }

fresh
live
expect_rc "live check passes" 0
expect_out_has "live summary" "all live checks passed"
expect_calls_has "the test container is created with the reserved label" "docker run -d --name platform-livetest --label platform.app=platform-livetest docker.io/library/busybox:1.37.0 sleep 300"
if [ -e "$STATE/container_exists" ]; then _fail "the test container is removed after a passing run"; else _pass; fi
expect_calls_has "the container removal ran, by the id docker run printed" "docker rm -f deadbeefcafe"
expect_calls_lacks "the container is never removed by name" "docker rm -f platform-livetest"
expect_calls_has "the name is pre-checked as well as the label" "docker ps -a -q --filter 'name=^platform-livetest\$'"
expect_eq "docker commands run only as the administrator (no -i)" "$(claude_ssh_calls | grep -c 'docker')" "0"
expect_eq "every docker command went through the administrator ssh" "$(admin_ssh_calls | grep -c 'sudo -n docker')" "4"
expect_eq "every live ssh call carries the timeout options" "$(grep '^ssh ' "$CALL_LOG" | grep -c -- '-o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3')" "$(grep -c '^ssh ' "$CALL_LOG")"
expect_eq "the claude commands all use the identity file, identities-only" "$(claude_ssh_calls | grep -c -- "-i $IDENT -o IdentitiesOnly=yes")" "$(claude_ssh_calls | wc -l)"
expect_eq "the claude commands run as the claude user" "$(claude_ssh_calls | grep -c -- '-o User=claude')" "$(claude_ssh_calls | wc -l)"
expect_eq "the administrator calls carry no identity option" "$(admin_ssh_calls | grep -c 'IdentitiesOnly')" "0"
expect_calls_has "claude ps is run" "ssh -i $IDENT -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -o User=claude -- pi-test ps"
expect_calls_has "the admin docker call is run with batch mode and timeouts" "ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 -- pi-test sudo -n docker run -d"
expect_calls_has "claude restart of the test app is run" "-- pi-test restart platform-livetest"
expect_calls_has "claude restart of an unlabelled name is probed" "-- pi-test restart traefik"
expect_calls_has "an arbitrary command is probed" "-- pi-test id"
expect_eq "the private key is never forwarded as content" "$(grep -c 'not a real key' "$CALL_LOG")" "0"

# negative: a claude command that does not behave as expected fails the run, and the container is still removed
fresh
touch "$STATE/ps_fail"
live
expect_rc "a failing claude ps fails the live run" 1
expect_out_has "the failure is named" "FAIL: claude ps lists the test container"
if [ -e "$STATE/container_exists" ]; then _fail "the test container is removed after a failing run"; else _pass; fi
expect_calls_has "removal ran after the failure" "docker rm -f deadbeefcafe"

# negative: every claude call dies (the identity is refused): the container is still removed
fresh
touch "$STATE/claude_down"
live
expect_rc "a refused identity fails the live run" 1
if [ -e "$STATE/container_exists" ]; then _fail "the test container is removed when every claude call fails"; else _pass; fi

# negative: container creation fails: nothing is left, the run stops with a clear error, removal is still attempted
fresh
touch "$STATE/run_fail"
live
expect_rc "a failed create exits non-zero" 1
expect_out_has "create failure named" "could not create the test container"
expect_calls_lacks "nothing is removed when the create failed (no id was captured)" "docker rm"
expect_calls_lacks "no claude command after a failed create" "User=claude"

# negative: an unlabelled container already named platform-livetest is refused, never run over, never removed
fresh
touch "$STATE/name_taken"
live
expect_rc "a same-named unlabelled container stops the run" 1
expect_out_has "name clash named" "named platform-livetest already exists"
expect_calls_lacks "no docker run over a name clash" "docker run"
expect_calls_lacks "no docker rm of a container we did not create" "docker rm"
expect_calls_lacks "no claude command after a name clash" "User=claude"

# negative: docker run prints something that is not a container id: stop, remove nothing
fresh
touch "$STATE/run_bad_id"
live
expect_rc "a malformed container id stops the run" 1
expect_out_has "malformed id named" "unexpected container id"
expect_calls_lacks "no removal by a malformed id" "docker rm"

# negative: commands that must be refused but succeed fail the run, each with its own FAIL line
fresh
touch "$STATE/id_ok"
live
expect_rc "an arbitrary command that succeeds fails the live run" 1
expect_out_has "arbitrary-command failure named" "FAIL: claude arbitrary command is refused by the wrapper: exit 0, want 2"
expect_calls_has "removal still ran" "docker rm -f deadbeefcafe"

fresh
touch "$STATE/traefik_ok"
live
expect_rc "an unlabelled restart that succeeds fails the live run" 1
expect_out_has "unlabelled-restart failure named" "FAIL: claude restart of an unlabelled name is refused by the helper: exit 0, want 1"

fresh
touch "$STATE/logs_99999_ok"
live
expect_rc "an over-maximum logs that succeeds fails the live run" 1
expect_out_has "over-maximum failure named" "FAIL: claude logs with an over-maximum line count is refused by the wrapper: exit 0, want 2"

fresh
touch "$STATE/ps_empty"
live
expect_rc "a claude ps that does not name the test app fails the live run" 1
expect_out_has "ps output failure named" "FAIL: claude ps output does not name platform-livetest"

# invalid LIVE_TEST_IMAGE: exit 2 before any ssh call
for bad_image in 'busybox;id' 'a b' '$(id)' '--privileged' '-v' 'img`id`' "img'x"; do
  fresh
  t_reset_calls
  run_cmd env LIVE_TEST_IMAGE="$bad_image" bash "$script" verify --live --identity "$IDENT" --host pi-test
  expect_rc "invalid LIVE_TEST_IMAGE '$bad_image'" 2
  expect_calls_lacks "no ssh call for invalid image '$bad_image'" "ssh "
done
fresh
t_reset_calls
run_cmd env LIVE_TEST_IMAGE='registry.example/team/img:1.2.3@sha256-abc' bash "$script" verify --live --identity "$IDENT" --host pi-test
expect_rc "a plain image reference is accepted" 0
expect_calls_has "the accepted image reaches docker run" "registry.example/team/img:1.2.3@sha256-abc sleep 300"

# SIGTERM in the middle of the claude commands: the trap removes the container and the run reports the signal exit
fresh
touch "$STATE/kill_on_third"
t_reset_calls
bash "$script" verify --live --identity "$IDENT" --host pi-test > "$T_TMP/sigterm.out" 2>&1 &
installer_pid=$!
echo "$installer_pid" > "$STATE/installer_pid"
rc=0
# shellcheck disable=SC2034 # rc is read by expect_rc in lib.sh
wait "$installer_pid" || rc=$?
out="$(cat "$T_TMP/sigterm.out")"
expect_rc "SIGTERM mid-run exits 143" 143
expect_out_lacks "an interrupted run never claims success" "all live checks passed"
expect_calls_has "the interrupted run removed the container by id" "docker rm -f deadbeefcafe"
if [ -e "$STATE/container_exists" ]; then _fail "the test container is gone after SIGTERM"; else _pass; fi

# negative: removal fails: reported, not silent
fresh
touch "$STATE/rm_fail"
live
expect_rc "a failed removal fails the run" 1
expect_out_has "removal failure is reported" "remove it by hand"

# negative: a leftover container with the reserved label is never clobbered
fresh
echo "abc123def456" > "$STATE/existing"
live
expect_rc "a leftover test container stops the run" 1
expect_out_has "leftover named" "already exists"
expect_calls_lacks "nothing created over a leftover" "docker run"
expect_calls_lacks "nothing removed that was not created" "docker rm"

# input errors: nothing runs
fresh
t_reset_calls
run_cmd bash "$script" verify --live --host pi-test
expect_rc "--live needs --identity" 2
expect_calls_lacks "ssh not called without --identity" "ssh "
run_cmd bash "$script" verify --live --identity "$IDENT"
expect_rc "--live needs --host" 2
run_cmd bash "$script" verify --live --identity "$T_TMP/missing-key" --host pi-test
expect_rc "--live with an unreadable identity" 2
run_cmd bash "$script" verify --live --identity -oProxyCommand=x --host pi-test
expect_rc "option-looking --identity refused" 2
run_cmd bash "$script" verify --live --identity "$IDENT" --host -oProxyCommand=x
expect_rc "option-looking --host refused under --live" 2
expect_calls_lacks "ssh never called on input errors" "ssh "

# nothing is created without the flag
fresh
t_reset_calls
run_cmd bash "$script" verify --host pi-test --identity "$IDENT"
expect_rc "verify --host without --live only streams" 0
expect_calls_lacks "no container is created without --live" "docker run"

t_finish
