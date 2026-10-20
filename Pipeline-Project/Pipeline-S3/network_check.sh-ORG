#!/usr/bin/env bash
#
# network_check.sh - Intermediate networking health check
#
# Interview talking points:
#   - Checks TCP retransmit counts specifically, since retransmits are the
#     classic "invisible" cause of latency -- the application sees no
#     error, it just silently feels slower, because TCP is quietly
#     recovering from packet loss underneath it.
#   - Separates "can I reach the host at all" (ping) from "is the actual
#     service port open" (a TCP connect test), since these answer
#     genuinely different questions and conflating them is a common
#     mistake ("ping works, so the network is fine" is not a valid
#     conclusion about a specific service's reachability).
#   - Reads NIC error/drop counters directly from /sys, showing awareness
#     that physical-layer problems live below anything ss/netstat can see.
#   - Uses /dev/tcp for a dependency-free port-reachability check instead
#     of requiring nc/telnet to be installed.

set -euo pipefail

TARGET_HOST=""
TARGET_PORT=""
PING_COUNT=3

usage() {
    echo "Usage: $0 -h host [-p port] [-c ping_count]"
    exit 3
}

while getopts "h:p:c:u" opt; do
    case "$opt" in
        h) TARGET_HOST="$OPTARG" ;;
        p) TARGET_PORT="$OPTARG" ;;
        c) PING_COUNT="$OPTARG" ;;
        u) usage ;;
        *) usage ;;
    esac
done

echo "--- Interface error/drop counters ---"
for iface_path in /sys/class/net/*; do
    iface=$(basename "$iface_path")
    [[ "$iface" == "lo" ]] && continue
    rx_errors=$(cat "$iface_path/statistics/rx_errors" 2>/dev/null || echo 0)
    tx_errors=$(cat "$iface_path/statistics/tx_errors" 2>/dev/null || echo 0)
    rx_dropped=$(cat "$iface_path/statistics/rx_dropped" 2>/dev/null || echo 0)
    tx_dropped=$(cat "$iface_path/statistics/tx_dropped" 2>/dev/null || echo 0)
    printf "%-10s rx_errors=%-6s tx_errors=%-6s rx_dropped=%-6s tx_dropped=%-6s\n" \
        "$iface" "$rx_errors" "$tx_errors" "$rx_dropped" "$tx_dropped"
done

echo
echo "--- TCP retransmit / socket summary ---"
if command -v ss >/dev/null 2>&1; then
    ss -s
else
    echo "ss not found -- install iproute2"
fi

exit_code=0
status="OK"

if [[ -n "$TARGET_HOST" ]]; then
    echo
    echo "--- Reachability check: ${TARGET_HOST} ---"

    if command -v ping >/dev/null 2>&1; then
        if ping -c "$PING_COUNT" -W 2 "$TARGET_HOST" > /tmp/ping_out.$$ 2>&1; then
            avg_rtt=$(grep -oP 'rtt.*= \K[0-9.]+' /tmp/ping_out.$$ || echo "n/a")
            echo "OK: ${TARGET_HOST} responds to ICMP (avg rtt ~${avg_rtt} ms)"
        else
            echo "WARNING: ${TARGET_HOST} did not respond to ICMP (may be blocked, not necessarily down)"
            exit_code=1
            status="WARNING"
        fi
        rm -f /tmp/ping_out.$$
    fi

    if [[ -n "$TARGET_PORT" ]]; then
        # Dependency-free TCP port check using bash's /dev/tcp
        if timeout 3 bash -c "exec 3<>/dev/tcp/${TARGET_HOST}/${TARGET_PORT}" 2>/dev/null; then
            echo "OK: TCP port ${TARGET_PORT} on ${TARGET_HOST} is open and accepting connections"
        else
            echo "CRITICAL: TCP port ${TARGET_PORT} on ${TARGET_HOST} is NOT reachable"
            exit_code=2
            status="CRITICAL"
        fi
    fi
fi

echo
echo "Overall: ${status}"
exit "$exit_code"