#!/usr/bin/env bash
# Tests for network_check.sh.  Counters live in fake /sys and /proc trees that are REWRITTEN 0.4s into the 1s sample
# window (so the script sees real deltas); probes run against real local listeners.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$HERE/.."
export LOG_LEVEL=error
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
fresh_state() { SYSMON_STATE_DIR="$(mktemp -d)"; export SYSMON_STATE_DIR; }

# ---------------- fixture builders ------------------------------------------------------------------------------------
setif() {  # setif SYS IFACE oper speed duplex rx_err tx_err rx_drop tx_drop rx_bytes tx_bytes carrier_changes
    local d="$1/class/net/$2"; mkdir -p "$d/statistics"
    echo "$3" > "$d/operstate"; echo "$4" > "$d/speed"; echo "$5" > "$d/duplex"
    echo "$6" > "$d/statistics/rx_errors"; echo "$7" > "$d/statistics/tx_errors"; echo "$8" > "$d/statistics/rx_dropped"; echo "$9" > "$d/statistics/tx_dropped"
    echo "${10}" > "$d/statistics/rx_bytes"; echo "${11}" > "$d/statistics/tx_bytes"; echo "${12}" > "$d/carrier_changes"
}
setsnmp() {  # setsnmp PROC OUTSEGS RETRANS LISTENOVERFLOWS LISTENDROPS
    mkdir -p "$1/net"
    printf 'Tcp: RtoAlgorithm RtoMin OutSegs RetransSegs InErrs\nTcp: 1 200 %s %s 0\n' "$2" "$3" > "$1/net/snmp"
    printf 'TcpExt: SyncookiesSent ListenOverflows ListenDrops\nTcpExt: 0 %s %s\n' "$4" "$5" > "$1/net/netstat"
}
settcp() {  # settcp PROC ESTAB CLOSE_WAIT TIME_WAIT
    local f="$1/net/tcp" i n=0; printf '  sl  local_address rem_address   st tx_queue rx_queue\n' > "$f"; : > "$1/net/tcp6"
    for i in $(seq 1 "$2"); do printf '%4d: 0100007F:1F90 0100007F:C000 01 0:0 0:0 0 0 1\n' $((n++)) >> "$f"; done
    for i in $(seq 1 "$3"); do printf '%4d: 0100007F:1F90 0100007F:C001 08 0:0 0:0 0 0 1\n' $((n++)) >> "$f"; done
    for i in $(seq 1 "$4"); do printf '%4d: 0100007F:1F90 0100007F:C002 06 0:0 0:0 0 0 1\n' $((n++)) >> "$f"; done
    printf '%4d: 00000000:0016 00000000:0000 0A 0:0 0:0 0 0 1\n' $((n++)) >> "$f"
}
mk() {  # mk → sets FXP (proc fixture) and FXS (sys fixture) with a healthy baseline
    FXP="$(mktemp -d)"; FXS="$(mktemp -d)"; mkdir -p "$FXP/sys/kernel" "$FXP/net"; echo testhost > "$FXP/sys/kernel/hostname"
    setif "$FXS" eth0 up 1000 full 0 0 0 0 1000 1000 1
    setif "$FXS" lo unknown -1 unknown 0 0 0 0 0 0 0
    setif "$FXS" docker0 up -1 unknown 0 0 0 0 0 0 0
    setsnmp "$FXP" 1000 10 0 0; settcp "$FXP" 5 0 2
}
# go [args…]  — runs with a 1s window; $MUTATE (a shell snippet) is executed 0.4s in, to move the counters
go() {
    fresh_state; local mp=""
    if [[ -n "${MUTATE:-}" ]]; then ( sleep 0.4; eval "$MUTATE" ) & mp=$!; fi
    OUT="$(SYSMON_PROC="$FXP" SYSMON_SYS="$FXS" bash "$ROOT/network_check.sh" --interval 1 "$@" 2>&1)"; RC=$?
    if [[ -n "$mp" ]]; then wait "$mp"; fi          # wait ONLY for our own mutation job — a bare `wait` would also wait for the long-lived test listeners
    MUTATE=""
}
chk() { if (( RC != $1 )); then bad "$2 (want rc=$1 got rc=$RC): ${OUT:0:500}"; return; fi
        if [[ -n "${3:-}" ]] && ! grep -qE -- "$3" <<<"$OUT"; then bad "$2 (rc ok, missing /$3/): ${OUT:0:500}"; return; fi; ok; }

# ---------------- healthy baseline ------------------------------------------------------------------------------------------
mk; go;                                                                     chk 0 "healthy" '^OK: 1 interface\(s\) sampled'
grep -q 'docker0' <<<"$OUT" && bad "docker0/lo must be excluded by default" || ok

# ---------------- interface error / drop RATES --------------------------------------------------------------------------------
mk; MUTATE='setif "$FXS" eth0 up 1000 full 30 0 0 0 5000 5000 1'; go;       chk 2 "30 errors/s → CRITICAL" 'eth0: [0-9.]+ errors\+drops/s'
mk; MUTATE='setif "$FXS" eth0 up 1000 full 3 0 2 0 5000 5000 1'; go;        chk 1 "5 errors+drops → WARNING" 'WARNING interface eth0'
mk; setif "$FXS" eth0 up 1000 full 4000000 0 0 0 1000 1000 1; go;           chk 0 "4 million LIFETIME errors but none now → OK (rates, not counters)" '^OK:'
mk; setif "$FXS" docker0 up -1 unknown 0 0 0 0 0 0 0; MUTATE='setif "$FXS" docker0 up -1 unknown 9999 0 0 0 0 0 0'; go; chk 0 "errors on an excluded interface are ignored" '^OK:'
mk; MUTATE='setif "$FXS" eth0 up 1000 full 0 0 0 0 5000 5000 1'; go;        chk 0 "throughput is reported" 'mbps_eth0='

# ---------------- link health --------------------------------------------------------------------------------------------------------
mk; MUTATE='setif "$FXS" eth0 up 1000 full 0 0 0 0 1000 1000 4'; go;        chk 1 "link flapped 3x → WARNING" 'link flapped 3x'
mk; setif "$FXS" eth0 up 100 half 0 0 0 0 1000 1000 1; go;                  chk 1 "half duplex → WARNING" 'HALF duplex'
mk; setif "$FXS" eth0 up -1 unknown 0 0 0 0 1000 1000 1; go;                chk 0 "unknown duplex / speed -1 (virtual NIC) is not a fault" '^OK:'
mk; go --require-up eth0;                                                   chk 0 "required interface is up" '^OK:'
mk; setif "$FXS" eth1 down -1 unknown 0 0 0 0 0 0 0; go --require-up eth0,eth1;  chk 2 "required interface down → CRITICAL" 'eth1 is down'
mk; go --require-up eth9;                                                   chk 2 "required interface missing → CRITICAL" 'eth9 is missing'

# ---------------- TCP retransmits -------------------------------------------------------------------------------------------------------
mk; MUTATE='setsnmp "$FXP" 2000 110 0 0'; go;                               chk 2 "100/1000 retransmitted (10%) → CRITICAL" 'TCP retransmits 10\.0%'
mk; MUTATE='setsnmp "$FXP" 2000 30 0 0'; go;                                chk 1 "20/1000 (2%) → WARNING" 'TCP retransmits 2\.0%'
mk; MUTATE='setsnmp "$FXP" 1050 20 0 0'; go;                                chk 0 "only 50 segments in the window → not evaluated (no noise)" '^OK:'
mk; MUTATE='setsnmp "$FXP" 2000 10 0 0'; go;                                chk 0 "no retransmits → OK" 'tcp_retrans_pct=0\.0%'
mk; MUTATE='setsnmp "$FXP" 100 5 0 0'; go;                                  chk 0 "counter reset (reboot) must not alert" '^OK:'
mk; MUTATE='setsnmp "$FXP" 2000 110 0 0'; go --confirm 2;                   chk 1 "retransmit CRITICAL held back by --confirm 2" 'unconfirmed 1/2'

# ---------------- listen queue / conntrack / sockets ---------------------------------------------------------------------------------------
mk; MUTATE='setsnmp "$FXP" 1000 10 150 0'; go;                              chk 2 "150 listen overflows → CRITICAL" '150 listen-queue drops'
grep -q 'NOT a network fault' <<<"$OUT" && ok || bad "listen drop detail should say it's the app: $OUT"
mk; MUTATE='setsnmp "$FXP" 1000 10 3 2'; go;                                chk 1 "5 listen drops → WARNING" '5 listen-queue drops'

mk; mkdir -p "$FXP/sys/net/netfilter"; echo 95000 > "$FXP/sys/net/netfilter/nf_conntrack_count"; echo 100000 > "$FXP/sys/net/netfilter/nf_conntrack_max"; go
chk 2 "conntrack 95% → CRITICAL" 'conntrack 95\.0%'
echo 50000 > "$FXP/sys/net/netfilter/nf_conntrack_count"; go;                chk 0 "conntrack 50% → OK" 'conntrack_pct=50\.0%'

mk; settcp "$FXP" 5 150 2; go;                                              chk 1 "150 CLOSE_WAIT → WARNING" '150 sockets in CLOSE_WAIT'
grep -q 'LOCAL APPLICATION never called close' <<<"$OUT" && ok || bad "CLOSE_WAIT detail should blame the app"
mk; settcp "$FXP" 5 1500 2; go;                                             chk 2 "1500 CLOSE_WAIT → CRITICAL" ''
mk; settcp "$FXP" 7 0 40; go;                                               chk 0 "socket counts are reported" 'tcp_established=7.*tcp_time_wait=40'

# ---------------- active probes ----------------------------------------------------------------------------------------------------------------
LP="$(mktemp)"; python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1],flush=True); s.listen(5); time.sleep(40)' > "$LP" & LPID=$!
CP="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
sleep 0.5; PORT="$(head -1 "$LP")"
mk; go --target "127.0.0.1:$PORT";                                           chk 0 "TCP connect to a live listener" "connect_ms_127_0_0_1_${PORT}="
mk; go --target "127.0.0.1:$CP";                                             chk 2 "TCP connect to a closed port → CRITICAL" 'unreachable'
mk; go --target "127.0.0.1:$PORT" --lat-warn 0 --lat-crit 100000;           chk 1 "latency warn threshold" 'slow connect'
mk; go --target "127.0.0.1:$PORT,127.0.0.1:$CP";                             chk 2 "comma list: one dead target is enough" 'unreachable'
mk; go --target 'a;b:80';                                                    chk 3 "shell-metacharacters in host rejected (no injection)" ''
mk; go --target '127.0.0.1:99999';                                           chk 3 "port out of range rejected" ''
mk; go --target '127.0.0.1';                                                 chk 3 "missing port rejected" ''
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null

mk; go --dns localhost;                                                      chk 0 "DNS resolves localhost" 'dns_ms_localhost='
mk; start=$SECONDS; go --dns nonexistent.invalid --dns-timeout 3;            chk 2 "unresolvable name → CRITICAL" 'cannot resolve nonexistent.invalid'
(( SECONDS - start < 15 )) && ok || bad "DNS probe must be bounded by its timeout"
mk; go --dns 'bad name;rm';                                                  chk 3 "bad DNS name rejected" ''

# TLS: unit-test the date maths, then an end-to-end probe if openssl exists
source "$ROOT/network_check.sh"; set +o errexit
d="$(cert_days_from_enddate 'notAfter=Jan  1 00:00:00 2099 GMT')"; (( d > 25000 )) && ok || bad "cert_days_from_enddate far future: $d"
d="$(cert_days_from_enddate 'notAfter=Jan  1 00:00:00 2000 GMT')"; (( d < 0 )) && ok || bad "expired cert must give negative days: $d"
if command -v openssl >/dev/null 2>&1; then
    CD="$(mktemp -d)"; openssl req -x509 -newkey rsa:2048 -nodes -keyout "$CD/k" -out "$CD/c" -days 3 -subj /CN=localhost >/dev/null 2>&1
    TP="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
    openssl s_server -accept "$TP" -cert "$CD/c" -key "$CD/k" -www -quiet >/dev/null 2>&1 & SPID=$!; sleep 1
    mk; go --tls "127.0.0.1:$TP";                                            chk 2 "cert expiring in ~3 days → CRITICAL" 'expires in [0-9]+d'
    mk; go --tls "127.0.0.1:$TP" --cert-warn 1: --cert-crit 0:;              chk 0 "…and OK with relaxed thresholds" 'cert_days_127_0_0_1_'
    kill "$SPID" 2>/dev/null; wait "$SPID" 2>/dev/null
    mk; go --tls "127.0.0.1:$CP";                                            chk 3 "unreadable cert → UNKNOWN" 'unreadable'
else printf 'SKIP: openssl not installed — end-to-end TLS probe not tested\n'; fi

# ---------------- formats & errors -------------------------------------------------------------------------------------------------------------------
mk; go -f json
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["check"]=="net" and d["status"]=="OK" and "tcp_established" in d["metrics"]' "$OUT" && ok || bad "json: $OUT"
mk; go -f prom; grep -q '^sysmon_net_tcp_established 5$' <<<"$OUT" && ok || bad "prom: $OUT"
fresh_state; SYSMON_PROC="$(mktemp -d)" SYSMON_SYS="$(mktemp -d)" bash "$ROOT/network_check.sh" >/dev/null 2>&1; (( $? == 3 )) && ok || bad "unreadable /proc & /sys → UNKNOWN"
fresh_state; bash "$ROOT/network_check.sh" --bogus >/dev/null 2>&1; (( $? == 3 )) && ok || bad "bad option → 3"
fresh_state; OUT="$(SYSMON_PROC="$FXP" SYSMON_SYS="$FXS" bash "$ROOT/network_check.sh" --interval 0 2>&1)"; RC=$?; chk 0 "--interval 0 skips rate metrics but still works" '^OK:'

# ---------------- smoke on the real machine ------------------------------------------------------------------------------------------------------------
fresh_state; OUT="$(unset SYSMON_PROC SYSMON_SYS; bash "$ROOT/network_check.sh" --interval 1 2>&1)"; RC=$?
(( RC <= 3 )) && grep -qE '^(OK|WARNING|CRITICAL|UNKNOWN): ' <<<"$OUT" && ok || bad "real system smoke (rc=$RC): $OUT"

printf '\nnetwork_check: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
