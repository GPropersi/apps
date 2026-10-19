#!/usr/bin/env bash
# Table tests for verify-egress.sh. Stubs iptables, docker, sudo, ip, ssh and sleep on PATH; the shared call log
# records every call. Chains are the real `iptables -S` form (the sanitized Pi scratch-chain capture is the
# "real capture" case); CIDRs are documentation ranges assembled from pieces (the hygiene check flags literals).
# SC2016: stub bodies and snippets are single-quoted on purpose. SC1091: lib.sh is sourced by relative path.
# shellcheck disable=SC1091,SC2016
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../test/lib.sh
. "$here/../test/lib.sh"
script="$here/verify-egress.sh"

t_init

DENY="$(t_ip4 198 51 100 0)/24"
DENY2="$(t_ip4 203 0 113 0)/24"
ALLOW="$(t_ip4 192 0 2 0)/24"
OTHER="$(t_ip4 10 77 0 0)/16"
GW="$(t_ip4 198 51 100 1)"
GW_OUTSIDE="$(t_ip4 192 0 2 1)"
LAN="$(t_ip4 192 0 2 50)"
DENY_FILE="$T_TMP/deny"
ALLOW_FILE="$T_TMP/allow"
CHAIN_FILE="$T_TMP/chain.txt"
P="-A DOCKER-USER"

# ---- stubs ----

cat > "$STUB_BIN/iptables" <<'EOF'
#!/usr/bin/env bash
echo "iptables $*" >> "$CALL_LOG"
case "$1" in
  -S)
    if [ -n "${IPT_RC:-}" ]; then echo "iptables: permission denied" >&2; exit "$IPT_RC"; fi
    [ -z "${IPT_WARN:-}" ] || echo "sudo: unable to resolve host somehost" >&2
    [ -z "${IPT_EMPTY:-}" ] || exit 0
    cat "$T_TMP/chain.txt" ;;
  -L)
    n=$(cat "$T_TMP/Lcount" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$T_TMP/Lcount"
    cat "$T_TMP/L$n.txt" ;;
esac
exit 0
EOF
cat > "$STUB_BIN/sudo" <<'EOF'
#!/usr/bin/env bash
echo "sudo $*" >> "$CALL_LOG"
[ "$1" = "-n" ] && shift
exec "$@"
EOF
cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
echo "docker $*" >> "$CALL_LOG"
case "$1" in
  network)
    case "$2" in
      create) exit "${NETCREATE_RC:-0}" ;;
      ls)
        if [ "${LS_RC:-0}" != 0 ]; then echo "ls failed" >&2; exit "$LS_RC"; fi
        printf '%s\n' ${NETS:-aaa bbb}; exit 0 ;;
      inspect)
        if [ "${INSPECT_RC:-0}" != 0 ]; then echo "inspect failed" >&2; exit "$INSPECT_RC"; fi
        if [ "$3" = bridge ]; then echo "${IPV6:-false}"; else echo "${IPV6_NET:-false}"; fi
        exit 0 ;;
      *) exit 0 ;;
    esac ;;
  rm) exit 0 ;;
  port) echo "${PORT_OUT:-}"; exit 0 ;;
  run)
    name=""; prev=""
    for a in "$@"; do
      if [ "$prev" = "--name" ]; then name="$a"; fi
      prev="$a"
    done
    if [ -n "${RUN_FAIL_NAME:-}" ] && [ "$name" = "$RUN_FAIL_NAME" ]; then echo "run failed" >&2; exit 125; fi
    # REAL_SNIPPET=1: run the probe/connect `sh -c <body> <argv0> args...` for real, locally, with only the stub
    # nc/timeout/nslookup on PATH (ABSENT lists tools to leave out), so the in-container classification is tested.
    real=0
    if [ "${REAL_SNIPPET:-}" = 1 ]; then
      case "$name" in platform-verify-egress-probe | platform-verify-egress-a) real=1 ;; esac
    fi
    if [ "$real" = 1 ]; then
      args=("$@"); n=${#args[@]}; i=0
      while [ "$i" -lt "$n" ]; do
        if [ "${args[$i]}" = sh ] && [ "${args[$((i + 1))]}" = -c ]; then break; fi
        i=$((i + 1))
      done
      body="${args[$((i + 2))]}"
      rm -rf "$T_TMP/snip-bin"; mkdir -p "$T_TMP/snip-bin"
      for t in nc timeout nslookup; do
        case " ${ABSENT:-} " in *" $t "*) ;; *) ln -s "$T_TMP/snip-src/$t" "$T_TMP/snip-bin/$t" ;; esac
      done
      PATH="$T_TMP/snip-bin" exec /bin/sh -c "$body" "${args[@]:$((i + 3))}"
    fi
    case "$name" in
      platform-verify-egress-probe) printf '%s\n' "${PROBE_OUT:-}" ;;
      platform-verify-egress-a) echo "RESULT=${CONN_A:-open}" ;;
    esac
    exit 0 ;;
esac
exit 0
EOF
cat > "$STUB_BIN/ip" <<'EOF'
#!/usr/bin/env bash
echo "ip $*" >> "$CALL_LOG"
case "$*" in
  *"route show default"*) [ -z "${GW_ENV:-}" ] || echo "default via $GW_ENV dev eth0 proto dhcp" ;;
  *"route get"*) echo "$GW_ENV dev eth0 src $LAN_ENV uid 1000" ;;
esac
exit 0
EOF
cat > "$STUB_BIN/ssh" <<'EOF'
#!/usr/bin/env bash
echo "ssh $*" >> "$CALL_LOG"
cat > "$T_TMP/ssh.stdin"
exit 0
EOF
cat > "$STUB_BIN/sleep" <<'EOF'
#!/usr/bin/env bash
echo "sleep $*" >> "$CALL_LOG"
[ -z "${SLEEP_SIG:-}" ] || kill -"$SLEEP_SIG" "$PPID"
exit 0
EOF
chmod +x "$STUB_BIN"/*

# in-container tool stubs (see the docker stub's REAL_SNIPPET): `timeout 6 nc -w 3 <host> <port>` is emulated as one
# command; the gateway host gets NC_RC/NC_ERR, every other host OTHER_RC/OTHER_ERR (stderr text, like nc's own).
mkdir -p "$T_TMP/snip-src"
cat > "$T_TMP/snip-src/timeout" <<'EOF'
#!/bin/bash
echo "timeout $*" >> "$CALL_LOG"
if [ "$5" = "$GW_ENV" ]; then rc="$NC_RC"; err="$NC_ERR"; else rc="$OTHER_RC"; err="$OTHER_ERR"; fi
[ -z "$err" ] || echo "$err" >&2
exit "$rc"
EOF
cat > "$T_TMP/snip-src/nc" <<'EOF'
#!/bin/bash
exit 0
EOF
cat > "$T_TMP/snip-src/nslookup" <<'EOF'
#!/bin/bash
echo "nslookup $*" >> "$CALL_LOG"
exit "$NSLOOKUP_RC"
EOF
chmod +x "$T_TMP"/snip-src/*

# ---- chain builder and mutators (CH is the array of `iptables -S` lines) ----

CH=()
# base_chain "<deny cidrs>" "<allow cidrs>"
base_chain() {
  local cidr iface proto i o
  CH=("-N DOCKER-USER" "$P -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN" "$P -i lo -j RETURN")
  for i in br-+ docker0; do for o in br-+ docker0; do CH+=("$P -i $i -o $o -j RETURN"); done; done
  for cidr in $2; do
    for iface in br-+ docker0; do for proto in udp tcp; do CH+=("$P -d $cidr -i $iface -p $proto -m $proto --dport 53 -j RETURN"); done; done
  done
  for cidr in $1; do for iface in br-+ docker0; do CH+=("$P -d $cidr -i $iface -j DROP"); done; done
  CH+=("$P -i docker0 -j RETURN" "$P -i br-+ -j RETURN" "$P -j DROP")
}
write_chain() { printf '%s\n' "${CH[@]}" > "$CHAIN_FILE"; }
ch_drop() { local out=() l; for l in "${CH[@]}"; do case "$l" in *"$1"*) ;; *) out+=("$l") ;; esac; done; CH=("${out[@]}"); }
ch_insert_before() {
  local out=() l done=0
  for l in "${CH[@]}"; do
    if [ "$done" -eq 0 ] && [[ "$l" == *"$1"* ]]; then out+=("$2"); done=1; fi
    out+=("$l")
  done
  CH=("${out[@]}")
}
ch_dup() {
  local out=() l done=0
  for l in "${CH[@]}"; do
    out+=("$l")
    if [ "$done" -eq 0 ] && [[ "$l" == *"$1"* ]]; then out+=("$l"); done=1; fi
  done
  CH=("${out[@]}")
}
ch_set_last() { CH[${#CH[@]} - 1]="$1"; }

# set_counters <before> <after>: the two `iptables -L -v -n -x` outputs the inbound probe reads
set_counters() {
  local n=1 v
  for v in "$1" "$2"; do
    printf '%s\n' 'Chain DOCKER-USER (1 references)' \
      '    pkts      bytes target     prot opt in     out     source               destination' \
      '       9      540 DROP       all  --  br-+   *       anywhere             anywhere' \
      "$(printf '%8s %8s DROP       all  --  *      *       anywhere             anywhere' "$v" 0)" > "$T_TMP/L$n.txt"
    n=$((n + 1))
  done
}

reset() {
  printf '# blocked ranges\n%s\n' "$DENY" > "$DENY_FILE"
  printf '%s\n' "$ALLOW" > "$ALLOW_FILE"
  base_chain "$DENY" "$ALLOW"; write_chain
  set_counters 3 7
  rm -f "$T_TMP/Lcount" "$T_TMP/ssh.stdin"
  : > "$CALL_LOG"
  export VERIFY_EGRESS_DENY_FILE="$DENY_FILE" VERIFY_EGRESS_ALLOW_FILE="$ALLOW_FILE" VERIFY_EGRESS_DOCKER=docker
  export VERIFY_EGRESS_INBOUND_WAIT=5
  export VERIFY_EGRESS_IPTABLES="$STUB_BIN/iptables"
  export IPT_RC="" IPT_EMPTY="" IPT_WARN="" IPV6=false IPV6_NET=false LS_RC=0 NETS="aaa bbb"
  export INSPECT_RC=0 NETCREATE_RC=0 RUN_FAIL_NAME="" CONN_A=open SLEEP_SIG=""
  export REAL_SNIPPET="" ABSENT="" NC_RC=1 NC_ERR="" OTHER_RC=0 OTHER_ERR="" NSLOOKUP_RC=0
  export GW_ENV="$GW" LAN_ENV="$LAN" PORT_OUT="$LAN:49153"
  export PROBE_OUT=$'TOOLS=ok\nLOOKUP=ok\nGATEWAY=blocked\nPUBLIC=open'
}

run_v() { run_cmd bash "$script" "$@"; }
count_calls() { grep -cF -- "$1" "$CALL_LOG" || true; }

# expect_clean <label>: the throwaway resources were removed at the end (the last call is the network removal).
expect_clean() {
  expect_eq "$1: network removed last" "$(tail -n 1 "$CALL_LOG")" "docker network rm platform-verify-egress-net"
  local n
  for n in probe b a inbound; do
    expect_eq "$1: $n removed at start and end" "$(count_calls "docker rm -f platform-verify-egress-$n")" "2"
  done
}

# fixture: a copy of the sanitized capture embedded in the stronghold test (test_server_host_base.py SCRATCH_CAPTURE,
# chain name renamed to DOCKER-USER); not a new capture.
real_capture() {
  cat <<EOF
-N DOCKER-USER
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -i lo -j RETURN
-A DOCKER-USER -i br-+ -o br-+ -j RETURN
-A DOCKER-USER -i br-+ -o docker0 -j RETURN
-A DOCKER-USER -i docker0 -o br-+ -j RETURN
-A DOCKER-USER -i docker0 -o docker0 -j RETURN
-A DOCKER-USER -d $ALLOW -i br-+ -p udp -m udp --dport 53 -j RETURN
-A DOCKER-USER -d $ALLOW -i br-+ -p tcp -m tcp --dport 53 -j RETURN
-A DOCKER-USER -d $ALLOW -i docker0 -p udp -m udp --dport 53 -j RETURN
-A DOCKER-USER -d $ALLOW -i docker0 -p tcp -m tcp --dport 53 -j RETURN
-A DOCKER-USER -d $DENY -i br-+ -j DROP
-A DOCKER-USER -d $DENY -i docker0 -j DROP
-A DOCKER-USER -i docker0 -j RETURN
-A DOCKER-USER -i br-+ -j RETURN
-A DOCKER-USER -j DROP
EOF
}

# ===================== static checks: passing paths =====================

reset
run_v
expect_rc "happy chain passes" 0
expect_out_has "happy chain prints OK" "verify-egress: OK"
expect_calls_lacks "no probe flag: no docker run" "docker run"
expect_calls_lacks "no probe flag: no network create" "network create"
expect_calls_lacks "no probe flag: no container removal" "docker rm"
expect_calls_has "chain read through sudo -n iptables" "sudo -n "
expect_calls_has "chain read" "iptables -S DOCKER-USER"

reset
real_capture > "$CHAIN_FILE"
run_v
expect_rc "real scratch-chain capture passes" 0

reset
printf '%s\n%s\n' "$DENY" "$DENY2" > "$DENY_FILE"
base_chain "$DENY $DENY2" "$ALLOW"; write_chain
run_v
expect_rc "two deny CIDRs pass" 0

reset
rm -f "$ALLOW_FILE"
base_chain "$DENY" ""; write_chain
run_v
expect_rc "absent allow file with no allow RETURNs passes" 0

reset
run_cmd env -u VERIFY_EGRESS_DOCKER bash "$script"
expect_rc "default docker command passes" 0
expect_calls_has "default docker command is sudo -n docker" "sudo -n docker network inspect bridge"

# ===================== static checks: failures (exit 1) =====================

reset; ch_drop "-d $DENY -i br-+ -j DROP"; write_chain; run_v
expect_rc "missing br-+ drop" 1
expect_out_has "missing br-+ drop named" "-A -i br-+ -d $DENY -j DROP"

reset; ch_drop "-d $DENY -i docker0 -j DROP"; write_chain; run_v
expect_rc "missing docker0 drop" 1
expect_out_has "missing docker0 drop named" "-A -i docker0 -d $DENY -j DROP"

reset; printf '%s\n%s\n' "$DENY" "$DENY2" > "$DENY_FILE"; run_v
expect_rc "configured CIDR without any drop in the chain" 1

reset; ch_insert_before "-i docker0 -j RETURN" "$P -d $OTHER -i br-+ -j DROP"; write_chain; run_v
expect_rc "unexpected extra drop" 1
expect_out_has "extra drop named" "$OTHER"

reset; ch_dup "-d $DENY -i br-+ -j DROP"; write_chain; run_v
expect_rc "duplicated drop" 1

reset; ch_drop "-d $DENY -i docker0 -j DROP"; ch_insert_before "$P -j DROP" "$P -d $DENY -i docker0 -j DROP"; write_chain; run_v
expect_rc "drop after the bridge RETURN" 1
expect_out_has "drop after RETURN reported as out of order" "out of order"

reset; ch_insert_before "-i br-+ -o docker0" "$P -o br-+ -j RETURN"; write_chain; run_v
expect_rc "bare -o RETURN" 1
expect_out_has "bare -o RETURN named" "RETURN on -o without a bridge"

reset; ch_insert_before "-i br-+ -o docker0" "$P -i eth0 -o br-+ -j RETURN"; write_chain; run_v
expect_rc "-o RETURN with a non-bridge -i" 1

reset; ch_drop "-i docker0 -o br-+"; write_chain; run_v
expect_rc "missing interface-pair RETURN" 1

reset; ch_insert_before "-d $DENY -i br-+ -j DROP" "$P -d $OTHER -i br-+ -p udp -m udp --dport 53 -j RETURN"; write_chain; run_v
expect_rc "allow RETURN not in the allow file" 1
expect_out_has "stray allow RETURN named" "$OTHER"

reset; ch_drop "-d $ALLOW -i docker0 -p tcp"; write_chain; run_v
expect_rc "allow RETURN in the file but missing from the chain" 1

reset; rm -f "$ALLOW_FILE"; run_v
expect_rc "allow RETURNs in the chain but no allow file" 1
expect_out_has "an empty wanted set shows no phantom missing entry" "missing: none)"

reset; ch_drop "-d $DENY"; write_chain; run_v
expect_rc "every drop missing from the chain" 1
expect_out_has "an empty actual set shows no phantom extra entry" "extra: none missing: -A -i br-+ -d $DENY -j DROP;-A -i docker0 -d $DENY -j DROP;)"

reset; ch_insert_before "-d $DENY -i br-+ -j DROP" "$P -d $ALLOW -i br-+ -p tcp -m tcp --dport 80 -j RETURN"; write_chain; run_v
expect_rc "allow RETURN on a port other than 53" 1

reset; ch_set_last "$P -j RETURN"; write_chain; run_v
expect_rc "final rule not DROP" 1
expect_out_has "final rule named" "final rule"

reset; printf '%s' "-N DOCKER-USER
-A DOCKER-USER -j RETURN
" > "$CHAIN_FILE"; run_v
expect_rc "open chain (stock RETURN only)" 1

reset; ch_drop "--ctstate RELATED,ESTABLISHED"; write_chain; run_v
expect_rc "missing conntrack RETURN" 1

reset; ch_insert_before "-d $DENY -i br-+ -j DROP" "$P -s $OTHER -j DROP"; write_chain; run_v
expect_rc "unparseable rule" 1
expect_out_has "unparseable rule named" "unrecognised rule"

reset; export IPT_EMPTY=1; run_v
expect_rc "empty iptables output" 1
expect_out_has "empty output named" "printed nothing"

reset; export IPT_RC=1; run_v
expect_rc "unreadable chain (iptables fails)" 1
expect_out_has "unreadable chain named" "cannot read"

reset; export IPV6=true; run_v
expect_rc "Docker IPv6 enabled" 1
expect_out_has "IPv6 named" "IPv6"

reset; export INSPECT_RC=1; run_v
expect_rc "Docker network inspect fails" 1

reset; export IPV6_NET=true; run_v
expect_rc "IPv6 enabled on a user-defined network" 1
expect_out_has "IPv6 network named" "network(s): aaa bbb"

reset; export LS_RC=1; run_v
expect_rc "Docker network list fails" 1

reset; export IPT_WARN=1; run_v
expect_rc "a sudo warning on stderr is not parsed as a rule" 0

reset; run_v --help
expect_rc "--help" 0
expect_out_has "--help prints the usage" "Usage: verify-egress.sh"
expect_out_lacks "--help stops before the code" "set -euo pipefail"

# deny/allow file validity
bad_deny() { # label content expected-message-fragment
  reset; printf '%b' "$2" > "$DENY_FILE"; run_v
  expect_rc "deny file $1" 1
  expect_out_has "deny file $1: the reason is named" "$3"
}
bad_deny "empty" "" "no CIDR lines"
bad_deny "comments only" "# nothing\n\n" "no CIDR lines"
bad_deny "bare address" "$(t_ip4 198 51 100 0)\n" "not a canonical IPv4 CIDR"
bad_deny "host bits set" "$(t_ip4 198 51 100 1)/24\n" "host bits set"
bad_deny "/0 prefix" "$(t_ip4 0 0 0 0)/0\n" "prefix must be 1-32"
bad_deny "/33 prefix" "$(t_ip4 198 51 100 0)/33\n" "prefix must be 1-32"
bad_deny "leading-zero prefix /08" "$(t_ip4 10 0 0 0)/08\n" "not a canonical IPv4 CIDR"
bad_deny "leading-zero octet 010" "$(t_ip4 010 0 0 0)/8\n" "not a canonical IPv4 CIDR"
bad_deny "leading-zero octet 051" "$(t_ip4 198 051 100 0)/24\n" "not a canonical IPv4 CIDR"
bad_deny "four-digit octet" "$(t_ip4 1000 0 0 0)/8\n" "not a canonical IPv4 CIDR"
bad_deny "CRLF" "$DENY\r\n" "CRLF"
bad_deny "trailing space" "$DENY \n" "trailing whitespace"
bad_deny "trailing space on a comment" "# note \n$DENY\n" "trailing whitespace"
bad_deny "duplicate line" "$DENY\n$DENY\n" "duplicate line"
bad_deny "IPv6" "fe80::/10\n" "not a canonical IPv4 CIDR"
bad_deny "octet out of range" "$(t_ip4 300 0 0 0)/8\n" "octet out of range"
bad_deny "octet 256 out of range" "$(t_ip4 10 256 0 0)/16\n" "octet out of range"
reset; rm -f "$DENY_FILE"; run_v
expect_rc "deny file missing" 1
expect_out_has "missing deny file named" "missing"

# a dangling symlink is a missing deny file, not an empty one
reset; rm -f "$DENY_FILE"; ln -s "$T_TMP/no-such-target" "$DENY_FILE"; run_v
expect_rc "deny file is a dangling symlink" 1
expect_out_has "dangling deny symlink reads as missing" "is missing"
rm -f "$DENY_FILE" "$T_TMP/no-such-target"

# an unreadable file is an invalid one (a root caller reads anything, so the case is skipped there)
if [ "$(/usr/bin/id -u)" -ne 0 ]; then
  reset; chmod 000 "$DENY_FILE"; run_v
  expect_rc "deny file unreadable" 1
  expect_out_has "unreadable deny file named" "not readable"
  chmod 600 "$DENY_FILE"
  reset; chmod 000 "$ALLOW_FILE"; run_v
  expect_rc "allow file unreadable" 1
  expect_out_has "unreadable allow file named" "not readable"
  chmod 600 "$ALLOW_FILE"
fi

reset; rm -f "$ALLOW_FILE"; ln -s "$T_TMP/no-such-target" "$ALLOW_FILE"; run_v
expect_rc "allow file is a dangling symlink" 1
expect_out_has "dangling allow symlink is present but invalid" "present but invalid"
rm -f "$ALLOW_FILE" "$T_TMP/no-such-target"

# accepted boundaries: the chain is built from the same ranges, so only the file grammar is under test
good_deny() { # label content cidr-list-for-the-chain [allow-chain-list]
  reset; printf '%b' "$2" > "$DENY_FILE"; base_chain "$3" "$ALLOW"; write_chain; run_v
  expect_rc "deny file accepted: $1" 0
}
good_deny "/1 prefix" "$(t_ip4 128 0 0 0)/1\n" "$(t_ip4 128 0 0 0)/1"
good_deny "/32 prefix" "$(t_ip4 198 51 100 7)/32\n" "$(t_ip4 198 51 100 7)/32"
good_deny "255 octet boundary" "$(t_ip4 255 255 255 0)/24\n" "$(t_ip4 255 255 255 0)/24"
good_deny "no trailing newline" "$DENY" "$DENY"
good_deny "comment lines between ranges" "# a\n$DENY\n\n# b\n" "$DENY"
reset; printf '# nothing to allow\n\n' > "$ALLOW_FILE"; base_chain "$DENY" ""; write_chain; run_v
expect_rc "a comments-only allow file is valid and means no allow RETURNs" 0
reset; rm -f "$DENY_FILE"; run_v
expect_calls_lacks "missing deny file: probes never start" "docker run"

reset; printf '%s \n' "$ALLOW" > "$ALLOW_FILE"; run_v
expect_rc "allow file present but invalid" 1
reset; printf '%s\n%s\n' "$ALLOW" "$ALLOW" > "$ALLOW_FILE"; run_v
expect_rc "allow file with a duplicate line" 1

# usage and --host
reset; run_v --bogus
expect_rc "unknown flag" 2
reset; run_v --host
expect_rc "--host without a value" 2

reset; run_v --host pi --probe
expect_rc "--host streams over ssh" 0
expect_calls_has "--host ssh argv forwards the flag" "ssh -o BatchMode=yes -- pi bash -s -- --probe"
expect_eq "--host streams this script" "$(head -n 1 "$T_TMP/ssh.stdin" 2>/dev/null)" "#!/usr/bin/env bash"
expect_calls_lacks "--host runs nothing locally" "docker"

reset; run_v --host pi --probe --probe-inbound
expect_rc "--host with both probe flags" 0
expect_calls_has "--host forwards both flags" "ssh -o BatchMode=yes -- pi bash -s -- --probe --probe-inbound"

reset; run_v --host pi
expect_rc "--host with no other flags" 0
expect_eq "--host with no flags forwards none" "$(grep '^ssh ' "$CALL_LOG")" "ssh -o BatchMode=yes -- pi bash -s --"

reset; ch_set_last "$P -j RETURN"; write_chain; run_v --probe
expect_rc "static failure with --probe" 1
expect_calls_lacks "static failure skips the probe" "docker run"
expect_calls_lacks "static failure creates no network" "network create"
expect_out_has "static failure says the probes were skipped" "probes skipped because the static checks failed"

reset; ch_set_last "$P -j RETURN"; write_chain; run_v --probe-inbound
expect_rc "static failure with --probe-inbound" 1
expect_out_has "static failure with --probe-inbound says the probes were skipped" "probes skipped because the static checks failed"

reset; ch_set_last "$P -j RETURN"; write_chain; run_v
expect_out_lacks "no probe flag: no skipped-probes message" "probes skipped"

# ===================== --probe =====================

reset; run_v --probe
expect_rc "probe passes" 0
expect_out_has "probe reports the gateway blocked" "gateway port 443 blocked"
expect_calls_has "probe creates the throwaway network" "docker network create platform-verify-egress-net"
expect_calls_has "probe targets the discovered gateway on a non-53 port" "probe $GW 443 example.com"
expect_calls_lacks "probe never uses port 53 for the gateway" "probe $GW 53"
expect_calls_has "probe runs the bridge/bridge check" "--name platform-verify-egress-a --network platform-verify-egress-net"
expect_calls_lacks "probe has no docker0 container" "platform-verify-egress-d0"
expect_clean "probe pass"

probe_case() { # label want_rc probe_out
  reset; export PROBE_OUT="$3"; run_v --probe
  expect_rc "probe: $1" "$2"
  expect_clean "probe: $1"
}
probe_case "gateway refused" 1 $'TOOLS=ok\nLOOKUP=ok\nGATEWAY=refused\nPUBLIC=open'
probe_case "gateway reachable" 1 $'TOOLS=ok\nLOOKUP=ok\nGATEWAY=open\nPUBLIC=open'
probe_case "public connect blocked (an always-blocked probe must fail)" 1 $'TOOLS=ok\nLOOKUP=ok\nGATEWAY=blocked\nPUBLIC=blocked'
probe_case "everything blocked" 1 $'TOOLS=ok\nLOOKUP=fail\nGATEWAY=blocked\nPUBLIC=blocked'
probe_case "public connect refused" 1 $'TOOLS=ok\nLOOKUP=ok\nGATEWAY=blocked\nPUBLIC=refused'
probe_case "lookup fails" 1 $'TOOLS=ok\nLOOKUP=fail\nGATEWAY=blocked\nPUBLIC=open'
probe_case "gateway connect container error" 2 $'TOOLS=ok\nLOOKUP=ok\nGATEWAY=error\nPUBLIC=open'
probe_case "public connect container error" 2 $'TOOLS=ok\nLOOKUP=ok\nGATEWAY=blocked\nPUBLIC=error'
probe_case "tool missing in the image" 2 'TOOLS=missing-nc'
probe_case "no output from the container" 2 ''
probe_case "gateway token missing" 2 $'TOOLS=ok\nLOOKUP=ok\nPUBLIC=open'

reset; export RUN_FAIL_NAME=platform-verify-egress-probe; run_v --probe
expect_rc "probe: container fails to start" 2
expect_clean "probe: container fails to start"

reset; export NETCREATE_RC=1; run_v --probe
expect_rc "probe: network create fails" 2
expect_clean "probe: network create fails"

reset; export GW_ENV="$GW_OUTSIDE"; run_v --probe
expect_rc "probe: gateway not covered by a deny CIDR" 2
expect_out_has "uncovered gateway message" "not covered"
expect_calls_lacks "uncovered gateway: nothing started" "docker run"
expect_calls_lacks "uncovered gateway: no network" "network create"

reset; export VERIFY_EGRESS_PROBE_PORT=53; run_v --probe
expect_rc "probe: port 53 is refused (a resolver exception would mask the drop)" 2
expect_out_has "port 53 named" "must not be 53"
expect_calls_lacks "probe port 53: nothing started" "docker run"
unset VERIFY_EGRESS_PROBE_PORT

reset; export GW_ENV=""; run_v --probe
expect_rc "probe: no default route" 2
expect_calls_lacks "no default route: nothing started" "docker run"

reset; export GW_ENV="not-an-address"; run_v --probe
expect_rc "probe: unparseable gateway" 2

# gateway present in both files: the resolver allow exception is port 53 only, so the non-53 probe is not masked
reset; printf '%s/32\n' "$GW" > "$ALLOW_FILE"; base_chain "$DENY" "$GW/32"; write_chain
run_v --probe
expect_rc "probe: gateway in deny and allow files" 0
expect_calls_has "gateway in both files: probe port is not 53" "probe $GW 443"
reset; printf '%s/32\n' "$GW" > "$ALLOW_FILE"; base_chain "$DENY" "$GW/32"; write_chain
export PROBE_OUT=$'TOOLS=ok\nLOOKUP=ok\nGATEWAY=open\nPUBLIC=open'; run_v --probe
expect_rc "probe: gateway in both files but reachable still fails" 1

# container-to-container
c2c_case() { # label want_rc var=value
  reset; export "${3?}"; run_v --probe
  expect_rc "c2c: $1" "$2"
  expect_clean "c2c: $1"
}
c2c_case "bridge/bridge blocked" 1 CONN_A=blocked
c2c_case "bridge/bridge refused" 1 CONN_A=refused
expect_eq "c2c: refused is retried then fails (5 attempts)" "$(count_calls '--name platform-verify-egress-a')" "5"
c2c_case "bridge/bridge container error" 2 CONN_A=error
c2c_case "server container fails to start" 2 RUN_FAIL_NAME=platform-verify-egress-b
c2c_case "bridge client container fails to start" 2 RUN_FAIL_NAME=platform-verify-egress-a

# a wrong-rules finding already recorded is never masked by a later container error (exit 1, not 2)
reset; export PROBE_OUT=$'TOOLS=ok\nLOOKUP=ok\nGATEWAY=open\nPUBLIC=open' CONN_A=error; run_v --probe
expect_rc "recorded failure plus a later container error exits 1" 1
expect_out_has "masked-finding summary printed" "1 check(s) failed"
expect_clean "recorded failure plus a later container error"

# ===================== in-container snippets, run for real (REAL_SNIPPET) =====================

real_case() { # label want_rc [var=value...]
  local label="$1" want="$2"
  shift 2
  reset; export REAL_SNIPPET=1
  local kv
  for kv in "$@"; do export "${kv?}"; done
  run_v --probe
  expect_rc "snippet: $label" "$want"
  expect_clean "snippet: $label"
}
real_case "gateway timed out, public open (happy path)" 0
expect_calls_has "probe connect is bounded" "timeout 6 nc -w 3"
expect_calls_has "snippet ran the lookup" "nslookup example.com"
expect_out_has "happy path: gateway blocked" "gateway port 443 blocked"
real_case "gateway nc rc 0 is open" 1 NC_RC=0 NC_ERR=
expect_out_has "nc rc 0 reads as reachable" "is reachable from a container"
real_case "gateway Connection refused" 1 NC_RC=1 "NC_ERR=nc: Connection refused"
expect_out_has "refused classified" "was refused"
real_case "gateway Connection reset" 1 NC_RC=1 "NC_ERR=nc: Connection reset by peer"
expect_out_has "reset classified as refused" "was refused"
real_case "gateway timeout rc 124" 0 NC_RC=124 NC_ERR=
expect_out_has "rc 124 classified blocked" "gateway port 443 blocked"
real_case "gateway timeout rc 137" 0 NC_RC=137 NC_ERR=
expect_out_has "rc 137 classified blocked" "gateway port 443 blocked"
real_case "gateway timeout rc 143" 0 NC_RC=143 NC_ERR=
expect_out_has "rc 143 classified blocked" "gateway port 443 blocked"
real_case "gateway nc timed-out message" 0 NC_RC=1 "NC_ERR=nc: timed out"
expect_out_has "timed-out message classified blocked" "gateway port 443 blocked"
real_case "gateway silent rc 2 is a container error" 2 NC_RC=2 NC_ERR=
expect_out_has "silent rc 2 classified error" "container/network error"
real_case "gateway other stderr is a container error" 2 NC_RC=1 "NC_ERR=nc: bad address"
expect_out_has "unknown error classified error" "container/network error"
real_case "public connect timed out" 1 OTHER_RC=1 "OTHER_ERR=nc: timed out"
expect_out_has "public timed out is not success" "did not succeed"
real_case "lookup fails" 1 NSLOOKUP_RC=1
real_case "container-to-container refused is retried then fails" 1 OTHER_RC=1 "OTHER_ERR=nc: Connection refused"
real_case "missing nc" 2 ABSENT=nc
expect_out_has "missing nc named" "missing-nc"
real_case "missing timeout" 2 ABSENT=timeout
expect_out_has "missing timeout named" "missing-timeout"
real_case "missing nslookup" 2 ABSENT=nslookup
expect_out_has "missing nslookup named" "missing-nslookup"

# mutation sanity: the same happy run against a copy whose "rc 0" arm is always-blocked must fail
sed 's/0) echo open ;;/0) echo blocked ;;/' "$script" > "$T_TMP/mutant.sh"
if cmp -s "$script" "$T_TMP/mutant.sh"; then _fail "mutation applied" "the sed did not change the script"; else _pass; fi
reset; export REAL_SNIPPET=1; run_cmd bash "$T_TMP/mutant.sh" --probe
expect_rc "an always-blocked classification fails the happy path" 1
reset; export REAL_SNIPPET=1; run_cmd bash "$script" --probe
expect_rc "the unmutated script passes the same run" 0

# ===================== --probe-inbound =====================

reset; run_v --probe-inbound
expect_rc "inbound: drop counter rises" 0
expect_calls_has "inbound publishes on the LAN address" "-p $LAN::8080"
expect_calls_has "inbound waits the bounded time" "sleep 5"
expect_calls_lacks "inbound only: no throwaway network" "network create"
expect_clean "inbound pass"

sig_case() { # signal want_rc
  reset; export SLEEP_SIG="$1"; run_v --probe-inbound
  expect_rc "signal $1 during the inbound wait" "$2"
  expect_clean "signal $1 during the inbound wait"
}
sig_case TERM 143
sig_case INT 130
sig_case HUP 129

reset; set_counters 7 7; run_v --probe-inbound
expect_rc "inbound: no dropped packet observed" 1
expect_clean "inbound: no packet"

reset; export RUN_FAIL_NAME=platform-verify-egress-inbound; run_v --probe-inbound
expect_rc "inbound: container fails to start" 2
expect_clean "inbound: container fails"

reset; export PORT_OUT=""; run_v --probe-inbound
expect_rc "inbound: no published port" 2
expect_clean "inbound: no port"

reset; printf 'Chain DOCKER-USER (1 references)\n' > "$T_TMP/L1.txt"; run_v --probe-inbound
expect_rc "inbound: final DROP counter not found" 2
expect_calls_lacks "inbound: unreadable counters start nothing" "docker run"

reset; export GW_ENV=""; run_v --probe-inbound
expect_rc "inbound: no gateway" 2
expect_calls_lacks "inbound: no gateway starts nothing" "docker run"

# ===================== structure =====================

if grep -nE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$script" | grep -vE '127\.|0\.0\.0\.0' >/dev/null; then
  _fail "verify-egress.sh holds no address literal" "found a dotted-quad"
else _pass; fi

t_finish
