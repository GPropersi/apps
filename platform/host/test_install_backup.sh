#!/usr/bin/env bash
# Stub tests for install-backup.sh. Every default host path lands under INSTALL_BACKUP_ROOT, the privilege prefix is a
# logging fakesudo, and curl/bunzip2/sha256sum/stat/chown/install/systemctl/systemd-run/ssh are stubs on PATH (owners are
# recorded by the chown and install stubs and reported by the stat stub; modes are real). The installed "restic" is a
# fixture script that logs its argv. No systemd, network, docker or real host path is touched. Static tests on the
# tracked sources (env reader copies, pinned checksum, unit values, window arithmetic) run at the end.
#
# No routable address literals and no real secret: the fixture values below are fake strings.
# SC2016: stub bodies and payload checks are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# SC2154: $out and $rc are set by run_cmd in lib.sh.
# shellcheck disable=SC1091,SC2016,SC2034,SC2059,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/install-backup.sh"
src="$here/../backup"

t_init
STATE="$T_TMP/state"
export STATE

# ---- stubs ----

mkstub() { # <name>: body from stdin; the stub first logs "<name> <argv...>" to the call log
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

mkstub nosudo <<'EOF'
exit 1
EOF

mkstub flock <<'EOF'
exit 0
EOF

# timeout: skip its options and the duration, then run the command (the installer bounds restic with it)
mkstub timeout <<'EOF'
while [ "${1:-}" != "" ] && [[ "$1" == -* ]]; do shift 2; done
shift
[ "$#" -gt 0 ] || exit 0
exec "$@"
EOF

# mv: carry the owner record from the source path to the destination (a rename keeps the owner on a real host)
mkstub mv <<'EOF'
args=()
for a in "$@"; do [ "$a" = -f ] || [ "$a" = -- ] || args+=("$a"); done
src="${args[0]}"
dst="${args[1]}"
if [ -f "$STATE/owner/${src//\//_}" ]; then
  mkdir -p "$STATE/owner"
  mv -f -- "$STATE/owner/${src//\//_}" "$STATE/owner/${dst//\//_}"
fi
exec /usr/bin/mv -f -- "$src" "$dst"
EOF

mkstub chown <<'EOF'
spec="$1"
path="$2"
u="${spec%%:*}"
g="${spec#*:}"
[ "$u" != root ] || u=0
[ "$g" != root ] || g=0
mkdir -p "$STATE/owner"
echo "$u:$g" > "$STATE/owner/${path//\//_}"
exit 0
EOF

mkstub install <<'EOF'
mode=""
own=""
grp=""
isdir=0
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -d) isdir=1; shift ;;
    -m) mode="$2"; shift 2 ;;
    -o) own="$2"; shift 2 ;;
    -g) grp="$2"; shift 2 ;;
    --) shift ;;
    *) args+=("$1"); shift ;;
  esac
done
if [ "$isdir" -eq 1 ]; then
  dir="${args[0]}"
  mkdir -p "$dir"
else
  dir="${args[1]}"
  rm -f -- "$dir"
  cp -- "${args[0]}" "$dir"
fi
chmod "$mode" "$dir"
[ "$own" != root ] || own=0
[ "$grp" != root ] || grp=0
mkdir -p "$STATE/owner"
echo "$own:$grp" > "$STATE/owner/${dir//\//_}"
exit 0
EOF

mkstub stat <<'EOF'
fmt="$2"
path="${@: -1}"
if [ ! -e "$path" ] && [ ! -L "$path" ]; then exit 1; fi
ug="$(cat "$STATE/owner/${path//\//_}" 2>/dev/null || echo 0:0)"
case "$fmt" in
  '%u:%g %a') echo "$ug $(/usr/bin/stat -c '%a' -- "$path")" ;;
  *) /usr/bin/stat -c "$fmt" -- "$path" ;;
esac
EOF

mkstub ssh <<'EOF'
cat > "$STATE/ssh_stdin"
exit 0
EOF

# curl: copies the fixture archive to the -o target (the fixture "archive" is the fixture restic script itself).
mkstub curl <<'EOF'
[ ! -f "$STATE/curl_fail" ] || exit 22
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift 2; else shift; fi
done
cp -- "$STATE/restic_fixture" "$out"
exit 0
EOF

# bunzip2 -c -- <file>: the fixture "archive" is already the binary
mkstub bunzip2 <<'EOF'
cat -- "${@: -1}"
EOF

# sha256sum: the archive hash comes from state (default the pinned constant); every other file is hashed for real.
mkstub sha256sum <<'EOF'
f="${@: -1}"
case "$f" in
  *.bz2) echo "$(cat "$STATE/bz2_sha" 2>/dev/null || echo "$GOODSHA")  $f" ;;
  *) /usr/bin/sha256sum -- "$f" ;;
esac
EOF

# systemctl: a timer that is enabled/active only after `enable --now`; state files under $STATE.
mkstub systemctl <<'EOF'
case "$1" in
  is-enabled) if [ -f "$STATE/timer_enabled" ]; then echo enabled; exit 0; fi; echo disabled; exit 1 ;;
  is-active) if [ -f "$STATE/timer_active" ]; then echo active; exit 0; fi; echo inactive; exit 3 ;;
  enable) touch "$STATE/timer_enabled" "$STATE/timer_active"; exit 0 ;;
  show)
    if [ -f "$STATE/no_next" ]; then echo "NextElapseUSecRealtime="; else echo "NextElapseUSecRealtime=Sat 2026-10-24 03:35:00 CDT"; fi
    exit 0 ;;
  *) exit 0 ;;
esac
EOF

mkstub systemd-run <<'EOF'
exit "${SYSTEMD_RUN_RC:-0}"
EOF

# ---- fixtures ----

GOODSHA="$(sed -n 's/^readonly RESTIC_SHA256="\(.*\)"$/\1/p' "$script")"
export GOODSHA
RPW='fixture-restic-password-0003'
SKEY='fixture-secret-key-0004'
ENV_BODY=$'RESTIC_REPOSITORY=s3:https://r2.example.test/bucket\nRESTIC_PASSWORD='"$RPW"$'\nAWS_ACCESS_KEY_ID=fixtureaccesskey\nAWS_SECRET_ACCESS_KEY='"$SKEY"$'\nAWS_DEFAULT_REGION=auto\nDISCORD_WEBHOOK=https://discord.example.test/api/webhooks/fixture\n'

# fresh: a clean root and clean state; every input valid; nothing installed yet.
fresh() {
  rm -rf "$T_TMP/root" "$STATE"
  mkdir -p "$STATE/owner" "$T_TMP/root/etc/platform" "$T_TMP/root/etc/systemd/system" "$T_TMP/root/usr/local/bin" \
    "$T_TMP/root/opt/platform/data" "$T_TMP/root/var/lib/platform/secrets" "$T_TMP/root/var/log/journal"
  t_reset_calls
  R="$T_TMP/root"
  printf '%s' "$ENV_BODY" > "$R/etc/platform/backup.env"
  chmod 600 "$R/etc/platform/backup.env"
  printf 'fixture\n' > "$R/etc/platform/postgres-admin.password"
  printf 'fixture\n' > "$R/etc/platform/redis-admin.password"
  printf 'services:\n' > "$R/opt/platform/data/compose.yaml"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'printf "restic" >> "$CALL_LOG"; for a in "$@"; do printf " %%s" "$a" >> "$CALL_LOG"; done; printf "\\n" >> "$CALL_LOG"\n'
    printf 'case "$1" in\n'
    printf '  version) echo "restic $(cat "$STATE/restic_version" 2>/dev/null || echo 0.18.1) compiled with go1.24.1 on linux/arm64" ;;\n'
    printf '  cat) [ ! -f "$STATE/cat_rc" ] || exit "$(cat "$STATE/cat_rc")"; [ -f "$STATE/repo_exists" ] || { echo "Fatal: repository does not exist" >&2; exit 10; } ;;\n'
    printf '  init) printf "%%s" "${RESTIC_REPOSITORY:-}" > "$STATE/init_repo_seen"; echo "created restic repository" ;;\n'
    printf 'esac\n'
  } > "$STATE/restic_fixture"
  export INSTALL_BACKUP_ROOT="$R"
  export INSTALL_BACKUP_SUDO=fakesudo
  unset INSTALL_BACKUP_TOOLS
}

ins() { run_cmd "$script" "$@"; }

OPT() { printf '%s' "$R/opt/platform/backup"; }
UNITS() { printf '%s' "$R/etc/systemd/system"; }
STATE_DIR() { printf '%s' "$R/var/lib/platform/backup-status"; }
mode_of() { /usr/bin/stat -c '%a' -- "$1"; }
owner_of() { cat "$STATE/owner/${1//\//_}" 2>/dev/null || echo 0:0; }

no_leaks() { # label: no fixture secret in the output or in any recorded argv
  if grep -qF -e "$RPW" -e "$SKEY" "$CALL_LOG"; then _fail "$1" "a fixture secret reached an argv"; else _pass; fi
  expect_out_lacks "$1 (password not printed)" "$RPW"
  expect_out_lacks "$1 (secret key not printed)" "$SKEY"
}

# nothing_installed <label>: no restic, no payload dir, no work dir, no unit, no download, no systemctl
nothing_installed() {
  local f bad=""
  for f in "$R/usr/local/bin/restic" "$(OPT)" "$R/var/lib/platform/backup" "$R/var/lib/platform/backup-status" "$R/var/log/platform-backup" "$(UNITS)/platform-backup.service" "$(UNITS)/platform-backup.timer"; do
    # a pre-planted symlink (the symlinked-work-dir case) is the fixture itself, not something the installer wrote
    [ ! -e "$f" ] || [ -L "$f" ] || bad="$bad $f"
  done
  if [ -z "$bad" ]; then _pass; else _fail "$1: nothing was written" "exists:$bad"; fi
  [ "${2:-}" = curl-ok ] || expect_calls_lacks "$1: no download" "curl "
  expect_calls_lacks "$1: no systemctl call" "systemctl "
  expect_calls_lacks "$1: no restic init" "restic init"
}

snap_take() {
  rm -rf "$T_TMP/snap"
  mkdir -p "$T_TMP/snap"
  cp -a "$R" "$T_TMP/snap/root"
  cp -a "$STATE" "$T_TMP/snap/state"
}
snap_restore() {
  rm -rf "$R" "$STATE"
  cp -a "$T_TMP/snap/root" "$R"
  cp -a "$T_TMP/snap/state" "$STATE"
  t_reset_calls
}

# ---- 1. usage, help and the privilege gate ----

fresh
ins --bogus
expect_rc "unknown argument" 2
ins --host
expect_rc "--host without a value" 2
ins --host -oProxyCommand=x
expect_rc "option-looking --host" 2
ins --help
expect_rc "--help succeeds" 0
expect_out_has "--help shows the usage line" "Usage: install-backup.sh"
expect_out_has "--help shows the exit codes" "Exit: 0 ok"
expect_out_lacks "--help stops before the code" "set -euo"
INSTALL_BACKUP_SUDO=nosudo ins install
expect_rc "no usable privilege" 1
expect_out_has "privilege failure is explained" "no usable privilege"
t_reset_calls
ins --host alias verify
expect_rc "--host streams over ssh" 0
expect_calls_has "ssh runs bash -s with the mode" "ssh -o BatchMode=yes -- alias bash -s -- verify"
if cmp -s "$STATE/ssh_stdin" "$script"; then _pass; else _fail "the script itself is streamed to ssh"; fi

# ---- 2. preconditions: every failure aborts with the named reason and nothing written ----

precond_case() { # label, setup function, expected message, [mode]
  fresh
  "$2"
  ins "${4:-install}"
  expect_rc "precondition: $1 fails" 1
  expect_out_has "precondition: $1 is named" "$3"
  expect_out_has "precondition: $1 says nothing was installed" "nothing was installed"
  nothing_installed "precondition: $1"
  no_leaks "precondition: $1"
}
c_env_missing() { rm -f "$R/etc/platform/backup.env"; }
c_env_mode() { chmod 644 "$R/etc/platform/backup.env"; }
c_env_owner() { echo "1000:1000" > "$STATE/owner/${R//\//_}_etc_platform_backup.env"; }
c_env_missing_key() { grep -v '^DISCORD_WEBHOOK=' "$R/etc/platform/backup.env" > "$R/etc/platform/backup.new"; mv "$R/etc/platform/backup.new" "$R/etc/platform/backup.env"; chmod 600 "$R/etc/platform/backup.env"; }
c_env_empty_value() { sed -i 's/^RESTIC_PASSWORD=.*/RESTIC_PASSWORD=/' "$R/etc/platform/backup.env"; }
c_env_quoted() { sed -i 's/^AWS_DEFAULT_REGION=.*/AWS_DEFAULT_REGION="auto"/' "$R/etc/platform/backup.env"; }
c_env_duplicate() { printf 'AWS_DEFAULT_REGION=auto\n' >> "$R/etc/platform/backup.env"; }
c_env_unknown() { printf 'EXTRA_KEY=1\n' >> "$R/etc/platform/backup.env"; }
c_env_cr() { printf 'RESTIC_REPOSITORY=s3:x\r\n' > "$R/etc/platform/backup.env"; chmod 600 "$R/etc/platform/backup.env"; }
c_env_symlink() { mv "$R/etc/platform/backup.env" "$R/etc/platform/real.env"; ln -s real.env "$R/etc/platform/backup.env"; }
c_no_stack() { rm -rf "$R/opt/platform/data"; }
c_no_secrets_root() { rmdir "$R/var/lib/platform/secrets"; }
c_pg_missing() { rm -f "$R/etc/platform/postgres-admin.password"; }
c_rd_missing() { rm -f "$R/etc/platform/redis-admin.password"; }
c_work_symlink() { mkdir -p "$R/elsewhere"; ln -s "$R/elsewhere" "$R/var/lib/platform/backup"; }

precond_case "missing env file" c_env_missing "env file is missing"
precond_case "env mode 0644" c_env_mode "env file mode is not 0600"
precond_case "env owner" c_env_owner "env file owner is not 0:0"
precond_case "a missing key" c_env_missing_key "does not define DISCORD_WEBHOOK"
precond_case "an empty value" c_env_empty_value "does not define RESTIC_PASSWORD"
precond_case "a quoted value" c_env_quoted "starts with a quote"
precond_case "a duplicate key" c_env_duplicate "repeats key AWS_DEFAULT_REGION"
precond_case "an unknown key" c_env_unknown "has an unknown key"
precond_case "a CR" c_env_cr "contains a CR"
precond_case "a symlinked env file" c_env_symlink "env file is a symlink"
precond_case "no data stack" c_no_stack "platform-data stack is not installed"
precond_case "no secrets root" c_no_secrets_root "secrets root"
precond_case "no postgres admin file" c_pg_missing "postgres-admin.password is missing"
precond_case "no redis admin file" c_rd_missing "redis-admin.password is missing"
precond_case "a symlinked work dir" c_work_symlink "is a symlink"
# restore-only shares the env precondition and a quoted value or a duplicate key aborts it too
precond_case "restore-only with a quoted value" c_env_quoted "starts with a quote" restore-only
precond_case "restore-only with a duplicate key" c_env_duplicate "repeats key" restore-only
precond_case "restore-only with a missing key" c_env_missing_key "does not define DISCORD_WEBHOOK" restore-only

# a missing required command aborts with nothing written
fresh
INSTALL_BACKUP_TOOLS="curl flock timeout bunzip2 no-such-tool-zq" ins install
expect_rc "missing required command fails" 1
expect_out_has "the missing command is named" "required command not found: no-such-tool-zq"
nothing_installed "missing command"
fresh
INSTALL_BACKUP_TOOLS="curl flock timeout bunzip2 no-such-tool-zq" ins restore-only
expect_rc "missing required command fails restore-only" 1
nothing_installed "missing command (restore-only)"
tools_default="$(sed -n 's/^TOOLS="${INSTALL_BACKUP_TOOLS:-\(.*\)}"$/\1/p' "$script")"
expect_eq "the default required commands are curl flock timeout bunzip2" "$tools_default" "curl flock timeout bunzip2"

# several problems are reported together
fresh
rm -rf "$R/opt/platform/data"
rm -f "$R/etc/platform/redis-admin.password"
ins install
expect_out_has "problems are reported together (stack)" "platform-data stack is not installed"
expect_out_has "problems are reported together (admin file)" "redis-admin.password is missing"
expect_out_has "the count is reported" "2 precondition(s) failed"

# ---- 3. a checksum mismatch refuses and leaves restic untouched ----

fresh
printf 'old-restic-marker\n' > "$R/usr/local/bin/restic"
chmod 755 "$R/usr/local/bin/restic"
echo "0000000000000000000000000000000000000000000000000000000000000000" > "$STATE/bz2_sha"
ins install
expect_rc "checksum mismatch fails" 1
expect_out_has "checksum mismatch is named" "checksum mismatch"
expect_eq "restic is untouched after a mismatch" "$(cat "$R/usr/local/bin/restic")" "old-restic-marker"
expect_calls_lacks "no mutating install after a mismatch" "install -m"
bad=""
for f in "$(OPT)" "$R/var/lib/platform/backup" "$R/var/lib/platform/backup-status" "$R/var/log/platform-backup" "$(UNITS)/platform-backup.service" "$(UNITS)/platform-backup.timer"; do
  [ ! -e "$f" ] || bad="$bad $f"
done
if [ -z "$bad" ]; then _pass; else _fail "a mismatch wrote nothing else (checksum is verified before any write)" "exists:$bad"; fi
expect_calls_lacks "a mismatch makes no systemctl call" "systemctl "
fresh
touch "$STATE/curl_fail"
ins install
expect_rc "a failed download fails" 1
expect_out_has "a failed download is named" "download of"
nothing_installed "failed download" curl-ok

# ---- 4. restore-only on a bare host, then a full install ----

fresh
rm -rf "$R/opt/platform/data" "$R/var/lib" "$R/etc/platform/postgres-admin.password" "$R/etc/platform/redis-admin.password"
ins restore-only
expect_rc "restore-only on a bare host" 0
no_leaks "restore-only"
expect_eq "restore-only installs restic 0755" "$(mode_of "$R/usr/local/bin/restic")" "755"
expect_eq "restic is root-owned" "$(owner_of "$R/usr/local/bin/restic")" "0:0"
for f in backup.sh restore.sh window.env restic.sha256; do
  expect_eq "restore-only: $f is root-owned" "$(owner_of "$(OPT)/$f")" "0:0"
done
expect_eq "restore-only: /var/lib/platform is 0755" "$(mode_of "$R/var/lib/platform")" "755"
expect_eq "restore-only: /var/lib/platform/backup is 0700" "$(mode_of "$R/var/lib/platform/backup")" "700"
expect_eq "restore-only: /var/log/platform-backup is 0750" "$(mode_of "$R/var/log/platform-backup")" "750"
expect_eq "restore-only: /var/lib/platform is root:root" "$(owner_of "$R/var/lib/platform")" "0:0"
expect_eq "restore-only: the work dir is root:root" "$(owner_of "$R/var/lib/platform/backup")" "0:0"
expect_eq "restore-only: the log dir is root:root" "$(owner_of "$R/var/log/platform-backup")" "0:0"
for f in backup.sh restore.sh window.env restic.sha256; do expect_file "restore-only places $f" "$(OPT)/$f"; done
expect_eq "restore-only: restore.sh is 0755" "$(mode_of "$(OPT)/restore.sh")" "755"
if cmp -s "$(OPT)/restore.sh" "$src/restore.sh" && cmp -s "$(OPT)/backup.sh" "$src/backup.sh" && cmp -s "$(OPT)/window.env" "$src/window.env"; then _pass; else _fail "restore-only payload bytes equal the tracked sources"; fi
if [ ! -e "$R/var/lib/platform/backup-status" ] && [ ! -e "$(UNITS)/platform-backup.service" ] && [ ! -e "$(UNITS)/platform-backup.timer" ]; then _pass; else _fail "restore-only writes no backup-status, unit or timer"; fi
expect_calls_lacks "restore-only makes no systemctl call" "systemctl "
expect_calls_lacks "restore-only makes no restic init" "restic init"
# restore-only again: every item already in place
t_reset_calls
ins restore-only
expect_rc "restore-only is idempotent" 0
expect_out_lacks "restore-only second run changes nothing" "changed:"
expect_calls_lacks "restore-only second run downloads nothing" "curl "

# a following install on a host that now has the data stack and admin files
mkdir -p "$R/opt/platform/data" "$R/var/lib/platform/secrets" "$R/etc/platform" "$R/etc/systemd/system" "$R/var/log/journal"
printf 'services:\n' > "$R/opt/platform/data/compose.yaml"
printf 'fixture\n' > "$R/etc/platform/postgres-admin.password"
printf 'fixture\n' > "$R/etc/platform/redis-admin.password"
t_reset_calls
ins install
expect_rc "install after restore-only" 0
expect_out_has "install reuses the var dir" "already: $R/var/lib/platform/"
expect_out_has "install reuses the work dir" "already: $R/var/lib/platform/backup/"
expect_out_has "install reuses the log dir" "already: $R/var/log/platform-backup/"
expect_out_has "install reuses restic" "already: $R/usr/local/bin/restic"
expect_out_has "install reuses the payloads" "already: $(OPT)/restore.sh"
expect_out_has "install creates backup-status" "changed: $(STATE_DIR)/"
expect_eq "backup-status is 0755" "$(mode_of "$(STATE_DIR)")" "755"
expect_eq "backup-status is root:root" "$(owner_of "$(STATE_DIR)")" "0:0"
expect_calls_lacks "the download is skipped when restic is current" "curl "
expect_calls_has "the timer is enabled" "systemctl enable --now platform-backup.timer"
# a disabled timer is re-enabled by a later install
rm -f "$STATE/timer_enabled" "$STATE/timer_active"
t_reset_calls
ins install
expect_rc "install with the timer disabled beforehand" 0
expect_calls_has "a disabled timer is enabled again" "systemctl enable --now platform-backup.timer"

# ---- 5. full install from scratch, and an idempotent second run ----

fresh
ins install
expect_rc "install" 0
no_leaks "install"
for f in backup.sh restore.sh; do expect_eq "$f is 0755" "$(mode_of "$(OPT)/$f")" "755"; done
expect_eq "window.env is 0644" "$(mode_of "$(OPT)/window.env")" "644"
expect_eq "the service unit is 0644" "$(mode_of "$(UNITS)/platform-backup.service")" "644"
expect_eq "the timer unit is 0644" "$(mode_of "$(UNITS)/platform-backup.timer")" "644"
expect_eq "restic is 0755" "$(mode_of "$R/usr/local/bin/restic")" "755"
expect_eq "the payload dir is 0755" "$(mode_of "$(OPT)")" "755"
expect_eq "the work dir is 0700" "$(mode_of "$R/var/lib/platform/backup")" "700"
expect_eq "the log dir is 0750" "$(mode_of "$R/var/log/platform-backup")" "750"
expect_eq "backup-status is 0755" "$(mode_of "$(STATE_DIR)")" "755"
for f in "$(OPT)/backup.sh" "$(OPT)/restore.sh" "$(OPT)/window.env" "$(UNITS)/platform-backup.service" "$(UNITS)/platform-backup.timer" "$R/usr/local/bin/restic" "$(OPT)/restic.sha256"; do
  expect_eq "${f##*/} is root:root" "$(owner_of "$f")" "0:0"
done
# a pre-existing directory with the wrong mode is corrected (the staging dir holds dumps and secrets)
chmod 755 "$R/var/lib/platform/backup"
chmod 700 "$(OPT)"
t_reset_calls
ins install
expect_rc "install over wrongly-moded directories" 0
expect_eq "the work dir is corrected to 0700" "$(mode_of "$R/var/lib/platform/backup")" "700"
expect_eq "the payload dir is corrected to 0755" "$(mode_of "$(OPT)")" "755"
expect_out_has "the corrected work dir is reported" "changed: $R/var/lib/platform/backup/"
fresh
ins install
for pair in "backup.sh:backup.sh" "restore.sh:restore.sh" "window.env:window.env"; do
  if cmp -s "$(OPT)/${pair%%:*}" "$src/${pair##*:}"; then _pass; else _fail "installed ${pair%%:*} equals the tracked source"; fi
done
if cmp -s "$(UNITS)/platform-backup.service" "$src/platform-backup.service"; then _pass; else _fail "installed service unit equals the tracked source"; fi
if cmp -s "$(UNITS)/platform-backup.timer" "$src/platform-backup-timer.timer"; then _pass; else _fail "installed timer equals platform-backup-timer.timer"; fi
expect_calls_has "daemon-reload ran" "systemctl daemon-reload"
expect_calls_has "the timer was enabled" "systemctl enable --now platform-backup.timer"
expect_calls_lacks "the service is never started" "systemctl start"
expect_calls_lacks "the service is never restarted" "restart platform-backup.service"
expect_calls_lacks "the service is never enabled" "enable platform-backup.service"
expect_calls_lacks "install never runs restic init" "restic init"
if [ "$(grep -c '^curl ' "$CALL_LOG")" -eq 1 ]; then _pass; else _fail "install downloads exactly once"; fi
if [ "$(tr -d '\n' < "$(OPT)/restic.sha256")" = "$(/usr/bin/sha256sum "$R/usr/local/bin/restic" | cut -d' ' -f1)" ]; then _pass; else _fail "restic.sha256 records the installed binary hash"; fi

t_reset_calls
ins install
expect_rc "second install" 0
if grep -vE '^(already: |install-backup: install: everything already in place$)' <<<"$out" | grep -q .; then _fail "a second install prints only already: lines" "other output present"; else _pass; fi
expect_calls_lacks "second install: no download" "curl "
expect_calls_lacks "second install: no systemctl enable" "systemctl enable"
expect_calls_lacks "second install: no daemon-reload" "daemon-reload"
expect_calls_lacks "second install: no restart" "systemctl restart"

# a changed timer is applied by restarting the TIMER (never the service)
printf '# drift\n' >> "$(UNITS)/platform-backup.timer"
t_reset_calls
ins install
expect_rc "install repairs a drifted timer" 0
expect_calls_has "the drifted timer is reloaded" "systemctl daemon-reload"
expect_calls_has "the timer is restarted" "systemctl restart platform-backup.timer"
expect_calls_lacks "the service is not started" "systemctl start"
expect_calls_lacks "the service is not restarted" "systemctl restart platform-backup.service"

# ---- 6. verify and status ----

fresh
ins install
now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
old_iso="$(date -u -d '40 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$(STATE_DIR)"
printf '%s\t%s\tok\tsnap1234\t-\n' "$now_iso" "$now_iso" > "$(STATE_DIR)/last-run.tsv"
chmod 644 "$(STATE_DIR)/last-run.tsv"
snap_take
ins verify
expect_rc "verify passes on a clean install" 0
expect_out_has "verify reports all checks passed" "all checks passed"
no_leaks "verify"
ins status
expect_rc "status passes on a clean install" 0

verify_case() { # label, mutation function, expected FAIL text
  snap_restore
  "$2"
  ins verify
  expect_rc "verify fails: $1" 1
  expect_out_has "verify names the check: $1" "$3"
  ins status
  expect_rc "status never fails: $1" 0
  expect_out_has "status shows the failure too: $1" "FAIL: "
}
m_payload_drift() { printf '# drift\n' >> "$(OPT)/backup.sh"; }
m_restore_drift() { printf '# drift\n' >> "$(OPT)/restore.sh"; }
m_window_drift() { printf 'BACKUP_WINDOW_END=06:00\n' > "$(OPT)/window.env"; }
m_unit_drift() { printf 'MemoryMax=1G\n' >> "$(UNITS)/platform-backup.service"; }
m_wrong_mode() { chmod 644 "$(OPT)/backup.sh"; }
m_timer_disabled() { rm -f "$STATE/timer_enabled"; }
m_timer_inactive() { rm -f "$STATE/timer_active"; }
m_no_next() { touch "$STATE/no_next"; }
m_timer_outside() { sed -i 's/03:35:00/03:10:00/' "$(UNITS)/platform-backup.timer"; }
m_timer_late() { sed -i 's/03:35:00/03:50:00/' "$(UNITS)/platform-backup.timer"; }
m_last_failed() { printf '%s\t%s\tfailed\t-\trestic-backup\n' "$now_iso" "$now_iso" > "$(STATE_DIR)/last-run.tsv"; }
m_last_old() { printf '%s\t%s\tok\tsnap1234\t-\n' "$old_iso" "$old_iso" > "$(STATE_DIR)/last-run.tsv"; }
m_last_garbage() { printf 'garbage\n' > "$(STATE_DIR)/last-run.tsv"; }
m_restic_version() { echo 0.18.0 > "$STATE/restic_version"; }
m_restic_hash() { printf '# drift\n' >> "$R/usr/local/bin/restic"; }
m_restic_record() { printf '%064d\n' 7 > "$(OPT)/restic.sha256"; }
m_state_mode() { chmod 700 "$(STATE_DIR)"; }
m_last_mode() { chmod 600 "$(STATE_DIR)/last-run.tsv"; }
m_env_mode() { chmod 644 "$R/etc/platform/backup.env"; }
m_env_missing() { rm -f "$R/etc/platform/backup.env"; }
m_work_mode() { chmod 755 "$R/var/lib/platform/backup"; }
verify_case "drifted backup.sh bytes" m_payload_drift "backup.sh differs from the shipped payload"
verify_case "drifted restore.sh bytes" m_restore_drift "restore.sh differs from the shipped payload"
verify_case "drifted window.env" m_window_drift "window.env differs from the shipped payload"
verify_case "drifted service unit" m_unit_drift "platform-backup.service differs from the shipped payload"
verify_case "a wrong mode" m_wrong_mode "backup.sh has owner/mode"
verify_case "a disabled timer" m_timer_disabled "platform-backup.timer is not enabled"
verify_case "an inactive timer" m_timer_inactive "platform-backup.timer is not active"
verify_case "no next run" m_no_next "has no next run scheduled"
verify_case "a timer outside the window" m_timer_outside "outside the backup window"
verify_case "a timer whose backstop leaves the window" m_timer_late "ends after BACKUP_WINDOW_END"
verify_case "a failed last run" m_last_failed "the last backup run failed (phase restic-backup)"
verify_case "a last run older than 36h" m_last_old "more than 36h ago"
verify_case "a malformed last run" m_last_garbage "unreadable or malformed"
verify_case "restic version drift" m_restic_version "restic version drift"
verify_case "restic hash drift" m_restic_hash "restic hash drift"
verify_case "a wrong restic hash record" m_restic_record "restic hash drift"
verify_case "backup-status with a wrong mode" m_state_mode "backup-status/ has owner/mode"
verify_case "last-run.tsv with a wrong mode" m_last_mode "last-run.tsv has owner/mode"
verify_case "backup.env with a wrong mode" m_env_mode "backup.env: env file mode is not 0600"
verify_case "a missing backup.env" m_env_missing "backup.env: env file is missing"
verify_case "a work dir with a wrong mode" m_work_mode "var/lib/platform/backup/ has owner/mode"

# an absent journal dir and an absent last-run.tsv are only WARNs
snap_restore
rmdir "$R/var/log/journal"
rm -f "$(STATE_DIR)/last-run.tsv"
ins verify
expect_rc "verify passes with no journal and no last run" 0
expect_out_has "an absent journal dir is a WARN" "WARN: "
expect_out_has "the journal WARN is named" "journal is not persistent"
expect_out_has "an absent last-run.tsv is a WARN" "no backup has run"

# ---- 7. run-now ----

# the script is streamed on stdin over --host (`bash -s -- MODE`): nothing in it may read stdin, or it would eat its own source
snap_restore
rc=0
out="$(bash -s -- verify < "$script" 2>&1)" || rc=$?
expect_rc "streamed on stdin (bash -s -- verify) the installer reaches main and verifies" 0
expect_out_has "streamed on stdin it runs to the end" "all checks passed"

snap_restore
ins run-now
expect_rc "run-now" 0
runline="$(grep '^systemd-run ' "$CALL_LOG" || true)"
for want in "--wait" "--pipe" "backup.sh manual" "-p Type=oneshot" "-p Nice=10" "-p IOSchedulingClass=idle" "-p MemoryHigh=384M" "-p MemoryMax=512M" "-p TimeoutStartSec=4500" "-p After=docker.service" "-p Requires=docker.service"; do
  expect_out_has_text "$runline" "$want" "run-now argv contains: $want"
done
case "$runline" in *EnvironmentFile*) _fail "run-now argv carries no EnvironmentFile" "$runline" ;; *) _pass ;; esac
case "$runline" in "systemd-run --wait --pipe "*) _pass ;; *) _fail "run-now starts with systemd-run --wait --pipe" "$runline" ;; esac
SYSTEMD_RUN_RC=7 ins run-now
expect_rc "run-now propagates the run's failure" 7

snap_restore
rm -f "$R/usr/local/bin/restic"
ins run-now
if [ "$rc" -ne 0 ]; then _pass; else _fail "run-now without restic exits non-zero" "rc=0"; fi
expect_out_has "run-now names the missing restic" "restic is not installed at"
expect_calls_lacks "run-now without restic makes no systemd-run call" "systemd-run"
snap_restore
rm -f "$(OPT)/backup.sh"
ins run-now
if [ "$rc" -ne 0 ]; then _pass; else _fail "run-now without backup.sh exits non-zero" "rc=0"; fi
expect_out_has "run-now names the missing backup.sh" "backup.sh is not installed"
expect_calls_lacks "run-now without backup.sh makes no systemd-run call" "systemd-run"

# ---- 8. init-repo ----

snap_restore
touch "$STATE/repo_exists"
ins init-repo
expect_rc "init-repo refuses when the repository exists" 1
expect_out_has "init-repo says why" "repository already exists"
expect_calls_lacks "init-repo made no restic init when the repo exists" "restic init"
no_leaks "init-repo (existing repo)"

snap_restore
ins init-repo
expect_rc "init-repo on a missing repository" 0
if [ "$(grep -c '^restic init' "$CALL_LOG")" -eq 1 ]; then _pass; else _fail "init-repo makes exactly one restic init"; fi
expect_eq "init-repo gave restic the env read by the shared reader" "$(cat "$STATE/init_repo_seen")" "s3:https://r2.example.test/bucket"
no_leaks "init-repo"

# any failure of `restic cat config` other than "repository does not exist" (exit 10) must not init
snap_restore
echo 1 > "$STATE/cat_rc"
ins init-repo
expect_rc "init-repo refuses when the repository cannot be reached (cat exits 1)" 1
expect_out_has "init-repo names the unreachable repository" "cannot reach or open the repository"
expect_calls_lacks "init-repo made no restic init after an unreachable cat" "restic init"
no_leaks "init-repo (unreachable)"

snap_restore
rm -f "$R/usr/local/bin/restic"
ins init-repo
if [ "$rc" -ne 0 ]; then _pass; else _fail "init-repo without restic exits non-zero" "rc=0"; fi
expect_out_has "init-repo names the missing restic" "restic is not installed at"
expect_calls_lacks "init-repo without restic makes no init call" "init"

snap_restore
c_env_quoted
ins init-repo
expect_rc "init-repo with a bad env file" 2
expect_out_has "init-repo names the env problem" "starts with a quote"
expect_calls_lacks "init-repo with a bad env makes no restic call" "restic "
no_leaks "init-repo (bad env)"

# ---- 9. static tests on the tracked sources ----

# first_block <file>: the first shared-env-reader block (the installer's own copy comes before its embedded payloads)
first_block() { awk '/^# BEGIN shared-env-reader$/ { f = 1 } f { print } /^# END shared-env-reader$/ { if (f) exit }' "$1"; }
b_backup="$(first_block "$src/backup.sh")"
b_restore="$(first_block "$src/restore.sh")"
b_install="$(first_block "$script")"
if [ -n "$b_backup" ] && [ "$b_backup" = "$b_restore" ] && [ "$b_backup" = "$b_install" ]; then _pass; else _fail "the shared env reader is byte-identical in backup.sh, restore.sh and install-backup.sh"; fi
if [ "$(grep -c '^# BEGIN shared-env-reader$' "$script")" -eq 3 ]; then _pass; else _fail "install-backup.sh has its own copy plus the two embedded ones"; fi
# every embedded copy is identical too
embedded_ok=1
while IFS= read -r n; do
  blk="$(awk -v want="$n" '/^# BEGIN shared-env-reader$/ { c++ } c == want { print } /^# END shared-env-reader$/ { if (c == want) exit }' "$script")"
  [ "$blk" = "$b_backup" ] || embedded_ok=0
done < <(seq 1 3)
expect_eq "all three copies inside install-backup.sh are identical to backup.sh's" "$embedded_ok" "1"
# positive control: one changed byte in one copy is caught
mut_blk="${b_restore/read_backup_env <file>/read_backup_env <fi1e>}"
if [ "$mut_blk" != "$b_backup" ]; then _pass; else _fail "positive control: the mutation changed the block"; fi
if [ "$mut_blk" = "$b_backup" ] && [ "$mut_blk" = "$b_install" ]; then _fail "positive control: a changed byte in one copy fails the comparison"; else _pass; fi
mut_blk="${b_install//printf -v/printf -w}"
if [ "$b_backup" = "$mut_blk" ]; then _fail "positive control: a mutated installer copy fails the comparison"; else _pass; fi

# restic pin: the checksum shape, and 0.18.1 identical in the comment, the download filename, the URL and the version check
sha_line="$(grep -E '^readonly RESTIC_SHA256=' "$script")"
if [[ "$sha_line" =~ ^readonly\ RESTIC_SHA256=\"[0-9a-f]{64}\"$ ]]; then _pass; else _fail "RESTIC_SHA256 matches ^[0-9a-f]{64}$"; fi
ver_of() { grep -oE '[0-9]+\.[0-9]+\.[0-9]+' <<<"$1" | sort -u | tr '\n' ' '; }
v_comment="$(ver_of "$(grep -E '^# SHA256SUMS of restic_' "$script")")"
v_file="$(ver_of "$(grep -E '^readonly RESTIC_FILE=' "$script")")"
v_url="$(ver_of "$(grep -E '^readonly RESTIC_URL=' "$script")")"
v_check="$(ver_of "$(grep -E '^readonly RESTIC_VERSION_PREFIX=' "$script")")"
expect_eq "0.18.1 is the version in the SHA comment" "$v_comment" "0.18.1 "
expect_eq "0.18.1 is the version in the download filename" "$v_file" "0.18.1 "
expect_eq "0.18.1 is the version in the download URL" "$v_url" "0.18.1 "
expect_eq "0.18.1 is the version in the version check" "$v_check" "0.18.1 "
if grep -qE '^readonly RESTIC_FILE="restic_0\.18\.1_linux_arm64\.bz2"$' "$script"; then _pass; else _fail "the download is restic_0.18.1_linux_arm64.bz2"; fi

# the tracked service unit
unit="$src/platform-backup.service"
timer="$src/platform-backup-timer.timer"
for want in "Type=oneshot" "User=root" "Wants=network-online.target" "After=network-online.target time-sync.target docker.service" "Requires=docker.service" "TimeoutStartSec=4500" "MemoryHigh=384M" "MemoryMax=512M" "Nice=10" "IOSchedulingClass=idle" "ExecStart=/opt/platform/backup/backup.sh nightly"; do
  if grep -qxF "$want" "$unit"; then _pass; else _fail "the service unit contains $want"; fi
done
if grep -q 'EnvironmentFile' "$unit"; then _fail "the service unit has no EnvironmentFile"; else _pass; fi
for want in "OnCalendar=*-*-* 03:35:00 America/Chicago" "Persistent=true" "AccuracySec=1min" "Unit=platform-backup.service" "WantedBy=timers.target"; do
  if grep -qxF "$want" "$timer"; then _pass; else _fail "the timer contains $want"; fi
done

# run-now's properties equal the unit's (drift fails)
props_match() { # <installer> <unit>: every RUN_PROPS entry is in the unit
  local line p key val ok=0 vals
  line="$(grep -E '^readonly RUN_PROPS=\(' "$1")"
  line="${line#*(}"
  line="${line%)}"
  for p in $line; do
    key="${p%%=*}"
    val="${p#*=}"
    case "$key" in
      After | Requires)
        vals="$(sed -n "s/^$key=//p" "$2")"
        [[ " $vals " == *" $val "* ]] || ok=1 ;;
      *) grep -qxF "$p" "$2" || ok=1 ;;
    esac
  done
  return "$ok"
}
if props_match "$script" "$unit"; then _pass; else _fail "run-now properties equal the tracked unit"; fi
sed 's/^MemoryMax=512M$/MemoryMax=1G/' "$unit" > "$T_TMP/unit.mutant"
if props_match "$script" "$T_TMP/unit.mutant"; then _fail "positive control: editing the unit's value without run-now fails the comparison"; else _pass; fi
sed 's/^TimeoutStartSec=4500$/TimeoutStartSec=4400/' "$unit" > "$T_TMP/unit.mutant"
if props_match "$script" "$T_TMP/unit.mutant"; then _fail "positive control: a changed TimeoutStartSec fails the comparison"; else _pass; fi
for want in Type=oneshot Nice=10 IOSchedulingClass=idle MemoryHigh=384M MemoryMax=512M TimeoutStartSec=4500 After=docker.service Requires=docker.service; do
  if grep -qE "^readonly RUN_PROPS=\((.* )?${want}[ )]" "$script"; then _pass; else _fail "run-now carries $want"; fi
done

# window arithmetic: the timer start, its backstop and its default deadline all lie inside window.env
secs() { local h="${1%%:*}" r="${1#*:}"; local m="${r%%:*}" s="${r#*:}"; [ "$s" != "$r" ] || s=0; echo $((10#$h * 3600 + 10#$m * 60 + 10#$s)); }
window_ok() { # <timer> <unit> <window.env>
  local t tmo ws we dl
  t="$(sed -n 's/^OnCalendar=\*-\*-\* \([0-9:]*\) .*/\1/p' "$1")"
  tmo="$(sed -n 's/^TimeoutStartSec=//p' "$2")"
  ws="$(sed -n 's/^BACKUP_WINDOW_START=//p' "$3")"
  we="$(sed -n 's/^BACKUP_WINDOW_END=//p' "$3")"
  dl="$(sed -n 's/^DEADLINE_SECS=//p' "$src/backup.sh")"
  t="$(secs "$t")"
  ws="$(secs "$ws")"
  we="$(secs "$we")"
  [ "$t" -ge "$ws" ] || return 1
  [ $((t + tmo + 60)) -le "$we" ] || return 1
  [ $((t + dl + 60)) -le "$we" ] || return 1
  [ "$tmo" -gt "$dl" ] || return 1
}
if window_ok "$timer" "$unit" "$src/window.env"; then _pass; else _fail "timer start and backstop lie inside window.env (03:35 -> 04:51 <= 05:00)"; fi
sed 's/03:35:00/03:44:00/' "$timer" > "$T_TMP/timer.mutant"
if window_ok "$T_TMP/timer.mutant" "$unit" "$src/window.env"; then _pass; else _fail "03:44 is the latest timer time that fits"; fi
sed 's/03:35:00/03:45:00/' "$timer" > "$T_TMP/timer.mutant"
if window_ok "$T_TMP/timer.mutant" "$unit" "$src/window.env"; then _fail "positive control: moving the timer to 03:45 fails the window check"; else _pass; fi
sed 's/03:35:00/03:20:00/' "$timer" > "$T_TMP/timer.mutant"
if window_ok "$T_TMP/timer.mutant" "$unit" "$src/window.env"; then _fail "positive control: a timer before the window start fails"; else _pass; fi
if [ "$(sed -n 's/^OnCalendar=\*-\*-\* [0-9:]* \(.*\)/\1/p' "$timer")" = "$(sed -n 's/^BACKUP_WINDOW_TZ=//p' "$src/window.env")" ]; then _pass; else _fail "the timer timezone equals BACKUP_WINDOW_TZ"; fi

# the worst-case run (deadline + the kill grace of every timed call that can still run after it) fits inside TimeoutStartSec
dl="$(sed -n 's/^DEADLINE_SECS=//p' "$src/backup.sh")"
kg="$(sed -n 's/.*timeout -s TERM -k \([0-9][0-9]*\) .*/\1/p' "$src/backup.sh" | sort -u)"
ul="$(sed -n 's/^UNLOCK_SECS=//p' "$src/backup.sh")"
nt="$(sed -n 's/^NOTIFY_PHASE_SECS=//p' "$src/backup.sh")"
tmo="$(sed -n 's/^TimeoutStartSec=//p' "$unit")"
expect_eq "the kill grace is a single known value" "$kg" "30"
worst_case() { echo $((dl + kg + (ul + kg) + (nt + kg))); } # clamped phase + kill, unlock + kill, notify + kill
deadline_ok() { [ "$(worst_case)" -lt "$1" ] && [ $((dl + ul + nt)) -lt "$1" ]; }
if deadline_ok "$tmo"; then _pass; else _fail "deadline + kill grace + unlock + notify ($(worst_case)s) < TimeoutStartSec ($tmo)"; fi
expect_eq "the worst case is 4440s" "$(worst_case)" "4440"
if deadline_ok 4440; then _fail "positive control: a TimeoutStartSec equal to the worst case fails"; else _pass; fi
if deadline_ok 4441; then _pass; else _fail "one second above the worst case passes"; fi
if [ "$tmo" -gt "$dl" ]; then _pass; else _fail "TimeoutStartSec exceeds the default deadline"; fi

# the make targets and docs are covered by test_make_targets.sh; here, only that the installer embeds all five payloads
for p in platform/backup/backup.sh platform/backup/restore.sh platform/backup/window.env platform/backup/platform-backup.service platform/backup/platform-backup-timer.timer; do
  if grep -qxF "# BEGIN-PAYLOAD $p" "$script"; then _pass; else _fail "install-backup.sh embeds $p"; fi
done

t_finish
