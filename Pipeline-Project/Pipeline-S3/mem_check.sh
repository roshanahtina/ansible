#!/usr/bin/env bash
#
# mem_check.sh - Intermediate memory health check
#
# Interview talking points:
#   - Uses MemAvailable (not MemFree) as the real "healthy" signal, since
#     Linux deliberately uses spare RAM for page cache.
#   - Nagios-style exit codes (0=OK,1=WARNING,2=CRITICAL,3=UNKNOWN) so this
#     script could be dropped straight into Nagios/Icinga as a plugin.
#   - Also checks swap usage and scans dmesg for recent OOM Killer events,
#     since "memory is fine right now" can hide "memory was fine only
#     because something just got OOM-killed 30 seconds ago."
#   - Parses /proc/meminfo directly instead of scraping `free` output,
#     which is more robust to locale/version differences in free's format.

set -euo pipefail

WARN_PCT=80
CRIT_PCT=90
SWAP_WARN_PCT=50

usage() {
    echo "Usage: $0 [-w warn_pct] [-c crit_pct] [-s swap_warn_pct]"
    exit 3
}

while getopts "w:c:s:h" opt; do
    case "$opt" in
        w) WARN_PCT="$OPTARG" ;;
        c) CRIT_PCT="$OPTARG" ;;
        s) SWAP_WARN_PCT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ ! -r /proc/meminfo ]]; then
    echo "UNKNOWN: cannot read /proc/meminfo"
    exit 3
fi

# Pull the exact fields we need out of /proc/meminfo (values are in kB)
get_kb() {
    awk -v key="$1:" '$1 == key {print $2}' /proc/meminfo
}

mem_total_kb=$(get_kb "MemTotal")
mem_avail_kb=$(get_kb "MemAvailable")
swap_total_kb=$(get_kb "SwapTotal")
swap_free_kb=$(get_kb "SwapFree")

if [[ -z "$mem_total_kb" || -z "$mem_avail_kb" ]]; then
    echo "UNKNOWN: could not parse MemTotal/MemAvailable"
    exit 3
fi

mem_used_kb=$(( mem_total_kb - mem_avail_kb ))
mem_used_pct=$(( 100 * mem_used_kb / mem_total_kb ))

swap_used_pct=0
if [[ -n "$swap_total_kb" && "$swap_total_kb" -gt 0 ]]; then
    swap_used_kb=$(( swap_total_kb - swap_free_kb ))
    swap_used_pct=$(( 100 * swap_used_kb / swap_total_kb ))
fi

# Check for recent OOM Killer activity (last ~200 kernel log lines)
oom_hits=0
if command -v dmesg >/dev/null 2>&1; then
    oom_hits=$(dmesg 2>/dev/null | tail -n 200 | grep -ci "out of memory\|oom-kill" || true)
fi

status="OK"
exit_code=0

if (( mem_used_pct >= CRIT_PCT )); then
    status="CRITICAL"
    exit_code=2
elif (( mem_used_pct >= WARN_PCT )); then
    status="WARNING"
    exit_code=1
fi

if (( swap_used_pct >= SWAP_WARN_PCT )) && (( exit_code < 1 )); then
    status="WARNING"
    exit_code=1
fi

if (( oom_hits > 0 )) && (( exit_code < 2 )); then
    status="CRITICAL"
    exit_code=2
fi

echo "${status}: memory used=${mem_used_pct}% swap used=${swap_used_pct}% oom_events_recent=${oom_hits} | mem_used_pct=${mem_used_pct};${WARN_PCT};${CRIT_PCT} swap_used_pct=${swap_used_pct}"

exit "$exit_code"