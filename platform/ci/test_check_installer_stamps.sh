#!/usr/bin/env bash
# Tests for check-installer-stamps.sh: a scratch tree of four fake installers (every host result and checkout fault), then
# the real installers (the script's stamp recompute must agree with ../lint/embed-payloads.sh).
# SC1091: sourced by relative path. SC2154: rc and out are set by run_cmd from lib.sh.
# shellcheck disable=SC1091,SC2154
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/check-installer-stamps.sh"
embed_tool="$here/../lint/embed-payloads.sh"
real_installers=("$here"/../host/install-*.sh)

t_init
names=(deploy-user data ingress jobs)
tab=$'\t'
newer="if the host installer is already from a newer main, re-run the latest deploy instead"

# stamp_of <file>: the stamp as the embed tool computes it (stamp line set to the empty value).
stamp_of() { sed 's/^readonly INSTALLER_STAMP=.*/readonly INSTALLER_STAMP=/' "$1" | sha256sum | cut -c1-16; }

# mk_installer <root> <name>: a fake installer carrying a correct stamp.
mk_installer() {
  local f="$1/platform/host/install-$2.sh"
  mkdir -p "$1/platform/host"
  printf '#!/usr/bin/env bash\n# fake installer %s\nreadonly INSTALLER_STAMP=\necho install %s\n' "$2" "$2" > "$f"
  local s
  s="$(stamp_of "$f")"
  sed -i "s/^readonly INSTALLER_STAMP=.*/readonly INSTALLER_STAMP=$s/" "$f"
}

# stamp_in <root> <name>
stamp_in() { sed -n 's/^readonly INSTALLER_STAMP=//p' "$1/platform/host/install-$2.sh"; }

# host_out <root> [name=value ...]: four lines in order with the stamps from the tree, overridden by name=value.
host_out() {
  local root="$1" n v o="" ov
  shift
  for n in "${names[@]}"; do
    v="$(stamp_in "$root" "$n")"
    for ov in "$@"; do
      if [ "${ov%%=*}" = "$n" ]; then v="${ov#*=}"; fi
    done
    o+="$n$tab$v"$'\n'
  done
  printf '%s' "$o"
}

in_dir() { local d="$1"; shift; ( cd "$d" || exit 99; "$@" ); }

tree="$T_TMP/tree"
for n in "${names[@]}"; do mk_installer "$tree" "$n"; done
dat="$(stamp_in "$tree" data)"

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree")"
expect_rc "all match" 0
expect_out_has "all match message" "check-installer-stamps: host installers match this commit"

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree")"$'\n'
expect_rc "trailing newline tolerated" 0

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree" data=0123456789abcdef)"
expect_rc "one differs" 1
expect_out_has "names the installer and its command" "host installer data differs from this commit (host 0123456789abcdef, expected $dat): run \`make host-data HOST=<alias> ARGS=\"install\"\`"
expect_out_lacks "others not named" "host installer jobs differs"
expect_out_has "newer-main line" "$newer"

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree" deploy-user=0123456789abcdef jobs=fedcba9876543210)"
expect_rc "two differ" 1
expect_out_has "deploy-user uses the pubkey form" "make host-deploy-user HOST=<alias> ARGS=\"install --pubkey-file PATH\""
expect_out_has "jobs listed too" "make host-jobs HOST=<alias> ARGS=\"install\""
expect_out_has "newer-main line with two" "$newer"

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree" ingress=missing)"
expect_rc "missing" 1
expect_out_has "missing echoed" "host installer ingress differs from this commit (host missing,"

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree" ingress=invalid)"
expect_rc "invalid" 1
expect_out_has "invalid echoed" "host installer ingress differs from this commit (host invalid,"

absent="$(host_out "$tree" | grep -v '^jobs')"
run_cmd in_dir "$tree" "$script" 0 "$absent"
expect_rc "absent name" 1
expect_out_has "absent name is drift" "host installer jobs differs from this commit"

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree" data="::warning::boom")"
expect_rc "workflow command as a value" 1
expect_out_has "value printed as unparsed" "host installer data differs from this commit (host unparsed,"
expect_out_lacks "raw host text not echoed" "::warning::boom"

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree" "data=${dat}${dat}")"
expect_rc "long hex" 1
expect_out_has "long hex printed as unparsed" "host unparsed,"

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree" "data=${dat}")"$'\n'"extra${tab}x"
expect_rc "extra line" 1
expect_out_has "extra line is drift" "differs from this commit"

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree" "data=${dat}${tab}extra")"
expect_rc "extra field" 1
expect_out_has "extra field is drift" "host installer data differs from this commit"

unknown="$(host_out "$tree" | sed 's/^jobs/other/')"
run_cmd in_dir "$tree" "$script" 0 "$unknown"
expect_rc "unknown name" 1

run_cmd in_dir "$tree" "$script" 0 ""
expect_rc "empty output" 1
expect_out_has "empty output names every installer" "host installer deploy-user differs from this commit"
expect_out_has "empty output newer-main line" "$newer"

drifted="$(host_out "$tree" data=0123456789abcdef)"
run_cmd in_dir "$tree" "$script" 2 "$drifted"
expect_rc "host rc 2" 1
expect_out_has "dispatcher line" "the host dispatcher has no 'stamps' command: run \`make host-deploy-user HOST=<alias> ARGS=\"install --pubkey-file PATH\"\`"
expect_out_has "rc 2 newer-main line" "$newer"
expect_out_lacks "rc 2 does not parse the host output" "differs from this commit"

for badrc in 1 2 255; do
  run_cmd in_dir "$tree" "$script" "$badrc" "$(host_out "$tree")"
  expect_rc "host rc $badrc with matching output" 1
  expect_out_has "host rc $badrc with matching output has the newer-main line" "$newer"
  expect_out_lacks "host rc $badrc with matching output is not a pass" "host installers match"
done

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree" data=0123456789ABCDEF)"
expect_rc "uppercase hex" 1
expect_out_has "uppercase hex printed as unparsed" "host installer data differs from this commit (host unparsed,"

run_cmd in_dir "$tree" "$script" 0 "$(host_out "$tree")"$'\n'"extra${tab}x"
expect_out_has "an extra line makes every name unparsed" "host installer data differs from this commit (host unparsed,"

run_cmd in_dir "$tree" "$script" 0 "$unknown"
expect_out_has "unknown name makes every name unparsed" "host installer jobs differs from this commit (host unparsed,"

run_cmd in_dir "$tree" "$script" 255 "distinctive-host-text-77 $drifted"
expect_rc "host rc 255" 1
expect_out_has "refusing to deploy blind" "reading host installer stamps failed (rc=255); refusing to deploy blind"
expect_out_has "rc 255 newer-main line" "$newer"
expect_out_lacks "rc 255 does not echo the host output" "distinctive-host-text-77"
expect_out_lacks "rc 255 does not parse the host output" "differs from this commit"

# Checkout faults: exit 2 before the host result is consulted.
bad="$T_TMP/bad"
cp -r "$tree" "$bad"
sed -i 's/^readonly INSTALLER_STAMP=.*/readonly INSTALLER_STAMP=/' "$bad/platform/host/install-data.sh"
run_cmd in_dir "$bad" "$script" 0 "$(host_out "$tree")"
expect_rc "empty checkout stamp" 2
expect_out_has "empty checkout stamp message" "install-data.sh stamp is stale or empty: run make embed"

run_cmd in_dir "$bad" "$script" 0 "$drifted"
expect_rc "empty checkout stamp with drifted host" 2
expect_out_has "stale line with drifted host" "stamp is stale or empty: run make embed"
expect_out_lacks "host result not consulted (drift)" "differs from this commit"

rm -rf "$bad"
cp -r "$tree" "$bad"
sed -i '/^readonly INSTALLER_STAMP=/d' "$bad/platform/host/install-jobs.sh"
run_cmd in_dir "$bad" "$script" 0 "$(host_out "$tree")"
expect_rc "installer without a stamp line" 2
expect_out_has "no stamp line message" "install-jobs.sh stamp is stale or empty"

rm -rf "$bad"
cp -r "$tree" "$bad"
echo "readonly INSTALLER_STAMP=0123456789abcdef" >> "$bad/platform/host/install-deploy-user.sh"
run_cmd in_dir "$bad" "$script" 0 "$(host_out "$tree")"
expect_rc "duplicate stamp line" 2
expect_out_has "duplicate stamp line message" "install-deploy-user.sh stamp is stale or empty"

rm -rf "$bad"
cp -r "$tree" "$bad"
echo "# one more byte" >> "$bad/platform/host/install-ingress.sh"
run_cmd in_dir "$bad" "$script" 0 "$(host_out "$tree")"
expect_rc "stale checkout stamp" 2
expect_out_has "stale checkout stamp message" "install-ingress.sh stamp is stale or empty: run make embed"

run_cmd in_dir "$bad" "$script" 2 "$drifted"
expect_rc "host rc 2 with a stale checkout stamp" 2
expect_out_has "checkout validation wins" "stamp is stale or empty: run make embed"
expect_out_lacks "no dispatcher line" "the host dispatcher has no 'stamps' command"
expect_out_lacks "no differs line" "differs from this commit"

run_cmd in_dir "$tree" "$script" 0
expect_rc "too few arguments" 2
run_cmd in_dir "$tree" "$script" 0 "x" "y"
expect_rc "too many arguments" 2
run_cmd in_dir "$tree" "$script" x "$(host_out "$tree")"
expect_rc "non-numeric rc" 2

# Real tree: the script runs from the real repo root against the committed installers.
real_root="$(cd "$here/../.." && pwd)"
real_out=""
for n in "${names[@]}"; do
  real_out+="$n$tab$(sed -n 's/^readonly INSTALLER_STAMP=//p' "$real_root/platform/host/install-$n.sh")"$'\n'
done
run_cmd in_dir "$real_root" "$script" 0 "$real_out"
expect_rc "real installers: the recompute agrees with the embed tool" 0

# One byte of a real installer changed in a scratch copy, stamp line untouched: stale (exit 2).
real_copy="$T_TMP/real"
mkdir -p "$real_copy/platform/host"
cp "${real_installers[@]}" "$real_copy/platform/host/"
printf '#' >> "$real_copy/platform/host/install-data.sh"
run_cmd in_dir "$real_copy" "$script" 0 "$real_out"
expect_rc "real installer with one byte changed" 2
expect_out_has "one-byte change is a stale stamp" "install-data.sh stamp is stale or empty: run make embed"

# The embed tool is the source of the normalisation the script mirrors, so it must exist at this path.
expect_file "embed tool present" "$embed_tool"

t_finish
