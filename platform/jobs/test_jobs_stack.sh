#!/usr/bin/env bash
# Static checks for the jobs runner image and compose service (compose.yaml, Dockerfile, Dockerfile.testapp,
# GO_VERSION). Offline and fast: no docker. Each security property has a mutation case: a mutated copy of the tree must
# fail with a named reason, and the unmutated tree must pass.
#
# compose.yaml is read with yaml-subset.sh, which refuses anything outside a small regular YAML subset, so a file
# that drifts out of what the test understands fails here instead of being misread.
# shellcheck disable=SC1091,SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
# shellcheck source=../lib/yaml-subset.sh
. "$here/../lib/yaml-subset.sh"

t_init

# Mounts the runner must have, exactly: container path -> mode. Registry, secrets, window dir and the two single-file
# mounts are read-only; status and state are the only writable ones. Host and container paths are identical.
ro_mounts="/var/lib/platform/registry /var/lib/platform/job-secrets /opt/platform/backup /etc/platform/jobs.env /etc/platform/jobs-redis.password"
rw_mounts="/var/lib/platform/jobs-status /var/lib/platform/jobs-state"

REASONS=()
r() { REASONS+=("$*"); }

# check_dockerfile <file> <label> <runner|testapp>: base images pinned by digest, builder tag tied to GO_VERSION.
check_dockerfile() {
  local file="$1" label="$2" kind="$3" dir gov line n_from=0 builder_tag src
  dir="$(dirname "$file")"
  if [ ! -s "$file" ]; then r "$label: file is missing"; return; fi
  gov="$(tr -d '[:space:]' < "$dir/GO_VERSION" 2>/dev/null)"
  [[ "$gov" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || r "$label: GO_VERSION must be an exact x.y.z (got '$gov')"
  while IFS= read -r line; do
    n_from=$((n_from + 1))
    if ! [[ "$line" =~ ^FROM[[:space:]]+(golang:[0-9.]+|gcr\.io/distroless/static-debian12:nonroot)@sha256:[0-9a-f]{64}([[:space:]]+AS[[:space:]]+[a-z]+)?$ ]]; then
      r "$label: base image is not a pinned golang or distroless/static-debian12:nonroot with a sha256 digest ($line)"
    fi
    if [[ "$line" =~ ^FROM[[:space:]]+golang:([0-9.]+)@ ]]; then
      builder_tag="${BASH_REMATCH[1]}"
      [ "$builder_tag" = "$gov" ] || r "$label: builder golang:$builder_tag differs from GO_VERSION $gov"
    fi
  done < <(grep -E '^FROM[[:space:]]' "$file")
  [ "$n_from" -eq 2 ] || r "$label: want exactly two FROM stages (builder, final), got $n_from"
  grep -E '^FROM[[:space:]]' "$file" | head -n 1 | grep -q 'golang:' || r "$label: the first stage must be the golang builder"
  grep -E '^FROM[[:space:]]' "$file" | tail -n 1 | grep -q 'gcr.io/distroless/static-debian12:nonroot@' || r "$label: the final stage must be gcr.io/distroless/static-debian12:nonroot by digest"
  grep -qxF 'USER 65532:65532' "$file" || r "$label: USER must be 65532:65532"
  grep -qF 'CGO_ENABLED=0' "$file" || r "$label: CGO_ENABLED=0 is required"
  grep -qF -- '-trimpath' "$file" || r "$label: -trimpath is required"
  grep -qxE 'ARG VERSION(=.*)?' "$file" || r "$label: ARG VERSION is required"
  grep -qF -- '-X main.version=${VERSION}' "$file" || r "$label: the version must be set with -X main.version=\${VERSION}"
  grep -qE '^COPY --from=build ' "$file" || r "$label: the final stage must copy the binary from the build stage"
  # Every COPY source must exist; the runner Dockerfile never copies a directory or '.', and never anything testapp.
  while IFS= read -r line; do
    [[ "$line" == COPY\ --from=* ]] && continue
    while IFS= read -r src; do
      [ -e "$dir/$src" ] || r "$label: COPY source '$src' does not exist (the COPY list and the files drifted)"
      if [ "$kind" = runner ]; then
        [[ "$src" == */ || "$src" == . || -d "$dir/$src" ]] && r "$label: COPY must name files, not the directory '$src'"
        [[ "$src" == *testapp* ]] && r "$label: the runner COPY list must not name testapp ($src)"
      fi
    done < <(awk '{ for (i = 2; i < NF; i++) if ($i !~ /^--/) print $i }' <<<"$line")
  done < <(grep -E '^COPY[[:space:]]' "$file")
  if [ "$kind" = runner ]; then
    grep -qxF 'ENTRYPOINT ["/runner"]' "$file" || r "$label: ENTRYPOINT must be [\"/runner\"]"
    grep -qxF 'CMD ["runner"]' "$file" || r "$label: CMD must be [\"runner\"]"
    grep -qF './cmd/runner' "$file" || r "$label: the build target must be ./cmd/runner"
    grep -q 'testapp' "$file" && r "$label: mentions testapp (it must stay out of the runner image build)"
  else
    grep -qxF 'ENTRYPOINT ["/testapp"]' "$file" || r "$label: ENTRYPOINT must be [\"/testapp\"]"
    grep -qF './testapp' "$file" || r "$label: the build target must be ./testapp"
  fi
}

# run_checks <dir>: fill REASONS (empty means the tree passes).
run_checks() {
  local dir="$1" cf s k v got err m want
  REASONS=()
  cf="$T_TMP/c-flat"
  err="$(ys_flatten < "$dir/compose.yaml" 2>&1 > "$cf")" || { r "compose.yaml is outside the YAML subset the test understands: $err"; : > "$cf"; }
  s=runner

  got="$(ys_children "$cf" services | sort | tr '\n' ' ')"
  [ "$got" = "runner " ] || r "service set is not exactly: runner (got: $got)"
  [ "$(ys_get "$cf" name)" = platform-jobs ] || r "compose project name must be platform-jobs"

  v="$(ys_get "$cf" "services/$s/image")"
  [[ "$v" =~ ^platform-jobs-runner:\$\{RUNNER_TAG(:\?[^}]*)?\}$ ]] || r "$s: image '$v' must be platform-jobs-runner:\${RUNNER_TAG} (a locally built image tagged by source hash)"
  [ "$(ys_get "$cf" "services/$s/pull_policy")" = never ] || r "$s: pull_policy must be never"
  [ "$(ys_get "$cf" "services/$s/container_name")" = platform-jobs-runner ] || r "$s: container_name must be platform-jobs-runner"
  for k in ports privileged network_mode cap_add labels; do
    ys_has "$cf" "services/$s/$k" && r "$s: $k is not allowed (the runner publishes nothing and carries no labels)"
  done
  ys_list "$cf" "services/$s/cap_drop" | grep -qxF ALL || r "$s: cap_drop must contain ALL"
  [ "$(ys_get "$cf" "services/$s/mem_limit")" = 48m ] || r "$s: mem_limit must be 48m"
  [ "$(ys_get "$cf" "services/$s/restart")" = unless-stopped ] || r "$s: restart must be unless-stopped"
  [ "$(ys_get "$cf" "services/$s/stop_grace_period")" = 65m ] || r "$s: stop_grace_period must be 65m (above the 1h job timeout maximum, so shutdown never SIGKILLs an in-flight run)"
  ys_list "$cf" "services/$s/security_opt" | grep -qxF no-new-privileges:true || r "$s: security_opt must contain no-new-privileges:true"
  [ "$(ys_get "$cf" "services/$s/read_only")" = true ] || r "$s: read_only must be true"
  ys_list "$cf" "services/$s/tmpfs" | grep -qxF /tmp || r "$s: tmpfs must include /tmp (read-only root)"
  [ "$(ys_get "$cf" "services/$s/user")" = "65532:65532" ] || r "$s: user must be 65532:65532"
  [ "$(ys_list "$cf" "services/$s/group_add" | tr '\n' ' ')" = "64324 " ] || r "$s: group_add must be exactly the jobs secret gid 64324"
  [ "$(ys_list "$cf" "services/$s/networks" | tr '\n' ' ')" = "platform " ] || r "$s: networks must be exactly platform (got: $(ys_list "$cf" "services/$s/networks" | tr '\n' ' '))"
  [ "$(ys_list "$cf" "services/$s/healthcheck/test" | tr '\n' ' ')" = "CMD /runner healthcheck " ] || r "$s: healthcheck must be CMD /runner healthcheck"
  for k in interval:30s timeout:5s retries:3 start_period:30s; do
    [ "$(ys_get "$cf" "services/$s/healthcheck/${k%%:*}")" = "${k#*:}" ] || r "$s: healthcheck ${k%%:*} must be ${k#*:}"
  done

  # -- environment: exactly GOMEMLIMIT=36MiB, nothing secret-looking
  while IFS= read -r k; do
    v="${k^^}"
    if [[ "$v" =~ (PASSWORD|AUTH|SECRET|TOKEN|WEBHOOK|KEY) && "$v" != *_FILE ]]; then r "$s: a secret in the environment ($k): secrets are mounted files"; fi
  done < <(ys_children "$cf" "services/$s/environment")
  if awk -F '\t' -v pre="services/$s/environment/" 'index($1, pre) == 1 && ($2 ~ /eyJ/ || $2 ~ /[0-9a-fA-F]{32}/ || $2 ~ /webhooks/ || $2 ~ /:\/\/[^\/]*@/) { f = 1 } END { exit f ? 0 : 1 }' "$cf"; then
    r "$s: an inline token or credential-looking value in the environment"
  fi
  [ "$(ys_children "$cf" "services/$s/environment" | tr '\n' ' ')" = "GOMEMLIMIT " ] || r "$s: environment must be exactly GOMEMLIMIT"
  [ "$(ys_get "$cf" "services/$s/environment/GOMEMLIMIT")" = 36MiB ] || r "$s: GOMEMLIMIT must be 36MiB (75% of mem_limit)"

  # -- mounts: the exact set, same path in and out, read-only except status and state
  local mounts
  mounts="$(ys_list "$cf" "services/$s/volumes")"
  while IFS= read -r v; do
    [ -n "$v" ] || continue
    if [[ "$v" == /opt/platform/backup/* ]]; then r "$s: single-file mount of the backup window ($v): mount the directory /opt/platform/backup (a rename-replaced window.env leaves a single-file mount stale)"; fi
  done <<<"$mounts"
  for m in $ro_mounts; do
    grep -qxF "$m:$m:ro" <<<"$mounts" || r "$s: $m must be mounted read-only as $m:$m:ro"
  done
  for m in $rw_mounts; do
    grep -qxF "$m:$m" <<<"$mounts" || r "$s: $m must be mounted read-write as $m:$m"
  done
  want=$(( $(wc -w <<<"$ro_mounts") + $(wc -w <<<"$rw_mounts") ))
  [ "$(grep -c . <<<"$mounts")" = "$want" ] || r "$s: volumes must be exactly the $want expected mounts (got $(grep -c . <<<"$mounts"))"
  ys_has "$cf" volumes && r "no top-level named volumes (every mount is a host path)"

  # -- networks
  [ "$(ys_get "$cf" networks/platform/external)" = true ] || r "network platform must be external: true"
  [ "$(ys_children "$cf" networks | sort | tr '\n' ' ')" = "platform " ] || r "unexpected network set (only platform)"
  for k in ipam enable_ipv6 driver_opts; do
    ys_has "$cf" "networks/platform/$k" && r "networks: $k is not allowed (no subnet or address literals, IPv6 off)"
  done

  # -- Dockerfiles
  check_dockerfile "$dir/Dockerfile" "Dockerfile" runner
  check_dockerfile "$dir/Dockerfile.testapp" "Dockerfile.testapp" testapp
}

# ---- mutation helpers (same awk helper as test_data_stack.sh) ----

m_edit() {
  # m_edit <file> <mode> <regex> [text]: mode replace|delete|after|before|dropkey|sub
  local file="$1" mode="$2" re="$3" text="${4:-}"
  M_MODE="$mode" M_RE="$re" M_TEXT="$text" awk -v ind="${M_IND:-2}" '
    function indent_of(s) { match(s, /^ */); return RLENGTH }
    BEGIN { mode = ENVIRON["M_MODE"]; re = ENVIRON["M_RE"]; text = ENVIRON["M_TEXT"]; svc = ENVIRON["M_SVC"]
            gsub(/\\n/, "\n", text); inscope = (svc == ""); dropping = 0 }
    {
      ind_now = indent_of($0)
      if (svc != "" && $0 !~ /^ *#/ && $0 !~ /^ *$/ && ind_now == ind && $0 ~ /^ *[A-Za-z0-9_-]+:/) {
        inscope = ($0 ~ ("^ *" svc ":"))
      } else if (svc != "" && $0 !~ /^ *$/ && ind_now < ind) { inscope = 0 }
      if (dropping) { if ($0 ~ /^ *$/ || ind_now > dropind) next; dropping = 0 }
      if (inscope && $0 ~ re) {
        if (mode == "replace") { print text; next }
        if (mode == "delete") next
        if (mode == "after") { print; print text; next }
        if (mode == "before") { print text; print; next }
        if (mode == "sub") { sub(re, text); print; next }
        if (mode == "dropkey") { dropping = 1; dropind = ind_now; next }
      }
      print
    }
  ' "$file" > "${file}-new" && mv "${file}-new" "$file"
}

mutn=0
# mutate <label> <expected reason substring> <file> <svc|-> <ind|-> <mode> <regex> [text]
# file: compose, dockerfile, testapp (Dockerfile.testapp) or goversion.
mutate() {
  local label="$1" wantr="$2" which="$3" svc="$4" ind="$5" mode="$6" re="$7" text="${8:-}" dir target hit=0 r_ changed=0
  mutn=$((mutn + 1))
  dir="$T_TMP/mut-$mutn"
  cp -R "$here" "$dir"
  case "$which" in
    compose) target="$dir/compose.yaml" ;;
    dockerfile) target="$dir/Dockerfile" ;;
    testapp) target="$dir/Dockerfile.testapp" ;;
    goversion) target="$dir/GO_VERSION" ;;
  esac
  cp "$target" "$T_TMP/before-mut"
  M_SVC=; M_IND=2
  [ "$svc" = - ] || M_SVC="$svc"
  [ "$ind" = - ] || M_IND="$ind"
  export M_SVC M_IND
  m_edit "$target" "$mode" "$re" "$text"
  cmp -s "$T_TMP/before-mut" "$target" || changed=1
  unset M_SVC M_IND
  if [ "$changed" = 0 ]; then
    _fail "mutation '$label' did not change the file" "regex: $re"
    return
  fi
  run_checks "$dir"
  for r_ in "${REASONS[@]}"; do [[ "$r_" == *"$wantr"* ]] && hit=1; done
  if [ "$hit" = 1 ]; then _pass; else _fail "mutation '$label' was not caught with a reason containing '$wantr'" "got: ${REASONS[*]:-no failure at all}"; fi
}

# ---- unmutated tree passes ----

run_checks "$here"
if [ "${#REASONS[@]}" -eq 0 ]; then _pass; else
  _fail "the unmutated jobs stack must pass every check"
  printf '  reason: %s\n' "${REASONS[@]}"
fi

# ---- mutation cases: compose.yaml ----

mutate "a label" "labels is not allowed" compose runner 2 after '^    container_name:' '    labels:\n      platform.app: runner'
mutate "a second network" "networks must be exactly platform" compose runner 2 after '^      - platform$' '      - other'
mutate "second network declared" "unexpected network set" compose - - after '^    external: true' '  other:\n    internal: true'
mutate "platform network not external" "platform must be external" compose - - replace '^    external: true' '    external: false'
mutate "a writable secrets mount" "/var/lib/platform/job-secrets must be mounted read-only" compose runner 2 replace '^      - /var/lib/platform/job-secrets' '      - /var/lib/platform/job-secrets:/var/lib/platform/job-secrets'
mutate "a writable registry mount" "/var/lib/platform/registry must be mounted read-only" compose runner 2 sub 'registry:ro$' 'registry'
mutate "a read-only status mount" "/var/lib/platform/jobs-status must be mounted read-write" compose runner 2 sub 'jobs-status$' 'jobs-status:ro'
mutate "missing group_add" "group_add must be exactly" compose runner 2 dropkey '^    group_add:'
mutate "wrong group_add" "group_add must be exactly" compose runner 2 replace '^      - "64324"' '      - "64322"'
mutate "missing cap_drop" "cap_drop must contain ALL" compose runner 2 dropkey '^    cap_drop:'
mutate "single-file window.env mount" "single-file mount of the backup window" compose runner 2 replace '^      - /opt/platform/backup:' '      - /opt/platform/backup/window.env:/opt/platform/backup/window.env:ro'
mutate "window directory mount removed" "/opt/platform/backup must be mounted read-only" compose runner 2 delete '^      - /opt/platform/backup:'
mutate "an extra mount" "volumes must be exactly the 7 expected mounts" compose runner 2 after '^      - /var/lib/platform/jobs-state' '      - /etc:/etc'
mutate "a secret name in the environment" "a secret in the environment (DISCORD_WEBHOOK)" compose runner 2 after '^      GOMEMLIMIT:' '      DISCORD_WEBHOOK: x'
mutate "a secret-looking value in the environment" "inline token or credential-looking value" compose runner 2 after '^      GOMEMLIMIT:' "      LOG_LEVEL: $(printf '%s%s' ey JhbGciOiJIUzI1NiJ9)"
mutate "a hex-run value in the environment" "inline token or credential-looking value" compose runner 2 after '^      GOMEMLIMIT:' "      LOG_LEVEL: $(printf '%s%s%s%s' 0123456789ab cdef0123 456789ab cdef0123)"
mutate "an extra environment key" "environment must be exactly GOMEMLIMIT" compose runner 2 after '^      GOMEMLIMIT:' '      LOG_LEVEL: debug'
mutate "GOMEMLIMIT changed" "GOMEMLIMIT must be 36MiB" compose runner 2 replace '^      GOMEMLIMIT:' '      GOMEMLIMIT: 48MiB'
mutate "published port" "ports is not allowed" compose runner 2 after '^    container_name:' '    ports:\n      - "8080:8080"'
mutate "privileged" "privileged is not allowed" compose runner 2 after '^    container_name:' '    privileged: true'
mutate "cap_add" "cap_add is not allowed" compose runner 2 after '^    container_name:' '    cap_add:\n      - NET_ADMIN'
mutate "root user" "user must be 65532:65532" compose runner 2 replace '^    user:' '    user: "0:0"'
mutate "writable root" "read_only must be true" compose runner 2 replace '^    read_only:' '    read_only: false'
mutate "no tmpfs" "tmpfs must include /tmp" compose runner 2 dropkey '^    tmpfs:'
mutate "no no-new-privileges" "security_opt must contain no-new-privileges:true" compose runner 2 dropkey '^    security_opt:'
mutate "mem_limit changed" "mem_limit must be 48m" compose runner 2 replace '^    mem_limit:' '    mem_limit: 512m'
mutate "restart policy removed" "restart must be unless-stopped" compose runner 2 delete '^    restart:'
mutate "pull_policy removed" "pull_policy must be never" compose runner 2 delete '^    pull_policy:'
mutate "floating image tag" "image 'platform-jobs-runner:latest'" compose runner 2 replace '^    image:' '    image: platform-jobs-runner:latest'
mutate "container_name changed" "container_name must be platform-jobs-runner" compose runner 2 replace '^    container_name:' '    container_name: runner'
mutate "healthcheck removed" "healthcheck must be CMD /runner healthcheck" compose runner 2 dropkey '^    healthcheck:'
mutate "healthcheck interval changed" "healthcheck interval must be 30s" compose runner 2 replace '^      interval:' '      interval: 5s'
mutate "healthcheck timeout changed" "healthcheck timeout must be 5s" compose runner 2 replace '^      timeout:' '      timeout: 60s'
mutate "healthcheck retries changed" "healthcheck retries must be 3" compose runner 2 replace '^      retries:' '      retries: 30'
mutate "healthcheck start_period changed" "healthcheck start_period must be 30s" compose runner 2 replace '^      start_period:' '      start_period: 1s'
mutate "stop_grace_period removed" "stop_grace_period must be 65m" compose runner 2 delete '^    stop_grace_period:'
mutate "stop_grace_period shortened" "stop_grace_period must be 65m" compose runner 2 replace '^    stop_grace_period:' '    stop_grace_period: 10s'
mutate "a writable jobs.env mount" "/etc/platform/jobs.env must be mounted read-only" compose runner 2 sub 'jobs\.env:ro$' 'jobs.env'
mutate "a writable password mount" "/etc/platform/jobs-redis.password must be mounted read-only" compose runner 2 sub 'jobs-redis\.password:ro$' 'jobs-redis.password'
mutate "network ipv6 enabled" "enable_ipv6 is not allowed" compose - - after '^    external: true' '    enable_ipv6: true'
mutate "network ipam" "ipam is not allowed" compose - - after '^    external: true' '    ipam:\n      driver: default'
mutate "a third service" "service set is not exactly" compose - - before '^networks:' '  extra:\n    image: docker.io/library/busybox:1.37.0\n'
mutate "compose leaves the YAML subset" "outside the YAML subset" compose runner 2 replace '^    cap_drop:' '    cap_drop: [ALL]'

# ---- mutation cases: Dockerfile and Dockerfile.testapp ----

mutate "non-digest base image" "base image is not a pinned" dockerfile - - sub '@sha256:[0-9a-f]+' ''
mutate "non-digest final image" "base image is not a pinned" dockerfile - - sub 'nonroot@sha256:[0-9a-f]+' 'nonroot'
mutate "floating builder tag" "base image is not a pinned" dockerfile - - sub 'golang:[0-9.]+@' 'golang:latest@'
mutate "builder tag differs from GO_VERSION" "differs from GO_VERSION" dockerfile - - sub 'golang:[0-9.]+@' 'golang:1.25.0@'
mutate "GO_VERSION bumped without the Dockerfile" "differs from GO_VERSION" goversion - - replace '.' '1.27.0'
mutate "final image not distroless" "base image is not a pinned" dockerfile - - sub 'gcr\.io/distroless/static-debian12:nonroot' 'docker.io/library/alpine:3.20'
mutate "runner root user" "USER must be 65532:65532" dockerfile - - replace '^USER ' 'USER 0:0'
mutate "runner without CGO_ENABLED=0" "CGO_ENABLED=0 is required" dockerfile - - sub 'CGO_ENABLED=0' 'CGO_ENABLED=1'
mutate "runner without -trimpath" "-trimpath is required" dockerfile - - sub '-trimpath' '-v'
mutate "runner without the version arg" "ARG VERSION is required" dockerfile - - delete '^ARG VERSION'
mutate "runner copies the whole context" "COPY must name files, not the directory" dockerfile - - after '^COPY go.mod' 'COPY . .'
mutate "runner copies testapp" "must not name testapp" dockerfile - - after '^COPY go.mod' 'COPY testapp/testapp_main.go ./testapp/'
mutate "runner COPY names a missing file" "does not exist" dockerfile - - after '^COPY go.mod' 'COPY internal/nonexistent.go ./internal/'
mutate "testapp non-digest base image" "Dockerfile.testapp: base image is not a pinned" testapp - - sub '@sha256:[0-9a-f]+' ''
mutate "testapp builder tag differs from GO_VERSION" "Dockerfile.testapp: builder golang:1.25.0 differs" testapp - - sub 'golang:[0-9.]+@' 'golang:1.25.0@'
mutate "testapp final image not distroless" "Dockerfile.testapp: base image is not a pinned" testapp - - sub 'gcr\.io/distroless/static-debian12:nonroot' 'docker.io/library/alpine:3.20'
mutate "testapp COPY names a missing file" "Dockerfile.testapp: COPY source 'testapp/missing.go' does not exist" testapp - - after '^COPY go.mod' 'COPY testapp/missing.go ./testapp/'
mutate "testapp root user" "Dockerfile.testapp: USER must be 65532:65532" testapp - - replace '^USER ' 'USER 0:0'

t_finish
