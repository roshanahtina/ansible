#!/usr/bin/env bash
# ============================================================================
# network_check.sh — senior-level network health check
#
#   * RATES over a sample window, never lifetime counters (an interface with 4 million errors since 2019 is fine
#     if it has none now; one gaining 50/second is an incident)
#   * TCP retransmit % = Δ RetransSegs / Δ OutSegs  — the "invisible latency" signal: apps see no error, just slowness
#   * Listen-queue overflows/drops (accept queue full = the application is too slow to accept() — not a network fault)
#   * conntrack table utilisation (full table = silently dropped packets, a classic NAT/firewall outage)
#   * CLOSE_WAIT build-up (the APPLICATION is not closing sockets: a leak, not a network problem)
#   * Link flapping via carrier_changes, half-duplex detection, link speed
#   * Active probes, each bounded by timeout: TCP connect latency, DNS resolution time, TLS certificate expiry
#   * Reads /proc/net/tcp directly — no dependency on ss/netstat
# ============================================================================
SCRIPT_NAME="network_check"; CHECK_NAME="net"
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

ERR_WARN=1; ERR_CRIT=10                  # errors+drops per second, per interface
RETR_WARN=1; RETR_CRIT=5; MIN_SEGS=100   # retransmit % (evaluated only if at least MIN_SEGS were sent in the window)
LISTEN_WARN=0; LISTEN_CRIT=100           # listen overflows+drops in the window
CT_WARN=70; CT_CRIT=90                   # conntrack %
CW_WARN=100; CW_CRIT=1000                # CLOSE_WAIT sockets
LAT_WARN=200; LAT_CRIT=1000              # ms
DNS_WARN=200; DNS_CRIT=1000              # ms
CERT_WARN="21:"; CERT_CRIT="7:"          # days left ("less than" ranges)
CONNECT_TIMEOUT=3; DNS_TIMEOUT=3; INTERVAL=2; CONFIRM=1
EXCL_IF='^(lo|veth.*|docker.*|br-.*|virbr.*|cali.*|flannel.*|cni.*|tun.*|tap.*|kube.*)$'; INCL_IF=""
REQUIRE_UP=""; TARGETS=""; DNS_NAMES=""; TLS_TARGETS=""

usage() { cat <<'EOF'
Usage: network_check.sh [options]
      --err-warn/--err-crit RANGE       errors+drops per second per interface        [1 / 10]
      --retrans-warn/--retrans-crit RANGE  TCP retransmit % in the window              [1 / 5]
      --listen-warn/--listen-crit RANGE    listen-queue overflows+drops in the window  [0 / 100]
      --conntrack-warn/--conntrack-crit RANGE  conntrack table %                       [70 / 90]
      --closewait-warn/--closewait-crit RANGE  sockets stuck in CLOSE_WAIT             [100 / 1000]
      --lat-warn/--lat-crit RANGE          TCP connect latency, ms                     [200 / 1000]
      --dns-warn/--dns-crit RANGE          DNS resolution time, ms                     [200 / 1000]
      --cert-warn/--cert-crit RANGE        TLS cert days left                          [21: / 7:]
      --target HOST:PORT[,..]              TCP connect probe(s)
      --dns NAME[,..]                      DNS resolution probe(s)
      --tls HOST:PORT[,..]                 TLS certificate expiry probe(s) (needs openssl)
      --require-up IF[,..]                 interfaces that MUST be up (CRITICAL otherwise)
      --iface-exclude RE / --iface-regex RE  interface filters
      --connect-timeout S / --dns-timeout S  probe timeouts                            [3 / 3]
      --interval SECS                      sample window for rates (0 = skip)          [2]
      --confirm N                          CRITICAL only after N consecutive runs      [1]
  -f, --format FMT                         nagios | json | prom
  -d, --debug   -h, --help
Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
EOF
}
parse_args() {
    local parsed
    parsed="$(getopt -o 'f:dh' -l 'err-warn:,err-crit:,retrans-warn:,retrans-crit:,listen-warn:,listen-crit:,conntrack-warn:,conntrack-crit:,closewait-warn:,closewait-crit:,lat-warn:,lat-crit:,dns-warn:,dns-crit:,cert-warn:,cert-crit:,target:,dns:,tls:,require-up:,iface-exclude:,iface-regex:,connect-timeout:,dns-timeout:,interval:,confirm:,format:,debug,help' \
              -n "$SCRIPT_NAME" -- "$@")" || { usage >&2; exit "$EXIT_UNKNOWN"; }
    eval set -- "$parsed"
    while true; do
        case "$1" in
            --err-warn) ERR_WARN="$2"; shift 2 ;;       --err-crit) ERR_CRIT="$2"; shift 2 ;;
            --retrans-warn) RETR_WARN="$2"; shift 2 ;;  --retrans-crit) RETR_CRIT="$2"; shift 2 ;;
            --listen-warn) LISTEN_WARN="$2"; shift 2 ;; --listen-crit) LISTEN_CRIT="$2"; shift 2 ;;
            --conntrack-warn) CT_WARN="$2"; shift 2 ;;  --conntrack-crit) CT_CRIT="$2"; shift 2 ;;
            --closewait-warn) CW_WARN="$2"; shift 2 ;;  --closewait-crit) CW_CRIT="$2"; shift 2 ;;
            --lat-warn) LAT_WARN="$2"; shift 2 ;;       --lat-crit) LAT_CRIT="$2"; shift 2 ;;
            --dns-warn) DNS_WARN="$2"; shift 2 ;;       --dns-crit) DNS_CRIT="$2"; shift 2 ;;
            --cert-warn) CERT_WARN="$2"; shift 2 ;;     --cert-crit) CERT_CRIT="$2"; shift 2 ;;
            --target) TARGETS="${TARGETS:+$TARGETS,}$2"; shift 2 ;;
            --dns) DNS_NAMES="${DNS_NAMES:+$DNS_NAMES,}$2"; shift 2 ;;
            --tls) TLS_TARGETS="${TLS_TARGETS:+$TLS_TARGETS,}$2"; shift 2 ;;
            --require-up) REQUIRE_UP="$2"; shift 2 ;;   --iface-exclude) EXCL_IF="$2"; shift 2 ;;
            --iface-regex) INCL_IF="$2"; shift 2 ;;     --connect-timeout) CONNECT_TIMEOUT="$2"; shift 2 ;;
            --dns-timeout) DNS_TIMEOUT="$2"; shift 2 ;; --interval) INTERVAL="$2"; shift 2 ;;
            --confirm) CONFIRM="$2"; shift 2 ;;         -f|--format) OUTPUT_FORMAT="$2"; shift 2 ;;
            -d|--debug) LOG_LEVEL=debug; shift ;;       -h|--help) usage; exit 0 ;;
            --) shift; break ;;                         *) die "internal option parsing error" ;;
        esac
    done
    [[ "$CONNECT_TIMEOUT" =~ ^[0-9]+$ && "$DNS_TIMEOUT" =~ ^[0-9]+$ && "$INTERVAL" =~ ^[0-9]+$ && "$CONFIRM" =~ ^[0-9]+$ ]] || die "timeouts/--interval/--confirm must be integers"
}

now_precise() { if [[ -n "${EPOCHREALTIME:-}" ]]; then printf '%s' "$EPOCHREALTIME"; else date +%s.%N; fi; }
ms_since() { awk -v a="$1" -v b="$(now_precise)" 'BEGIN{printf "%.1f", (b-a)*1000}'; }
valid_host() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }                     # whitelist — hosts are passed to probes
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
mlabel() { local n="${1//[^A-Za-z0-9]/_}"; printf '%s' "$n"; }

iface_snapshot() {  # one line per interface: name rx_err tx_err rx_drop tx_drop rx_bytes tx_bytes carrier_changes oper speed duplex
    local d n
    for d in "$SYS"/class/net/*; do
        [[ -d "$d" ]] || continue; n="${d##*/}"
        [[ "$n" =~ $EXCL_IF ]] && continue
        if [[ -n "$INCL_IF" && ! "$n" =~ $INCL_IF ]]; then continue; fi
        printf '%s %s %s %s %s %s %s %s %s %s %s\n' "$n" \
            "$(slurp "$d/statistics/rx_errors" 0)" "$(slurp "$d/statistics/tx_errors" 0)" \
            "$(slurp "$d/statistics/rx_dropped" 0)" "$(slurp "$d/statistics/tx_dropped" 0)" \
            "$(slurp "$d/statistics/rx_bytes" 0)" "$(slurp "$d/statistics/tx_bytes" 0)" \
            "$(slurp "$d/carrier_changes" 0)" "$(slurp "$d/operstate" unknown)" "$(slurp "$d/speed" -1)" "$(slurp "$d/duplex" unknown)"
    done
}
iface_rates() {  # iface_rates SNAP1 SNAP2 ELAPSED → "name err_per_s mbps flaps oper speed duplex"
    awk -v el="$3" 'NR==FNR { e[$1]=$2+$3+$4+$5; b[$1]=$6+$7; c[$1]=$8; next }
        ($1 in e) { er=($2+$3+$4+$5)-e[$1]; if (er<0) er=0; by=($6+$7)-b[$1]; if (by<0) by=0; fl=$8-c[$1]; if (fl<0) fl=0
                    printf "%s %.2f %.2f %d %s %s %s\n", $1, er/el, by*8/el/1000000, fl, $9, $10, $11 }' "$1" "$2"
}
connect_ms() {  # connect_ms HOST PORT → prints latency in ms; rc 1 if the connection failed or timed out
    local t0; t0="$(now_precise)"
    with_timeout "$CONNECT_TIMEOUT" bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$1" "$2" 2>/dev/null || return 1
    ms_since "$t0"
}
dns_ms() {  # dns_ms NAME → prints resolution time in ms; rc 1 on failure
    local t0; t0="$(now_precise)"
    with_timeout "$DNS_TIMEOUT" getent ahosts "$1" >/dev/null 2>&1 || return 1
    ms_since "$t0"
}
cert_days_from_enddate() {  # "notAfter=Jan  1 00:00:00 2099 GMT" → days left
    local e="${1#notAfter=}" ts
    ts="$(date -d "$e" +%s 2>/dev/null)" || return 1
    printf '%d' $(( (ts - $(now_epoch)) / 86400 ))
}
cert_days() {  # cert_days HOST PORT
    local end
    end="$(echo | with_timeout "$CONNECT_TIMEOUT" openssl s_client -connect "$1:$2" -servername "$1" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null)" || return 1
    [[ -n "$end" ]] || return 1
    cert_days_from_enddate "$end"
}
bump_h() { apply_hysteresis "$2" "net.$1" "$CONFIRM"; bump_status "$HYST_STATUS"; }

main() {
    parse_args "$@"
    [[ -d "$PROC/net" || -d "$SYS/class/net" ]] || { OVERALL_STATUS=3; summary "cannot read $PROC/net or $SYS/class/net"; finish; }
    local td s; td="$(tmpdir)"

    # ---- 1. take the first sample --------------------------------------------------------------------------------
    local rt1 ot1 lo1 ld1 t1; t1="$(now_precise)"
    iface_snapshot > "$td/if1"
    rt1="$(proc_net_get "$PROC/net/snmp" Tcp RetransSegs 2>/dev/null || true)"; ot1="$(proc_net_get "$PROC/net/snmp" Tcp OutSegs 2>/dev/null || true)"
    lo1="$(proc_net_get "$PROC/net/netstat" TcpExt ListenOverflows 2>/dev/null || true)"; ld1="$(proc_net_get "$PROC/net/netstat" TcpExt ListenDrops 2>/dev/null || true)"
    if (( INTERVAL > 0 )); then sleep "$INTERVAL"; fi
    local rt2 ot2 lo2 ld2 el
    iface_snapshot > "$td/if2"
    rt2="$(proc_net_get "$PROC/net/snmp" Tcp RetransSegs 2>/dev/null || true)"; ot2="$(proc_net_get "$PROC/net/snmp" Tcp OutSegs 2>/dev/null || true)"
    lo2="$(proc_net_get "$PROC/net/netstat" TcpExt ListenOverflows 2>/dev/null || true)"; ld2="$(proc_net_get "$PROC/net/netstat" TcpExt ListenDrops 2>/dev/null || true)"
    el="$(ms_since "$t1")"; el="$(awk -v ms="$el" 'BEGIN{ if (ms<1) ms=1; printf "%.3f", ms/1000 }')"

    # ---- 2. interfaces: error/drop RATES, throughput, flaps, duplex, required-up -----------------------------------
    local n er mbps flaps oper speed duplex nif=0 worst_er=0 worst_if="" st
    if (( INTERVAL > 0 )); then
        while read -r n er mbps flaps oper speed duplex; do
            [[ -n "$n" ]] || continue; nif=$((nif + 1)); local m; m="$(mlabel "$n")"
            perf "err_per_s_${m}" "$er" "" "$ERR_WARN" "$ERR_CRIT"; perf "mbps_${m}" "$mbps" Mbps
            st="$(classify "$er" "$ERR_WARN" "$ERR_CRIT")"; bump_h "err.$m" "$st"
            if (( st > 0 )); then summary "${n}: ${er} errors+drops/s${HYST_NOTE}"; detail "$(status_label "$HYST_STATUS") interface ${n}: ${er} errors+drops per second (check ethtool -S ${n}: CRC/frame errors = cable/optic/duplex; drops = ring buffer/CPU)"; fi
            if fcmp "$er" gt "$worst_er"; then worst_er="$er"; worst_if="$n"; fi
            if (( flaps > 0 )); then bump_status 1; summary "${n}: link flapped ${flaps}x"; detail "WARNING interface ${n}: carrier changed ${flaps} time(s) in the window — bad cable/optic/switch port"; fi
            if [[ "$duplex" == half ]] && [[ "$speed" =~ ^[0-9]+$ ]] && (( speed > 0 )); then bump_status 1; summary "${n}: HALF duplex"; detail "WARNING interface ${n} negotiated half duplex at ${speed} Mb/s — duplex mismatch (expect late collisions/CRC errors)"; fi
            if [[ "$speed" =~ ^[0-9]+$ ]] && (( speed > 0 )); then perf "speed_mbps_${m}" "$speed" Mbps; fi
        done < <(iface_rates "$td/if1" "$td/if2" "$el")
        perf worst_err_per_s "$worst_er" "" "$ERR_WARN" "$ERR_CRIT"
    fi
    if [[ -n "$REQUIRE_UP" ]]; then
        local want; local -a ups; IFS=',' read -ra ups <<<"$REQUIRE_UP"
        for want in "${ups[@]}"; do
            oper="$(slurp "$SYS/class/net/$want/operstate" missing)"
            if [[ "$oper" != up ]]; then bump_status 2; summary "${want} is ${oper}"; detail "CRITICAL required interface ${want}: operstate=${oper}"; fi
            perf "up_$(mlabel "$want")" "$([[ "$oper" == up ]] && echo 1 || echo 0)"
        done
    fi
    summary "${nif} interface(s) sampled"

    # ---- 3. TCP retransmit % -----------------------------------------------------------------------------------------------
    if [[ -n "$rt1" && -n "$rt2" && -n "$ot1" && -n "$ot2" ]] && (( INTERVAL > 0 )); then
        local dret=$(( rt2 - rt1 )) dout=$(( ot2 - ot1 )) rp
        if (( dret < 0 || dout < 0 )); then dret=0; dout=0; fi
        perf tcp_out_segs "$dout" c; perf tcp_retrans_segs "$dret" c
        if (( dout >= MIN_SEGS )); then
            rp="$(pct "$dret" "$dout")"; perf tcp_retrans_pct "$rp" % "$RETR_WARN" "$RETR_CRIT"
            st="$(classify "$rp" "$RETR_WARN" "$RETR_CRIT")"; bump_h retrans "$st"
            if (( st > 0 )); then summary "TCP retransmits ${rp}%${HYST_NOTE}"; detail "$(status_label "$HYST_STATUS") ${dret} of ${dout} segments retransmitted (${rp}%) — packet loss/congestion upstream: run mtr to the peer, check ethtool -S, switch ports"; fi
        else log debug "only ${dout} segments sent in the window (< ${MIN_SEGS}); retransmit % not evaluated"; fi
    fi
    # ---- 4. listen queue overflow/drops (the APP is not accepting fast enough) ---------------------------------------------
    if [[ -n "$lo1" && -n "$lo2" && -n "$ld1" && -n "$ld2" ]] && (( INTERVAL > 0 )); then
        local dl=$(( (lo2 - lo1) + (ld2 - ld1) )); if (( dl < 0 )); then dl=0; fi
        perf listen_drops "$dl" c "$LISTEN_WARN" "$LISTEN_CRIT"
        st="$(classify "$dl" "$LISTEN_WARN" "$LISTEN_CRIT")"; bump_status "$st"
        if (( st > 0 )); then summary "${dl} listen-queue drops"; detail "$(status_label "$st") ${dl} connections dropped because an accept queue was full — raise backlog/somaxconn, or the application is too slow to accept() (this is NOT a network fault)"; fi
    fi

    # ---- 5. conntrack ---------------------------------------------------------------------------------------------------------
    local ctc ctm
    ctc="$(slurp "$PROC/sys/net/netfilter/nf_conntrack_count" "")"; ctm="$(slurp "$PROC/sys/net/netfilter/nf_conntrack_max" "")"
    if [[ "$ctc" =~ ^[0-9]+$ && "$ctm" =~ ^[0-9]+$ ]] && (( ctm > 0 )); then
        local cp; cp="$(pct "$ctc" "$ctm")"; perf conntrack_pct "$cp" % "$CT_WARN" "$CT_CRIT"
        st="$(classify "$cp" "$CT_WARN" "$CT_CRIT")"; bump_h conntrack "$st"
        if (( st > 0 )); then summary "conntrack ${cp}% (${ctc}/${ctm})${HYST_NOTE}"; detail "$(status_label "$HYST_STATUS") conntrack table ${cp}% full — at 100% the kernel silently drops NEW connections ('nf_conntrack: table full, dropping packet' in dmesg); raise nf_conntrack_max or shorten timeouts"; fi
    fi

    # ---- 6. socket states (straight from /proc/net/tcp) ----------------------------------------------------------------------
    if [[ -r "$PROC/net/tcp" ]]; then
        local kv; declare -A SC=()
        for kv in $(tcp_state_counts); do SC["${kv%%=*}"]="${kv##*=}"; done
        perf tcp_established "${SC[ESTAB]:-0}"; perf tcp_time_wait "${SC[TIME_WAIT]:-0}"; perf tcp_listen "${SC[LISTEN]:-0}"
        perf tcp_close_wait "${SC[CLOSE_WAIT]:-0}" "" "$CW_WARN" "$CW_CRIT"; perf tcp_syn_recv "${SC[SYN_RECV]:-0}"
        st="$(classify "${SC[CLOSE_WAIT]:-0}" "$CW_WARN" "$CW_CRIT")"; bump_status "$st"
        if (( st > 0 )); then summary "${SC[CLOSE_WAIT]} sockets in CLOSE_WAIT"; detail "$(status_label "$st") ${SC[CLOSE_WAIT]} CLOSE_WAIT sockets — the remote side closed but the LOCAL APPLICATION never called close(): a socket/fd leak in the app (find it: lsof -iTCP -sTCP:CLOSE_WAIT)"; fi
    fi

    # ---- 7. active probes (each bounded by a timeout) ---------------------------------------------------------------------------
    local item host port ms l
    local -a arr
    if [[ -n "$TARGETS" ]]; then
        IFS=',' read -ra arr <<<"$TARGETS"
        for item in "${arr[@]}"; do
            host="${item%:*}"; port="${item##*:}"
            valid_host "$host" && valid_port "$port" || die "invalid --target '$item' (want HOST:PORT)"
            l="$(mlabel "$host")_$port"
            if ms="$(connect_ms "$host" "$port")"; then
                perf "connect_ms_${l}" "$ms" ms "$LAT_WARN" "$LAT_CRIT"
                st="$(classify "$ms" "$LAT_WARN" "$LAT_CRIT")"; bump_status "$st"
                if (( st > 0 )); then summary "${host}:${port} slow connect ${ms} ms"; detail "$(status_label "$st") TCP connect to ${host}:${port} took ${ms} ms"; fi
            else bump_status 2; summary "${host}:${port} unreachable"; detail "CRITICAL cannot connect to ${host}:${port} within ${CONNECT_TIMEOUT}s (refused, filtered or no route)"; perf "connect_ms_${l}" -1 ms; fi
        done
    fi
    if [[ -n "$DNS_NAMES" ]]; then
        IFS=',' read -ra arr <<<"$DNS_NAMES"
        for item in "${arr[@]}"; do
            valid_host "$item" || die "invalid --dns name '$item'"
            l="$(mlabel "$item")"
            if ms="$(dns_ms "$item")"; then
                perf "dns_ms_${l}" "$ms" ms "$DNS_WARN" "$DNS_CRIT"
                st="$(classify "$ms" "$DNS_WARN" "$DNS_CRIT")"; bump_status "$st"
                if (( st > 0 )); then summary "DNS ${item} ${ms} ms"; detail "$(status_label "$st") resolving ${item} took ${ms} ms — slow resolver adds this delay to EVERY new connection (check /etc/resolv.conf, ndots, search domains)"; fi
            else bump_status 2; summary "DNS ${item} failed"; detail "CRITICAL cannot resolve ${item} within ${DNS_TIMEOUT}s"; perf "dns_ms_${l}" -1 ms; fi
        done
    fi
    if [[ -n "$TLS_TARGETS" ]]; then
        if have openssl; then
            IFS=',' read -ra arr <<<"$TLS_TARGETS"
            for item in "${arr[@]}"; do
                host="${item%:*}"; port="${item##*:}"
                valid_host "$host" && valid_port "$port" || die "invalid --tls '$item'"
                l="$(mlabel "$host")_$port"
                if ms="$(cert_days "$host" "$port")"; then
                    perf "cert_days_${l}" "$ms" d "$CERT_WARN" "$CERT_CRIT"
                    st="$(classify "$ms" "$CERT_WARN" "$CERT_CRIT")"; bump_status "$st"
                    if (( st > 0 )); then summary "cert ${host}:${port} expires in ${ms}d"; detail "$(status_label "$st") TLS certificate for ${host}:${port} expires in ${ms} day(s)"; fi
                else bump_status 3; detail "UNKNOWN could not read the TLS certificate from ${host}:${port}"; summary "cert ${host}:${port} unreadable"; fi
            done
        else log warn "--tls requested but openssl not installed — skipped"; fi
    fi
    finish
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
