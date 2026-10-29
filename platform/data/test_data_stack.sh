#!/usr/bin/env bash
# Static checks for the data stack (compose.yaml, pg_hba.conf, redis-entrypoint.sh, README.md). Offline and fast: no
# docker. Each security property has a mutation case: a mutated copy of the stack must fail with a named reason, and
# the unmutated tree must pass.
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

services="postgres redis"

# Postgres data path per pinned major. A pinned major that is not in this table fails the test, so a pin bump forces
# a conscious update (the image layout changed in 18: PGDATA moved under /var/lib/postgresql/<major>/docker).
declare -A pg_path=(
  [14]=/var/lib/postgresql/data
  [15]=/var/lib/postgresql/data
  [16]=/var/lib/postgresql/data
  [17]=/var/lib/postgresql/data
  [18]=/var/lib/postgresql
)

# Postgres -c settings that must be present with exactly this value (max_connections and shared_buffers have their
# own range checks).
declare -A pg_want=(
  [hba_file]=/etc/postgresql/pg_hba.conf
  [log_statement]=none
  [log_min_error_statement]=panic
  [effective_cache_size]=512MB
  [work_mem]=4MB
  [maintenance_work_mem]=48MB
  [huge_pages]=off
  [wal_compression]=on
  [max_parallel_workers_per_gather]=0
  [hash_mem_multiplier]=1
)
pg_ranged=" max_connections shared_buffers "

# Explicit exclusions for the hostname shape (a dotted name whose last label is letters only).
host_registry="docker.io"
host_label="platform.app"
host_files=" README.md lib.sh yaml-subset.sh install-data.sh install-jobs.sh redis-entrypoint.sh test_data_stack.sh test_redis_entrypoint.sh "
host_files="$host_files data-live.txt test_traefik_dynamic.sh 127.x State.OOMKilled postgres.public com.docker.compose.project platform.sh test_data_live.sh memory.current memory.stat memory.peak memory.max memory.events pg.log fill.txt up.txt up2.txt up3.txt pull-err compose.reversed postgres-admin.password redis-admin.password "
host_files="$host_files new-db.sh test_new_db.sh reserved-names.txt logger.log stdin.log APP.lock myapp.lock other.lock docker.real c1.out c2.out State.Status State.Health State.Health.Status users.acl.tmp postgres-admin.password redis-admin.password Config.Env "
host_exts=" yml yaml env acl conf "

hostname_ok() {
  local t="$1" last="${1##*.}"
  [[ "$last" =~ ^[A-Za-z]+$ ]] || return 0
  [ "$t" = "$host_registry" ] && return 0
  [ "$t" = "$host_label" ] && return 0
  [[ "$host_files" == *" $t "* ]] && return 0
  [[ "$host_exts" == *" $last "* ]] && return 0
  return 1
}

# scan_file <file>: print the shape name for each kind of secret-shaped value found.
scan_file() {
  local f="$1" content t ln
  content="$(sed -E 's/sha256:[0-9a-f]{64}/sha256:DIGEST/g' "$f")"
  grep -qE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' <<<"$content" && echo "email shape"
  grep -qE '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}' <<<"$content" && echo "UUID shape"
  grep -qE 'eyJ[A-Za-z0-9_-]{3,}' <<<"$content" && echo "eyJ token prefix"
  grep -qE '[0-9a-fA-F]{32,}' <<<"$content" && echo "32+ hex run"
  while IFS=: read -r ln t; do
    hostname_ok "$t" || echo "hostname shape (not allow-listed) at line $ln"
  done < <(grep -noE '[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+' <<<"$content")
}

# to_mb <size>: 96mb, 192m, 1g -> whole megabytes (empty when not understood).
to_mb() {
  if [[ "$1" =~ ^([0-9]+)([mM][bB]?)$ ]]; then echo "${BASH_REMATCH[1]}"
  elif [[ "$1" =~ ^([0-9]+)([gG][bB]?)$ ]]; then echo $((BASH_REMATCH[1] * 1024))
  fi
}

# arg_after <flat> <service> <flag>: the command item after the flag.
arg_after() {
  ys_list "$1" "services/$2/command" | awk -v f="$3" 'p == 1 { print; exit } $0 == f { p = 1 }'
}

REASONS=()
r() { REASONS+=("$*"); }

# run_checks <stack-dir>: fill REASONS (empty means the stack passes).
run_checks() {
  local dir="$1" cf s k v got got_nets tag major want_path mnt hba readme entry f
  REASONS=()
  cf="$T_TMP/c-flat"
  local err
  err="$(ys_flatten < "$dir/compose.yaml" 2>&1 > "$cf")" || { r "compose.yaml is outside the YAML subset the test understands: $err"; : > "$cf"; }

  # -- service set
  got="$(ys_children "$cf" services | sort | tr '\n' ' ')"
  [ "$got" = "$services " ] || r "service set is not exactly: $services (got: $got)"

  # -- per service: pinned image, no published ports or privilege, hardening
  for s in $services; do
    [[ " $got " == *" $s "* ]] || continue
    v="$(ys_get "$cf" "services/$s/image")"
    if ! [[ "$v" =~ ^docker\.io/library/$s:[0-9]+\.[0-9]+(\.[0-9]+)?@sha256:[0-9a-f]{64}$ ]]; then
      r "$s: image '$v' is not fully qualified with an exact version tag and a sha256 digest (floating, unpinned or a variant suffix tag)"
    fi
    [ "$(ys_get "$cf" "services/$s/container_name")" = "platform-data-$s" ] || r "$s: container_name must be platform-data-$s"
    for k in ports privileged network_mode cap_add; do
      ys_has "$cf" "services/$s/$k" && r "$s: $k is not allowed"
    done
    ys_list "$cf" "services/$s/cap_drop" | grep -qxF ALL || r "$s: cap_drop must contain ALL"
    [ -n "$(ys_get "$cf" "services/$s/mem_limit")" ] || r "$s: mem_limit must be set"
    [ "$(ys_get "$cf" "services/$s/restart")" = unless-stopped ] || r "$s: restart must be unless-stopped"
    ys_list "$cf" "services/$s/security_opt" | grep -qxF no-new-privileges:true || r "$s: security_opt must contain no-new-privileges:true"
    [ "$(ys_get "$cf" "services/$s/read_only")" = true ] || r "$s: read_only must be true"
    ys_list "$cf" "services/$s/tmpfs" | grep -qxF /tmp || r "$s: tmpfs must include /tmp (read-only root)"
    if [ "$s" = postgres ]; then
      ys_list "$cf" "services/$s/tmpfs" | grep -qxF /var/run/postgresql || r "$s: tmpfs must include /var/run/postgresql (read-only root, socket directory)"
    fi
    ys_list "$cf" "services/$s/healthcheck/test" | grep -q . || r "$s: a healthcheck is required"
    [[ "$(ys_get "$cf" "services/$s/user")" =~ ^[1-9][0-9]*:[0-9]+$ ]] || r "$s: user must be a fixed non-root uid:gid"
    ys_list "$cf" "services/$s/group_add" | grep -qxF 64322 || r "$s: group_add must hold the admin-secret gid 64322"
    if grep -F "services/$s/labels" "$cf" | grep -qF 'platform.app'; then
      r "$s: carries a platform.app label (no service in the data stack may)"
    fi
    got_nets="$(ys_list "$cf" "services/$s/networks" | sort | tr '\n' ' ')"
    [ "$got_nets" = "platform " ] || r "$s: networks are '$got_nets', want only 'platform '"

    # -- no secret anywhere in the environment (names) or in command/healthcheck arguments
    while IFS= read -r k; do
      v="${k^^}"
      if [[ "$v" =~ (PASSWORD|AUTH|SECRET|TOKEN) && "$v" != *_FILE ]]; then r "$s: a secret in the environment ($k): secrets are mounted files"; fi
    done < <(ys_children "$cf" "services/$s/environment")
    while IFS= read -r v; do
      [[ "$v" =~ ^(-a|--pass|--requirepass|--masterauth)($|=) ]] && r "$s: a password flag in command ($v)"
    done < <(ys_list "$cf" "services/$s/command")
    if ys_list "$cf" "services/$s/command" | grep -qiE 'password|requirepass'; then r "$s: a password literal in command"; fi
    if awk -F '\t' -v pre="services/$s/environment/" 'index($1, pre) == 1 && $2 ~ /eyJ/ { f = 1 } END { exit f ? 0 : 1 }' "$cf"; then r "$s: an inline token in the environment"; fi
  done

  # -- networks
  [ "$(ys_get "$cf" networks/platform/external)" = true ] || r "network platform must be external: true"
  [ "$(ys_children "$cf" networks | sort | tr '\n' ' ')" = "platform " ] || r "unexpected network set (only platform)"
  for k in ipam enable_ipv6 driver_opts; do
    ys_has "$cf" "networks/platform/$k" && r "networks: $k is not allowed (no subnet or address literals, IPv6 off)"
  done

  # -- volumes: both named, with an explicit name equal to the key
  [ "$(ys_children "$cf" volumes | sort | tr '\n' ' ')" = "platform-data-postgres platform-data-redis " ] || r "named volume set is not exactly platform-data-postgres and platform-data-redis"
  for k in platform-data-postgres platform-data-redis; do
    [ "$(ys_get "$cf" "volumes/$k/name")" = "$k" ] || r "volume $k must carry an explicit name: $k"
  done
  ys_list "$cf" services/redis/volumes | grep -qxF 'platform-data-redis:/data' || r "redis must mount the named volume platform-data-redis at /data"
  ys_list "$cf" services/redis/volumes | grep -qE '^/etc/platform/redis-admin\.password:[^:]+:ro$' || r "redis must mount the admin password file read-only"
  ys_list "$cf" services/postgres/volumes | grep -qE '^/etc/platform/postgres-admin\.password:[^:]+:ro$' || r "postgres must mount the admin password file read-only"
  [ "$(ys_get "$cf" services/postgres/environment/POSTGRES_PASSWORD_FILE)" = /etc/platform/postgres-admin.password ] || r "postgres must read its password from POSTGRES_PASSWORD_FILE"
  [ "$(ys_children "$cf" services/postgres/environment | tr '\n' ' ')" = "POSTGRES_PASSWORD_FILE " ] || r "postgres environment must be exactly POSTGRES_PASSWORD_FILE"

  # -- postgres: pinned major and its data path
  tag="$(ys_get "$cf" services/postgres/image | sed -E 's/^[^:]*:([^@]*)@.*$/\1/')"
  major="${tag%%.*}"
  if [ -z "$major" ] || [ -z "${pg_path[$major]+x}" ]; then
    r "postgres major '$major' is not in the major-to-path table (update the table after checking the image's documented data path)"
  else
    want_path="${pg_path[$major]}"
    mnt="$(ys_list "$cf" services/postgres/volumes | grep -E '^platform-data-postgres:' | head -n 1)"
    [ "$mnt" = "platform-data-postgres:$want_path" ] || r "postgres volume must be platform-data-postgres:$want_path for major $major (got '${mnt:-none}'): a wrong path silently writes to an anonymous volume"
  fi

  # -- postgres tuning (-c settings)
  local -A seen=()
  local item key val idx=0 want_val=0
  while IFS= read -r item; do
    idx=$((idx + 1))
    if [ "$want_val" = 1 ]; then
      want_val=0
      key="${item%%=*}"
      val="${item#*=}"
      [ -z "${seen[$key]+x}" ] || r "postgres setting $key is given twice (last wins)"
      seen[$key]="$val"
    elif [ "$item" = "-c" ]; then
      want_val=1
    elif [ "$idx" -eq 1 ] && [ "$item" = postgres ]; then
      :
    else
      r "postgres: unexpected command item '$item' (only postgres and -c <setting> pairs)"
    fi
  done < <(ys_list "$cf" services/postgres/command)
  [ "$want_val" = 0 ] || r "postgres: a trailing -c has no setting"
  ys_list "$cf" services/postgres/command | head -n 1 | grep -qxF postgres || r "postgres command must start with postgres"
  for k in "${!pg_want[@]}"; do
    if [ -z "${seen[$k]+x}" ]; then r "postgres setting $k is missing"
    elif [ "${seen[$k]}" != "${pg_want[$k]}" ]; then r "postgres setting $k is '${seen[$k]}', want '${pg_want[$k]}'"
    fi
  done
  for k in "${!seen[@]}"; do
    [ -n "${pg_want[$k]+x}" ] || [[ "$pg_ranged" == *" $k "* ]] || [ "$k" = synchronous_commit ] || r "postgres: unexpected setting $k"
  done
  [ -z "${seen[synchronous_commit]+x}" ] || [ "${seen[synchronous_commit]}" = on ] || r "postgres synchronous_commit must stay on"
  v="$(to_mb "${seen[shared_buffers]:-}")"
  { [ -n "$v" ] && [ "$v" -ge 128 ] && [ "$v" -le 192 ]; } || r "postgres shared_buffers must be 128-192MB (got '${seen[shared_buffers]:-unset}')"
  v="${seen[max_connections]:-}"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    [ "$v" -ge $((3 * 15 + 10)) ] || r "postgres max_connections $v is below 3 x 15 + 10 reserved headroom"
  else
    r "postgres max_connections is missing or not a number"
  fi
  [ "$(ys_get "$cf" services/postgres/shm_size)" = 128m ] || r "postgres shm_size must be 128m"
  [ "$(ys_get "$cf" services/postgres/mem_limit)" = 512m ] || r "postgres mem_limit must be 512m"
  ys_list "$cf" services/postgres/healthcheck/test | tr '\n' ' ' | grep -qxF 'CMD pg_isready -U postgres ' || r "postgres healthcheck must be: pg_isready -U postgres"
  ys_list "$cf" services/postgres/volumes | grep -qxF '/opt/platform/data/pg_hba.conf:/etc/postgresql/pg_hba.conf:ro' || r "postgres must mount pg_hba.conf read-only at the hba_file path"

  # -- pg_hba.conf: exactly one local line (peer for postgres), scram-sha-256 only on host lines, no trust
  hba="$dir/pg_hba.conf"
  if [ ! -s "$hba" ]; then
    r "pg_hba.conf is missing"
  else
    local locals
    locals="$(grep -E '^[[:space:]]*local([[:space:]]|$)' "$hba" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
    [ "$(grep -cE '^[[:space:]]*local([[:space:]]|$)' "$hba")" = 1 ] || r "pg_hba.conf must have exactly one local line (got: $(grep -cE '^[[:space:]]*local([[:space:]]|$)' "$hba"))"
    grep -qxF 'local all postgres peer' <<<"$locals" || r "pg_hba.conf must contain exactly the line: local all postgres peer"
    grep -qiE 'trust' "$hba" && r "pg_hba.conf must not contain trust anywhere"
    local line cnt=0 first_host=1 norm
    while IFS= read -r line; do
      norm="$(sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' <<<"$line")"
      if [ "$first_host" = 1 ]; then
        first_host=0
        [ "$norm" = "host all postgres samenet reject" ] || r "pg_hba.conf first host line must be exactly: host all postgres samenet reject"
        continue
      fi
      cnt=$((cnt + 1))
      read -ra f <<<"$line"
      { [ "${#f[@]}" -eq 5 ] && [ "${f[0]}" = host ] && [ "${f[3]}" = samenet ]; } || r "pg_hba.conf host line must be exactly 'host <database> <user> samenet <method>': $line"
      [ "${f[4]:-}" = scram-sha-256 ] || r "pg_hba.conf host line must use scram-sha-256: $line"
    done < <(grep -E '^[[:space:]]*host' "$hba")
    [ "$cnt" -ge 1 ] || r "pg_hba.conf has no host line"
    if grep -vE '^[[:space:]]*(#|$)' "$hba" | grep -vE '^[[:space:]]*(local|host)[[:space:]]' | grep -q .; then r "pg_hba.conf has a line other than local or host"; fi
  fi

  # -- redis: exactly the five expected flags, each once, each with a value (last wins, so extras are refused)
  local -A rseen=()
  local rflag=""
  while IFS= read -r item; do
    if [ -z "$rflag" ]; then
      [[ " --maxmemory --maxmemory-policy --appendonly --appendfsync --aclfile --proto-max-bulk-len " == *" $item "* ]] || r "redis: unexpected command flag '$item'"
      [ -z "${rseen[$item]+x}" ] || r "redis flag $item is given twice (last wins)"
      rseen[$item]=1
      rflag="$item"
    else
      rflag=""
    fi
  done < <(ys_list "$cf" services/redis/command)
  [ -z "$rflag" ] || r "redis flag $rflag has no value"
  [ "$(arg_after "$cf" redis --maxmemory)" = 96mb ] || r "redis maxmemory must be 96mb"
  [ "$(arg_after "$cf" redis --maxmemory-policy)" = noeviction ] || r "redis maxmemory-policy must be noeviction (queued jobs must never be evicted)"
  [ "$(arg_after "$cf" redis --appendonly)" = yes ] || r "redis appendonly must be yes (AOF)"
  [ "$(arg_after "$cf" redis --appendfsync)" = everysec ] || r "redis appendfsync must be everysec"
  [ "$(arg_after "$cf" redis --aclfile)" = /data/users.acl ] || r "redis aclfile must be /data/users.acl"
  [ "$(arg_after "$cf" redis --proto-max-bulk-len)" = 1mb ] || r "redis proto-max-bulk-len must be 1mb (no single value over 1 MB, for every client)"
  local mm lim
  mm="$(to_mb "$(arg_after "$cf" redis --maxmemory)")"
  lim="$(to_mb "$(ys_get "$cf" services/redis/mem_limit)")"
  if [ -n "$mm" ] && [ -n "$lim" ]; then
    [ "$lim" -ge $((2 * mm)) ] || r "redis mem_limit ${lim}m is below 2 x maxmemory ${mm}m (AOF rewrite buffer and copy-on-write are not counted by maxmemory)"
  else
    r "redis mem_limit or maxmemory is missing or not understood"
  fi
  ys_has "$cf" services/redis/environment && r "redis must have no environment"
  [ "$(ys_list "$cf" services/redis/entrypoint | tr '\n' ' ')" = "/usr/local/bin/redis-entrypoint.sh " ] || r "redis entrypoint must be /usr/local/bin/redis-entrypoint.sh"
  ys_list "$cf" services/redis/volumes | grep -qxF '/opt/platform/data/redis-entrypoint.sh:/usr/local/bin/redis-entrypoint.sh:ro' || r "redis entrypoint payload must be mounted read-only"
  local hc
  hc="$(ys_list "$cf" services/redis/healthcheck/test | tr '\n' ' ')"
  [ "$hc" = "CMD redis-cli --user health --pass placeholder --no-auth-warning ping " ] \
    || r "redis healthcheck must use the health user with exactly the placeholder password (got: $hc)"
  [[ " $hc " == *" -a "* ]] && r "redis healthcheck must not use -a"

  # -- redis entrypoint payload
  entry="$dir/redis-entrypoint.sh"
  [ -s "$entry" ] || r "redis-entrypoint.sh is missing"
  [ -x "$entry" ] || r "redis-entrypoint.sh must be executable"
  grep -qxF 'exec redis-server "$@"' "$entry" 2>/dev/null || r "redis-entrypoint.sh must exec redis-server with its arguments"

  # -- README: the documented contract
  readme="$dir/README.md"
  if [ ! -s "$readme" ]; then
    r "README.md is missing"
  else
    for k in noeviction 'no per-app quota' 'WARN' 'SCAN' 'RANDOMKEY' 'DBSIZE' connection.env PLATFORM_PG_HOST PLATFORM_PG_PORT PLATFORM_REDIS_HOST PLATFORM_REDIS_PORT \
      DB_PASSWORD_FILE REDIS_KEY_PREFIX '/var/lib/platform/secrets/<app>' 'group_add: ["64323"]' 'vm.overcommit_memory=1' PgBouncer JOBS_SECRET_FILE '## Job secrets' '## Reserved key namespace' '## Value size limit' '--proto-max-bulk-len 1mb'; do
      grep -qF -- "$k" "$readme" || r "README.md lacks: $k"
    done
  fi

  # -- no-secrets scan over everything under the data dir
  local shape
  while IFS= read -r -d '' f; do
    while IFS= read -r shape; do
      [ -n "$shape" ] && r "no-secrets scan: $shape in ${f#"$dir"/}"
    done < <(scan_file "$f")
  done < <(find "$dir" -type f -print0)
}

# ---- mutation helpers (awk, with patterns passed through the environment) ----
# Scope: M_SVC limits a helper to one block whose header line is "<M_SVC>:" at indent M_IND (default 2).

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
# file: compose, hba, readme or entry (redis-entrypoint.sh). mode chmod: the regex is a chmod mode (a-x) and no edit runs.
# With MUT_ABSENT=1 set for one call, the case passes only when NO reason contains the substring (a boundary that must stay valid).
mutate() {
  local label="$1" wantr="$2" which="$3" svc="$4" ind="$5" mode="$6" re="$7" text="${8:-}" dir target hit r_ changed=0 mode_before
  mutn=$((mutn + 1))
  dir="$T_TMP/mut-$mutn"
  cp -R "$here" "$dir"
  case "$which" in
    compose) target="$dir/compose.yaml" ;;
    hba) target="$dir/pg_hba.conf" ;;
    readme) target="$dir/README.md" ;;
    entry) target="$dir/redis-entrypoint.sh" ;;
  esac
  cp "$target" "$T_TMP/before-mut"
  M_SVC=; M_IND=2
  [ "$svc" = - ] || M_SVC="$svc"
  [ "$ind" = - ] || M_IND="$ind"
  export M_SVC M_IND
  if [ "$mode" = chmod ]; then
    mode_before="$(stat -c %a "$target")"
    chmod "$re" "$target"
    [ "$mode_before" != "$(stat -c %a "$target")" ] && changed=1
  else
    m_edit "$target" "$mode" "$re" "$text"
    cmp -s "$T_TMP/before-mut" "$target" || changed=1
  fi
  unset M_SVC M_IND
  if [ "$changed" = 0 ]; then
    _fail "mutation '$label' did not change the file" "regex: $re"
    MUT_ABSENT=0
    return
  fi
  run_checks "$dir"
  hit=0
  for r_ in "${REASONS[@]}"; do [[ "$r_" == *"$wantr"* ]] && hit=1; done
  if [ "${MUT_ABSENT:-0}" = 1 ]; then
    if [ "$hit" = 0 ]; then _pass; else _fail "boundary '$label' must not fail with a reason containing '$wantr'" "got: ${REASONS[*]}"; fi
  elif [ "$hit" = 1 ]; then _pass; else _fail "mutation '$label' was not caught with a reason containing '$wantr'" "got: ${REASONS[*]:-no failure at all}"; fi
  MUT_ABSENT=0
}

# plant <label> <expected shape> <value-assembled-at-run-time>: append the value to the README and scan.
plant() {
  local label="$1" wantr="$2" value="$3" dir hit=0 r_
  mutn=$((mutn + 1))
  dir="$T_TMP/mut-$mutn"
  cp -R "$here" "$dir"
  printf '\n%s\n' "$value" >> "$dir/README.md"
  run_checks "$dir"
  for r_ in "${REASONS[@]}"; do [[ "$r_" == *"$wantr"* ]] && hit=1; done
  if [ "$hit" = 1 ]; then _pass; else _fail "planted $label was not caught with '$wantr'" "got: ${REASONS[*]:-no failure at all}"; fi
}

# ---- unmutated tree passes ----

run_checks "$here"
if [ "${#REASONS[@]}" -eq 0 ]; then _pass; else
  _fail "the unmutated data stack must pass every check"
  printf '  reason: %s\n' "${REASONS[@]}"
fi

# ---- mutation cases: compose.yaml, both services ----

mutate "published port" "ports is not allowed" compose postgres 2 after '^  postgres:' '    ports:\n      - "5432:5432"'
mutate "published redis port" "ports is not allowed" compose redis 2 after '^  redis:' '    ports:\n      - "6379:6379"'
mutate "privileged" "privileged is not allowed" compose redis 2 after '^  redis:' '    privileged: true'
mutate "network_mode host" "network_mode is not allowed" compose postgres 2 after '^  postgres:' '    network_mode: host'
mutate "cap_add" "cap_add is not allowed" compose redis 2 after '^  redis:' '    cap_add:\n      - NET_ADMIN'
mutate "a third service" "service set is not exactly" compose - - before '^volumes:' '  extra:\n    image: docker.io/library/busybox:1.37.0\n'
mutate "platform.app label" "platform.app label" compose redis 2 after '^  redis:' '    labels:\n      platform.app: redis'
mutate "tag without digest" "not fully qualified" compose postgres 2 sub '@sha256:[0-9a-f]+' ''
mutate "floating image tag" "not fully qualified" compose redis 2 replace '^    image:' '    image: docker.io/library/redis:latest'
mutate "variant suffix tag" "variant suffix" compose redis 2 sub ':8\.10\.2@' ':8.10.2-alpine@'
mutate "unqualified image" "not fully qualified" compose redis 2 sub 'docker\.io/library/' ''
mutate "container_name changed" "container_name must be platform-data-postgres" compose postgres 2 replace '^    container_name:' '    container_name: postgres'
mutate "container_name removed" "container_name must be platform-data-redis" compose redis 2 delete '^    container_name:'
mutate "extra network" "networks are" compose redis 2 after '^      - platform$' '      - other'
mutate "extra network declared" "unexpected network set" compose - - after '^    external: true' '  other:\n    internal: true'
mutate "platform network not external" "platform must be external" compose - - replace '^    external: true' '    external: false'
mutate "ipam on the platform network" "ipam is not allowed" compose platform 2 after '^  platform:' '    ipam: x'
mutate "ipv6 on the platform network" "enable_ipv6 is not allowed" compose platform 2 after '^  platform:' '    enable_ipv6: true'
mutate "driver_opts on the platform network" "driver_opts is not allowed" compose platform 2 after '^  platform:' '    driver_opts: x'
mutate "root user" "fixed non-root" compose postgres 2 replace '^    user:' '    user: "0:0"'
mutate "no admin-secret group" "group_add must hold" compose redis 2 dropkey '^    group_add:'
mutate "writable root" "read_only must be true" compose postgres 2 replace '^    read_only:' '    read_only: false'
mutate "no tmpfs for redis" "tmpfs must include /tmp" compose redis 2 dropkey '^    tmpfs:'
mutate "compose leaves the YAML subset" "outside the YAML subset" compose redis 2 replace '^    cap_drop:' '    cap_drop: [ALL]'

for svc in postgres redis; do
  mutate "$svc without cap_drop" "$svc: cap_drop must contain ALL" compose "$svc" 2 dropkey '^    cap_drop:'
  mutate "$svc without mem_limit" "$svc: mem_limit must be set" compose "$svc" 2 delete '^    mem_limit:'
  mutate "$svc without restart policy" "$svc: restart must be unless-stopped" compose "$svc" 2 delete '^    restart:'
  mutate "$svc without no-new-privileges" "$svc: security_opt must contain no-new-privileges:true" compose "$svc" 2 dropkey '^    security_opt:'
  mutate "$svc without healthcheck" "$svc: a healthcheck is required" compose "$svc" 2 dropkey '^    healthcheck:'
done

# ---- mutation cases: secrets ----

mutate "postgres password in env" "a secret in the environment (POSTGRES_PASSWORD)" compose postgres 2 after '^    environment:' '      POSTGRES_PASSWORD: hunter2'
mutate "redis auth in env" "a secret in the environment (REDISCLI_AUTH)" compose redis 2 after '^    container_name:' '    environment:\n      REDISCLI_AUTH: hunter2'
mutate "redis requirepass flag" "a password flag in command" compose redis 2 after '^      - --appendonly' '      - --requirepass=hunter2'
mutate "postgres command item containing the word password" "a password literal in command" compose postgres 2 after '^      - postgres$' '      - -c\n      - password_encryption=md5'
mutate "postgres env with a lowercase secret name" "a secret in the environment (postgres_password)" compose postgres 2 after '^    environment:' '      postgres_password: hunter2'
mutate "postgres env with an unrelated key" "postgres environment must be exactly" compose postgres 2 after '^    environment:' '      DATABASE_URL: x'
mutate "postgres env with a _FILE-suffixed extra key" "postgres environment must be exactly" compose postgres 2 after '^    environment:' '      POSTGRES_PASSWORD_FILE_X: x'
mutate "postgres runs the redis image" "image" compose postgres 2 replace '^    image:' '    image: docker.io/library/redis:8.10.2@sha256:5c02d7c0f8d75af45958c0294a8004f2e14b42df98a1103e3a669aa7ec787be6'
mutate "postgres without the socket tmpfs" "tmpfs must include /var/run/postgresql" compose postgres 2 delete '^      - /var/run/postgresql'
mutate "env secret as a token" "inline token" compose postgres 2 after '^    environment:' "      POSTGRES_PASSWORD_FILE_X: $(printf '%s%s' ey JhbGciOi)"

# ---- mutation cases: volumes and the pinned major ----

mutate "postgres volume name key removed" "must carry an explicit name" compose platform-data-postgres 2 delete '^    name:'
mutate "redis volume name key removed" "must carry an explicit name" compose platform-data-redis 2 delete '^    name:'
mutate "redis volume not named" "redis must mount the named volume" compose redis 2 replace '^      - platform-data-redis:/data' '      - /data'
mutate "postgres volume at the wrong path" "postgres volume must be platform-data-postgres:/var/lib/postgresql" compose postgres 2 replace '^      - platform-data-postgres:' '      - platform-data-postgres:/var/lib/postgresql/data'
mutate "postgres major 17 with the 18 path" "for major 17" compose postgres 2 sub ':18\.6@' ':17.6@'
mutate "postgres major missing from the table" "not in the major-to-path table" compose postgres 2 sub ':18\.6@' ':19.0@'

# ---- mutation cases: postgres tuning ----

mutate "log_statement not none" "postgres setting log_statement is 'all'" compose postgres 2 replace '^      - log_statement=none' '      - log_statement=all'
mutate "log_min_error_statement not panic" "log_min_error_statement is 'error'" compose postgres 2 replace '^      - log_min_error_statement=panic' '      - log_min_error_statement=error'
mutate "log_min_error_statement removed" "log_min_error_statement is missing" compose postgres 2 delete '^      - log_min_error_statement=panic'
mutate "hash_mem_multiplier removed" "hash_mem_multiplier is missing" compose postgres 2 delete '^      - hash_mem_multiplier=1'
mutate "hash_mem_multiplier changed to 2" "hash_mem_multiplier is '2'" compose postgres 2 replace '^      - hash_mem_multiplier=1' '      - hash_mem_multiplier=2'
mutate "max_connections below the headroom" "max_connections 54 is below" compose postgres 2 replace '^      - max_connections=60' '      - max_connections=54'
MUT_ABSENT=1 mutate "max_connections exactly at the headroom (3 x 15 + 10) is valid" "max_connections" compose postgres 2 replace '^      - max_connections=60' '      - max_connections=55'
MUT_ABSENT=1 mutate "shared_buffers at the upper bound is valid" "shared_buffers" compose postgres 2 replace '^      - shared_buffers=128MB' '      - shared_buffers=192MB'
mutate "shared_buffers just below the lower bound" "shared_buffers must be 128-192MB" compose postgres 2 replace '^      - shared_buffers=128MB' '      - shared_buffers=127MB'
mutate "a long option appended after the real settings" "unexpected command item '--log_statement=all'" compose postgres 2 after '^      - max_parallel_workers_per_gather=0' '      - --log_statement=all'
mutate "a glued -c option appended" "unexpected command item '-clog_statement=all'" compose postgres 2 after '^      - max_parallel_workers_per_gather=0' '      - -clog_statement=all'
mutate "a duplicated postgres setting (last wins)" "log_statement is given twice" compose postgres 2 after '^      - max_parallel_workers_per_gather=0' '      - -c\n      - log_statement=all'
mutate "shared_buffers too large" "shared_buffers must be 128-192MB" compose postgres 2 replace '^      - shared_buffers=128MB' '      - shared_buffers=1GB'
mutate "huge_pages on" "huge_pages is 'on'" compose postgres 2 replace '^      - huge_pages=off' '      - huge_pages=on'
mutate "synchronous_commit off" "synchronous_commit must stay on" compose postgres 2 after '^      - postgres$' '      - -c\n      - synchronous_commit=off'
mutate "an unexpected setting" "unexpected setting fsync" compose postgres 2 after '^      - postgres$' '      - -c\n      - fsync=off'
mutate "hba_file pointing elsewhere" "hba_file is" compose postgres 2 replace '^      - hba_file=' '      - hba_file=/tmp/pg_hba.conf'
mutate "shm_size changed" "shm_size must be 128m" compose postgres 2 replace '^    shm_size:' '    shm_size: 64m'
mutate "postgres mem_limit changed" "mem_limit must be 512m" compose postgres 2 replace '^    mem_limit:' '    mem_limit: 1g'
mutate "pg_hba mount not read-only" "pg_hba.conf read-only" compose postgres 2 replace '^      - /opt/platform/data/pg_hba.conf' '      - /opt/platform/data/pg_hba.conf:/etc/postgresql/pg_hba.conf'
mutate "postgres password file mount not read-only" "admin password file read-only" compose postgres 2 replace '^      - /etc/platform/postgres-admin.password' '      - /etc/platform/postgres-admin.password:/etc/platform/postgres-admin.password'

# ---- mutation cases: pg_hba.conf ----

mutate "host line using trust" "must use scram-sha-256" hba - - sub 'scram-sha-256' 'trust'
mutate "host line using md5" "must use scram-sha-256" hba - - sub 'scram-sha-256' 'md5'
mutate "host line with an open address" "samenet <method>" hba - - sub 'samenet' '0.0.0.0/0'
mutate "host line with the address all" "samenet <method>" hba - - sub 'samenet' 'all'
mutate "hostssl line type" "samenet <method>" hba - - sub '^host ' 'hostssl '
mutate "host line with uppercase TRUST" "must not contain trust anywhere" hba - - sub 'scram-sha-256' 'TRUST'
mutate "host line with a trailing option" "samenet <method>" hba - - sub '$' ' clientcert=verify-full'
mutate "trust anywhere in the file" "must not contain trust anywhere" hba - - after '^host all all samenet' '# trust'
mutate "local line removed" "exactly one local line" hba - - delete '^local all postgres peer'
mutate "local line method changed" "exactly the line: local all postgres peer" hba - - replace '^local all postgres peer' 'local all postgres scram-sha-256'
mutate "extra local line" "exactly one local line" hba - - after '^local all postgres peer' 'local all all scram-sha-256'
mutate "extra local trust line" "must not contain trust anywhere" hba - - after '^local all postgres peer' 'local all all trust'
mutate "host lines removed" "has no host line" hba - - delete '^host '
mutate "superuser reject line removed" "first host line must be exactly" hba - - delete '^host all postgres'
mutate "superuser reject line made scram" "first host line must be exactly" hba - - replace '^host all postgres' 'host all postgres samenet scram-sha-256'
mutate "superuser reject line commented out" "first host line must be exactly" hba - - replace '^host all postgres' '#'
mutate "superuser reject line scoped to another user" "first host line must be exactly" hba - - sub 'all postgres' 'all someone'
mutate "an unknown line type" "other than local or host" hba - - after '^local all postgres peer' 'include x'

# ---- mutation cases: redis ----

mutate "eviction policy changed" "maxmemory-policy must be noeviction" compose redis 2 replace '^      - noeviction' '      - allkeys-lru'
mutate "AOF off" "appendonly must be yes" compose redis 2 replace '^      - "yes"' '      - "no"'
mutate "appendfsync changed" "appendfsync must be everysec" compose redis 2 replace '^      - everysec' '      - always'
mutate "aclfile changed" "aclfile must be" compose redis 2 replace '^      - /data/users.acl' '      - /tmp/users.acl'
mutate "maxmemory raised" "redis mem_limit 192m is below 2 x maxmemory 128m" compose redis 2 replace '^      - 96mb' '      - 128mb'
mutate "mem_limit below 2 x maxmemory" "is below 2 x maxmemory" compose redis 2 replace '^    mem_limit:' '    mem_limit: 150m'
mutate "entrypoint mount not read-only" "mounted read-only" compose redis 2 replace '^      - /opt/platform/data/redis-entrypoint.sh' '      - /opt/platform/data/redis-entrypoint.sh:/usr/local/bin/redis-entrypoint.sh'
mutate "entrypoint removed" "redis entrypoint must be" compose redis 2 dropkey '^    entrypoint:'
mutate "redis admin password mount not read-only" "admin password file read-only" compose redis 2 replace '^      - /etc/platform/redis-admin.password' '      - /etc/platform/redis-admin.password:/etc/platform/redis-admin.password'
mutate "healthcheck not the health user" "health user with exactly the placeholder" compose redis 2 replace '^        - health$' '        - admin'
mutate "healthcheck password not the placeholder" "exactly the placeholder" compose redis 2 replace '^        - placeholder$' '        - hunter2'
mutate "healthcheck with -a" "must not use -a" compose redis 2 after '^        - ping' '        - -a'
mutate "healthcheck without --pass" "exactly the placeholder" compose redis 2 delete '^        - --pass'
mutate "redis command -a" "a password flag in command" compose redis 2 after '^      - --appendonly' '      - -a'
mutate "redis unknown flag appended" "unexpected command flag '--protected-mode'" compose redis 2 after '^      - /data/users.acl' '      - --protected-mode\n      - "no"'
mutate "redis duplicated eviction policy" "--maxmemory-policy is given twice" compose redis 2 after '^      - /data/users.acl' '      - --maxmemory-policy\n      - allkeys-lru'
mutate "redis duplicated appendonly" "--appendonly is given twice" compose redis 2 after '^      - /data/users.acl' '      - --appendonly\n      - "no"'
mutate "proto-max-bulk-len flag removed" "redis proto-max-bulk-len must be 1mb" compose redis 2 delete '^      - --proto-max-bulk-len'
mutate "proto-max-bulk-len value changed" "redis proto-max-bulk-len must be 1mb" compose redis 2 replace '^      - 1mb' '      - 512mb'
mutate "redis duplicated proto-max-bulk-len" "--proto-max-bulk-len is given twice" compose redis 2 after '^      - /data/users.acl' '      - --proto-max-bulk-len\n      - 512mb'
mutate "redis flag without a value" "has no value" compose redis 2 after '^      - /data/users.acl' '      - --save'

# ---- mutation cases: README and payload ----

mutate "entrypoint without its exec line" "must exec redis-server with its arguments" entry - - delete '^exec redis-server'
mutate "entrypoint exec drops the arguments" "must exec redis-server with its arguments" entry - - replace '^exec redis-server' 'exec redis-server'
mutate "entrypoint not executable" "redis-entrypoint.sh must be executable" entry - - chmod a-x

mutate "README without the memory note" "README.md lacks: no per-app quota" readme - - sub 'no per-app quota' 'plenty of room'
mutate "README without connection.env" "README.md lacks: PLATFORM_PG_PORT" readme - - sub 'PLATFORM_PG_PORT' 'PORT'
mutate "README without the overcommit note" "README.md lacks: vm.overcommit_memory=1" readme - - sub 'vm.overcommit_memory=1' 'vm tuning'

# ---- no-secrets scan: one planted value per shape (assembled at run time) ----

plant "email" "email shape" "$(printf '%s@%s.%s' someone mail example)"
plant "UUID" "UUID shape" "$(printf '%s-%s-%s-%s-%s' 0123abcd 4567 89ab cdef 0123456789ab)"
plant "eyJ token prefix" "eyJ token prefix" "$(printf '%s%s' ey JhbGciOiJIUzI1NiJ9)"
plant "32+ hex run" "32+ hex run" "$(printf '%s%s%s%s' 0123456789ab cdef0123 456789ab cdef0123)"
plant "hostname" "hostname shape" "$(printf '%s.%s.%s' db corp net)"

t_finish
