#!/usr/bin/env bash
# Static checks for compose.host-network.yaml: the blue/green cloudflared pair for hosts that are not the app host.
# Offline and fast: no docker. Two kinds of check:
#   - shape: exactly the two connector services on the host network, with no network, port or logging keys;
#   - parity: each colour equals the same colour in compose.yaml (the app host's file) except networking and the
#     image pin, so the two files cannot drift apart unnoticed.
# Every property has a mutation case (a mutated copy must fail with a named reason; the real files must pass), and
# the parity exceptions have negative cases (a repin, a network-only change) that must leave parity passing.
#
# shellcheck disable=SC1091,SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
# shellcheck source=../lib/yaml-subset.sh
. "$here/../lib/yaml-subset.sh"

t_init

colours="blue green"
img_re='^ghcr\.io/gpropersi/cloudflared-supervisor:[0-9]+@sha256:[0-9a-f]{64}$'
# A different, valid digest, assembled at run time (a literal 64-hex run would trip the secrets scans).
other_digest="sha256:$(printf '%064d' 0 | tr '0' 'a')"

# The token group the installer checks and the compose group_add must name the same gid.
token_gid="$(sed -n 's/^readonly TOKEN_GID=\([0-9][0-9]*\)$/\1/p' "$here/../host/install-cloudflared-host.sh")"
[ -n "$token_gid" ] || { _fail "could not read TOKEN_GID from the installer"; exit 1; }

REASONS=()
r() { REASONS+=("$*"); }

# flat <yaml> <out>: flatten, or record why it cannot be read.
flat() {
  ys_flatten < "$1" > "$2" 2> "$2-err" || { r "$1 is outside the YAML subset: $(cat "$2-err")"; return 1; }
}

# parity_lines <flat> <colour>: the colour's keys and values, minus the exceptions.
parity_lines() {
  awk -F '\t' -v p="services/cloudflared-$2/" 'index($1, p) == 1 {
    k = substr($1, length(p) + 1)
    if (k ~ /^(networks|network_mode|image)(\[|\/|$)/) next
    print k "\t" substr($0, length($1) + 2)
  }' "$1" | sort
}

# run_checks <host-compose> <pi-compose>: fill REASONS.
run_checks() {
  local host="$1" pi="$2" hf="$T_TMP/host-flat" pf="$T_TMP/pi-flat" c k svc v svcs
  REASONS=()
  flat "$host" "$hf" || return 0
  flat "$pi" "$pf" || return 0

  [ "$(ys_get "$hf" name)" = platform-cloudflared ] || r "name must be platform-cloudflared"
  ys_has "$hf" networks && r "top-level networks is not allowed"
  svcs="$(ys_children "$hf" services | sort | tr '\n' ' ')"
  [ "$svcs" = "cloudflared-blue cloudflared-green " ] || r "service set is not exactly cloudflared-blue cloudflared-green (got: $svcs)"

  for c in $colours; do
    svc="cloudflared-$c"
    [ "$(ys_get "$hf" "services/$svc/network_mode")" = host ] || r "$svc: network_mode must be exactly host"
    for v in networks ports privileged cap_add logging command; do
      ys_has "$hf" "services/$svc/$v" && r "$svc: $v is not allowed"
    done
    ys_has "$hf" "services/$svc/labels" && r "$svc: labels are not allowed (no platform.app label)"
    grep -qF 'docker.sock' <<<"$(ys_list "$hf" "services/$svc/volumes")" && r "$svc: the Docker socket is mounted"
    ys_has "$hf" "services/$svc/environment/TUNNEL_TOKEN" && r "$svc: inline token is not allowed"
    [ "$(ys_list "$hf" "services/$svc/group_add")" = "$token_gid" ] || r "$svc: group_add must be exactly the installer's TOKEN_GID ($token_gid)"
    [[ "$(ys_get "$hf" "services/$svc/image")" =~ $img_re ]] || r "$svc: image must be a pinned gpropersi supervisor image (floating or unpinned)"
    grep -qxF "/etc/platform/cloudflared.token:/run/cloudflared/token:ro" <<<"$(ys_list "$hf" "services/$svc/volumes")" || r "$svc: token mount must be read-only"
    grep -qxF "/etc/platform/cloudflared.webhook:/run/secrets/cloudflared-webhook:ro" <<<"$(ys_list "$hf" "services/$svc/volumes")" || r "$svc: webhook mount must be read-only and outside the state directory"
    grep -qxF "/var/lib/cloudflared-supervisor-$c:/var/lib/cloudflared-supervisor" <<<"$(ys_list "$hf" "services/$svc/volumes")" || r "$svc: state volume must be exactly its own directory (read-write)"
  done

  [ "$(ys_get "$hf" services/cloudflared-blue/environment/CF_METRICS_A)" = 127.0.0.1:20251 ] || r "blue CF_METRICS_A is not 127.0.0.1:20251"
  [ "$(ys_get "$hf" services/cloudflared-blue/environment/CF_METRICS_B)" = 127.0.0.1:20252 ] || r "blue CF_METRICS_B is not 127.0.0.1:20252"
  [ "$(ys_get "$hf" services/cloudflared-green/environment/CF_METRICS_A)" = 127.0.0.1:20253 ] || r "green CF_METRICS_A is not 127.0.0.1:20253"
  [ "$(ys_get "$hf" services/cloudflared-green/environment/CF_METRICS_B)" = 127.0.0.1:20254 ] || r "green CF_METRICS_B is not 127.0.0.1:20254"
  [ "$(for c in $colours; do for k in A B; do ys_get "$hf" "services/cloudflared-$c/environment/CF_METRICS_$k"; done; done | sort -u | wc -l)" = 4 ] || r "metrics addresses must be four distinct values"
  [ "$(for c in $colours; do grep -F ':/var/lib/cloudflared-supervisor' <<<"$(ys_list "$hf" "services/cloudflared-$c/volumes")" | cut -d: -f1; done | sort -u | wc -l)" = 2 ] || r "state directories must be distinct"

  for c in $colours; do
    [ -n "$(parity_lines "$pf" "$c")" ] || r "parity: no keys found for $c in the app host file"
    if [ "$(parity_lines "$hf" "$c")" != "$(parity_lines "$pf" "$c")" ]; then
      r "parity: $c differs from the app host's $c"
    fi
  done
}

# pin_note <host-compose> <pi-compose>: print a note for each colour whose image pin differs between the files.
# Advisory only: the two files are bumped separately, so a difference is allowed, just worth seeing.
pin_note() {
  local hf="$T_TMP/note-host-flat" pf="$T_TMP/note-pi-flat" c
  flat "$1" "$hf" && flat "$2" "$pf" || return 0
  for c in $colours; do
    [ "$(ys_get "$hf" "services/cloudflared-$c/image")" = "$(ys_get "$pf" "services/cloudflared-$c/image")" ] \
      || echo "note: cloudflared-$c image pin differs between compose.host-network.yaml and compose.yaml (bump both, or accept the divergence)"
  done
}

# ---- mutation helper (awk; pattern and text through the environment) ----
# m_edit <file> <mode> <regex> [text]: mode replace|delete|after|dropkey, limited to service M_SVC when set.
m_edit() {
  local file="$1" mode="$2" re="$3" text="${4:-}"
  M_MODE="$mode" M_RE="$re" M_TEXT="$text" awk '
    function indent_of(s) { match(s, /^ */); return RLENGTH }
    BEGIN { mode = ENVIRON["M_MODE"]; re = ENVIRON["M_RE"]; text = ENVIRON["M_TEXT"]; svc = ENVIRON["M_SVC"]
            gsub(/\\n/, "\n", text); inscope = (svc == ""); dropping = 0 }
    {
      n = indent_of($0)
      if (svc != "" && $0 !~ /^ *#/ && $0 !~ /^ *$/ && n == 2 && $0 ~ /^ *[A-Za-z0-9_-]+:/) { inscope = ($0 ~ ("^ *" svc ":")) }
      else if (svc != "" && $0 !~ /^ *$/ && n < 2) { inscope = 0 }
      if (dropping) { if ($0 ~ /^ *$/ || n > dropind) next; dropping = 0 }
      if (inscope && $0 ~ re) {
        if (mode == "replace") { print text; next }
        if (mode == "delete") next
        if (mode == "after") { print; print text; next }
        if (mode == "dropkey") { dropping = 1; dropind = n; next }
      }
      print
    }
  ' "$file" > "${file}-new" && mv "${file}-new" "$file"
}

mutn=0
# mutate <label> <expected reason substring> <host|pi> <svc|-> <mode> <regex> [text]
mutate() {
  local label="$1" wantr="$2" which="$3" svc="$4" mode="$5" re="$6" text="${7:-}" dir hit=0 r_
  mutn=$((mutn + 1))
  dir="$T_TMP/mut-$mutn"
  mkdir -p "$dir"
  cp "$here/compose.host-network.yaml" "$dir/host.yaml"
  cp "$here/compose.yaml" "$dir/pi.yaml"
  M_SVC=
  [ "$svc" = - ] || M_SVC="$svc"
  export M_SVC
  if [ "$mode" = sed ]; then
    sed -E -i -e "$re" "$dir/$which.yaml"
  else
    m_edit "$dir/$which.yaml" "$mode" "$re" "$text"
  fi
  unset M_SVC
  if cmp -s "$dir/$which.yaml" "$here/$([ "$which" = host ] && echo compose.host-network.yaml || echo compose.yaml)"; then
    _fail "mutation '$label' did not change the file" "regex: $re"
    return
  fi
  run_checks "$dir/host.yaml" "$dir/pi.yaml"
  for r_ in ${REASONS[@]+"${REASONS[@]}"}; do [[ "$r_" == *"$wantr"* ]] && hit=1; done
  if [ "$hit" = 1 ]; then _pass; else _fail "mutation '$label' was not caught with a reason containing '$wantr'" "got: ${REASONS[*]:-no failure at all}"; fi
}

# keeps_parity <label> <host|pi> <svc> <mode> <regex> [text]: the edit must not make parity fail.
keeps_parity() {
  local label="$1" which="$2" svc="$3" mode="$4" re="$5" text="${6:-}" dir r_ bad=0
  mutn=$((mutn + 1))
  dir="$T_TMP/mut-$mutn"
  mkdir -p "$dir"
  cp "$here/compose.host-network.yaml" "$dir/host.yaml"
  cp "$here/compose.yaml" "$dir/pi.yaml"
  M_SVC="$svc"
  export M_SVC
  cp "$dir/$which.yaml" "$dir/before.yaml"
  m_edit "$dir/$which.yaml" "$mode" "$re" "$text"
  unset M_SVC
  if cmp -s "$dir/before.yaml" "$dir/$which.yaml"; then
    _fail "negative case '$label' did not change the file" "regex: $re"
    return
  fi
  run_checks "$dir/host.yaml" "$dir/pi.yaml"
  for r_ in ${REASONS[@]+"${REASONS[@]}"}; do [[ "$r_" == parity:* ]] && bad=1; done
  if [ "$bad" = 0 ]; then _pass; else _fail "negative case '$label' broke parity" "got: ${REASONS[*]}"; fi
}

# ---- the real files ----
run_checks "$here/compose.host-network.yaml" "$here/compose.yaml"
if [ "${#REASONS[@]}" = 0 ]; then _pass; else _fail "the real files must pass" "${REASONS[*]}"; fi

# ---- image pin divergence note (non-failing) ----
note_out="$(pin_note "$here/compose.host-network.yaml" "$here/compose.yaml")"
[ -z "$note_out" ] || echo "$note_out"
cp "$here/compose.host-network.yaml" "$T_TMP/same-host.yaml"
cp "$here/compose.host-network.yaml" "$T_TMP/same-pi.yaml"
if [ -z "$(pin_note "$T_TMP/same-host.yaml" "$T_TMP/same-pi.yaml")" ]; then _pass; else _fail "identical pins must print no note"; fi
cp "$here/compose.host-network.yaml" "$T_TMP/div-host.yaml"
M_SVC=cloudflared-blue m_edit "$T_TMP/div-host.yaml" replace '^    image:' "    image: ghcr.io/gpropersi/cloudflared-supervisor:1@${other_digest}"
div_out="$(pin_note "$T_TMP/div-host.yaml" "$T_TMP/same-pi.yaml")"
if [[ "$div_out" == *"cloudflared-blue image pin differs"* && "$div_out" != *"cloudflared-green"* ]]; then _pass; else _fail "a repinned colour must print exactly its note" "got: $div_out"; fi

# ---- parity negative cases ----
keeps_parity "repin blue in the host file" host cloudflared-blue replace '^    image:' "    image: ghcr.io/gpropersi/cloudflared-supervisor:1@${other_digest}"
keeps_parity "repin green in the host file" host cloudflared-green replace '^    image:' "    image: ghcr.io/gpropersi/cloudflared-supervisor:1@${other_digest}"
keeps_parity "repin green in the app host file" pi cloudflared-green replace '^    image:' "    image: ghcr.io/gpropersi/cloudflared-supervisor:1@${other_digest}"
keeps_parity "host file network_mode changed" host cloudflared-blue replace '^    network_mode:' '    network_mode: bridge'
keeps_parity "app host file network renamed" pi cloudflared-green replace '^      - platform$' '      - other'

# ---- mutation cases ----
mutate "drop network_mode" "network_mode must be exactly host" host cloudflared-blue delete '^    network_mode:'
mutate "network_mode bridge" "network_mode must be exactly host" host cloudflared-green replace '^    network_mode:' '    network_mode: bridge'
mutate "networks re-added" "networks is not allowed" host cloudflared-blue after '^    network_mode:' '    networks:\n      - platform'
mutate "published port" "ports is not allowed" host cloudflared-green after '^    network_mode:' '    ports:\n      - "80:80"'
mutate "third service" "service set is not exactly" host - sed '$a\  extra:\n    image: docker.io/library/busybox:1'
mutate "mem_limit changed in one colour" "parity: green" host cloudflared-green replace '^    mem_limit:' '    mem_limit: 256m'
mutate "tmpfs dropped" "parity: blue" host cloudflared-blue dropkey '^    tmpfs:'
mutate "metrics ports collide" "CF_METRICS_A is not" host cloudflared-green replace '^      CF_METRICS_A:' '      CF_METRICS_A: 127.0.0.1:20251'
mutate "one state directory for both colours" "state directories must be distinct" host cloudflared-green replace '^      - /var/lib/cloudflared-supervisor-' '      - /var/lib/cloudflared-supervisor-blue:/var/lib/cloudflared-supervisor'
mutate "token mount read-write" "token mount must be read-only" host cloudflared-blue replace '^      - /etc/platform/cloudflared.token' '      - /etc/platform/cloudflared.token:/run/cloudflared/token'
mutate "logging key added" "logging is not allowed" host cloudflared-green after '^    network_mode:' '    logging:\n      driver: json-file'
mutate "project named like the app host" "name must be platform-cloudflared" host - replace '^name:' 'name: platform-ingress'
mutate "healthcheck interval changed in the app host file" "parity: blue" pi cloudflared-blue replace '^      interval:' '      interval: 30s'
mutate "user changed in the host file" "parity: green" host cloudflared-green replace '^    user:' '    user: "0:0"'
mutate "group_add differs from the installer's TOKEN_GID" "group_add must be exactly the installer's TOKEN_GID" host cloudflared-green replace '^      - "64321"' '      - "64322"'
mutate "Docker socket mounted" "the Docker socket is mounted" host cloudflared-blue after '^    volumes:' '      - /var/run/docker.sock:/var/run/docker.sock:ro'
mutate "inline token" "inline token is not allowed" host cloudflared-blue after '^    environment:' '      TUNNEL_TOKEN: placeholder'
mutate "floating tag" "floating or unpinned" host cloudflared-blue replace '^    image:' '    image: ghcr.io/gpropersi/cloudflared-supervisor:latest'
mutate "leaves the YAML subset" "outside the YAML subset" host cloudflared-blue replace '^    cap_drop:' '    cap_drop: [ALL]'

t_finish
