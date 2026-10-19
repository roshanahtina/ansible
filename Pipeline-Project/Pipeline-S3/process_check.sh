#!/usr/bin/env bash
#
# process_check.sh - Intermediate process health check
#
# Interview talking points:
#   - Distinguishes zombie count from D-state count, since they point at
#     completely different root causes (zombie -> parent not reaping;
#     D-state -> storage/NFS I/O stuck) even though both look "weird" in
#     a process listing to a junior engineer.
#   - Surfaces top CPU and top memory consumers separately, since the
#     worst offender for each is often a different process.
#   - Accepts an optional process-name pattern so the same script can be
#     reused as a generic "is <thing> healthy" check, not just a one-off.
#   - Deliberately avoids parsing `ps aux` with fragile column-position
#     assumptions; uses `ps -eo` with explicit fields instead, which is
#     the more robust/portable approach worth calling out.

set -euo pipefail

TOP_N=5
WATCH_PATTERN=""

usage() {
    echo "Usage: $0 [-n top_n] [-p process_name_pattern]"
    exit 3
}

while getopts "n:p:h" opt; do
    case "$opt" in
        n) TOP_N="$OPTARG" ;;
        p) WATCH_PATTERN="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

echo "--- Top ${TOP_N} processes by CPU ---"
ps -eo pid,ppid,user,%cpu,%mem,stat,etime,comm --sort=-%cpu | head -n $((TOP_N + 1))

echo
echo "--- Top ${TOP_N} processes by memory (RSS) ---"
ps -eo pid,ppid,user,%cpu,%mem,stat,etime,comm --sort=-%mem | head -n $((TOP_N + 1))

echo
zombie_count=$(ps -eo stat= | grep -c '^Z' || true)
dstate_count=$(ps -eo stat= | grep -c '^D' || true)
total_procs=$(ps -e --no-headers | wc -l)

echo "--- Process state summary ---"
echo "total_processes=${total_procs} zombies=${zombie_count} d_state=${dstate_count}"

status="OK"
exit_code=0

if (( zombie_count > 10 )); then
    status="WARNING"
    exit_code=1
    echo "NOTE: high zombie count usually means a specific PARENT process is not reaping children -- check ps -eo pid,ppid,stat,comm | awk '\$3 ~ /^Z/ {print \$2}' to find the common parent PID."
fi

if (( dstate_count > 0 )); then
    status="WARNING"
    exit_code=1
    echo "NOTE: D-state processes present -- these are blocked on uninterruptible I/O (disk/NFS), cannot be killed with SIGKILL. Check iostat -x and NFS mount health, not the process itself."
fi

# Optional: watch a specific process pattern (e.g. a critical daemon)
if [[ -n "$WATCH_PATTERN" ]]; then
    echo
    echo "--- Watching pattern: ${WATCH_PATTERN} ---"
    match_count=$(pgrep -c -f "$WATCH_PATTERN" || true)
    if (( match_count == 0 )); then
        echo "CRITICAL: no running process matches '${WATCH_PATTERN}'"
        exit_code=2
        status="CRITICAL"
    else
        echo "OK: ${match_count} matching process(es) running"
        pgrep -a -f "$WATCH_PATTERN"
    fi
fi

echo
echo "Overall: ${status}"
exit "$exit_code"