#!/usr/bin/env bash
# embed-payloads.sh: keep the payloads embedded in platform/host/install-*.sh equal to their tracked sources.
#
# The installers run on a host with no checkout, so each one carries the files it installs (dispatcher, login-shell
# wrapper, root helper) as an embedded copy. Every embedded payload sits between a marker pair, found generically
# in any platform/host/install-*.sh (adding an installer or a payload needs no change here):
#
#   # BEGIN-PAYLOAD <repo-relative source path>
#   payload_<basename incl. extension, non-alphanumerics as _>() {
#     cat <<'PLATFORM_PAYLOAD_EOF'
#   <the source file, byte for byte>
#   PLATFORM_PAYLOAD_EOF
#   }
#   # END-PAYLOAD <repo-relative source path>
#
# Default mode regenerates every region from its source (idempotent). --check rewrites nothing: it prints
# `DRIFT <installer>: <source path>` per differing payload and exits 1.
#
# Usage: embed-payloads.sh [--check] [--root DIR]
# Exit: 0 in sync (or regenerated) | 1 drift found (--check) | 2 usage error, bad marker, or unusable source
#       (missing, no trailing newline, contains the heredoc delimiter or a marker line, path outside the repo),
#       an installer with no region, an orphan heredoc delimiter line, a marker pair outside the installers,
#       or two payloads in one installer that would define the same function
# Installer header prose must not start a line with "# BEGIN-PAYLOAD " or "# END-PAYLOAD ".
set -euo pipefail

export LC_ALL=C

readonly DELIM="PLATFORM_PAYLOAD_EOF"
check=0
root=""

while [ $# -gt 0 ]; do
  case "$1" in
    --check) check=1; shift ;;
    --root) [ $# -ge 2 ] || { echo "missing value for --root" >&2; exit 2; }; root="$2"; shift 2 ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { print; next } { exit }' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

[ -n "$root" ] || root="$(git rev-parse --show-toplevel)"
cd "$root"

drift=0
total_regions=0
marker_re='^# (BEGIN|END)-PAYLOAD( |$)'

die() { echo "embed-payloads: $1" >&2; exit 2; }

# render <source>: sets REGION to the full marker-to-marker region for the source (each line newline-terminated).
render() {
  local src="$1" line name
  case "$src" in
    /*|*..*|*[!A-Za-z0-9._/-]*) die "unsafe payload path: $src" ;;
  esac
  [ -f "$src" ] || die "payload source not found: $src"
  [ ! -s "$src" ] || [ -z "$(tail -c1 "$src")" ] || die "payload source must end with a newline: $src"
  name="$(basename "$src")"
  name="${name//[!A-Za-z0-9]/_}"
  FN="payload_${name}"
  REGION="# BEGIN-PAYLOAD $src"$'\n'"${FN}() {"$'\n'"  cat <<'$DELIM'"$'\n'
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$line" != "$DELIM" ] || die "payload source contains the heredoc delimiter: $src"
    [[ ! "$line" =~ $marker_re ]] || die "payload source contains a payload marker line: $src"
    REGION+="$line"$'\n'
  done < "$src"
  REGION+="$DELIM"$'\n'"}"$'\n'"# END-PAYLOAD $src"$'\n'
}

# process <installer>: rewrites (or checks) every payload region in the file.
process() {
  local file="$1" out line src="" orig="" in=0 changed=0 count=0 seen=" " begin_re='^# BEGIN-PAYLOAD (.+)$'
  out=""
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in" -eq 0 ]; then
      if [[ "$line" =~ $begin_re ]]; then
        src="${BASH_REMATCH[1]}"
        orig="$line"$'\n'
        in=1
      else
        [ "$line" != "$DELIM" ] || die "$file: a $DELIM heredoc line outside any BEGIN-PAYLOAD region"
        out+="$line"$'\n'
      fi
    else
      orig+="$line"$'\n'
      if [ "$line" = "# END-PAYLOAD $src" ]; then
        render "$src"
        [[ "$seen" != *" $FN "* ]] || die "$file: two payloads would define the function $FN"
        seen+="$FN "
        count=$((count + 1))
        if [ "$REGION" != "$orig" ]; then
          [ "$check" -eq 0 ] || echo "DRIFT $file: $src"
          drift=1
          changed=1
        fi
        out+="$REGION"
        in=0
      elif [[ "$line" =~ $begin_re ]]; then
        die "$file: BEGIN-PAYLOAD for $src is not closed before the next BEGIN-PAYLOAD"
      fi
    fi
  done < "$file"
  [ "$in" -eq 0 ] || die "$file: BEGIN-PAYLOAD $src has no END-PAYLOAD"
  [ "$count" -gt 0 ] || die "$file: no payload region found (a deleted or misspelled marker would silently stop the check)"
  total_regions=$((total_regions + count))
  # Writes are deferred until every installer parsed cleanly, so a bad input rewrites nothing.
  if [ "$check" -eq 0 ] && [ "$changed" -eq 1 ]; then
    pending_files+=("$file")
    pending_out+=("$out")
  fi
}

shopt -s nullglob
installers=(platform/host/install-*.sh)
[ "${#installers[@]}" -gt 0 ] || die "no platform/host/install-*.sh installer found"

# Markers are only honoured in the installers; a pair anywhere else would be silently ignored, so refuse it.
# (test_*.sh files and this tool carry marker text as fixtures/docs.)
if [ -d platform ]; then
  while IFS= read -r f; do
    if grep -qE "$marker_re" "$f"; then die "payload marker outside platform/host/install-*.sh: $f"; fi
  done < <(find platform -type f -name '*.sh' ! -path 'platform/host/install-*.sh' ! -name 'test_*.sh' ! -path 'platform/lint/embed-payloads.sh' | sort)
fi

pending_files=()
pending_out=()
for f in "${installers[@]}"; do
  process "$f"
done
for i in "${!pending_files[@]}"; do
  printf '%s' "${pending_out[$i]}" > "${pending_files[$i]}"
  echo "updated ${pending_files[$i]}"
done

if [ "$check" -eq 1 ]; then
  if [ "$drift" -eq 1 ]; then
    echo "embed-payloads: embedded payloads differ from their sources; run: make embed" >&2
    exit 1
  fi
  echo "embed-payloads: OK (${#installers[@]} installer(s), $total_regions payload(s))"
else
  echo "embed-payloads: embedded payloads in sync (${#installers[@]} installer(s), $total_regions payload(s))"
fi
