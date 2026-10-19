#!/usr/bin/env bash
#
# load_check.sh - Intermediate load average / CPU health check
#
# Interview talking points:
#   - Normalizes load average against nproc, since "load 4" means very
#     different things on a 4-core box vs a 32-core box.
#   - Deliberately also reads %iowait from /proc/stat, because the classic
#     interview trap is: high load average + low CPU usage = I/O bound,
#     not CPU bound. This script surfaces both numbers side by side so a
#     human (or on-call engineer) doesn't jump to the wrong conclusion.
#   - Counts D-state (uninterruptible sleep) processes directly, which is
#     the concrete evidence backing up an iowait-driven load spike.
#   - Uses two /proc/stat samples 1 second apart to compute instantaneous
#     CPU percentages, since /proc/stat's counters are cumulative since boot.

set -euo pipefail

WARN_RATIO="1.0"   # load / core count
CRIT_RATIO="2.0"

usage() {
    echo "Usage: $0 [-w warn_ratio] [-c crit_ratio]"
    exit 3
}

while getopts "w:c:h" opt; do
    case "$opt" in
        w) WARN_RATIO="$OPTARG" ;;
        c) CRIT_RATIO="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

nproc_count=$(nproc 2>/dev/null || echo 1)
read -r load1 load5 load15 _ < /proc/loadavg

# --- Sample /proc/stat twice, 1s apart, to get instantaneous CPU % ---
read_cpu_line() {
    awk '/^cpu / {print $2,$3,$4,$5,$6,$7,$8}' /proc/stat
}

read -r u1 n1 s1 i1 w1 irq1 sirq1 <<< "$(read_cpu_line)"
sleep 1
read -r u2 n2 s2 i2 w2 irq2 sirq2 <<< "$(read_cpu_line)"

total1=$(( u1+n1+s1+i1+w1+irq1+sirq1 ))
total2=$(( u2+n2+s2+i2+w2+irq2+sirq2 ))
totald=$(( total2 - total1 ))
idled=$(( i2 - i1 ))
iowaitd=$(( w2 - w1 ))

if (( totald <= 0 )); then
    cpu_used_pct=0
    iowait_pct=0
else
    cpu_used_pct=$(( 100 * (totald - idled) / totald ))
    iowait_pct=$(( 100 * iowaitd / totald ))
fi

# Count processes stuck in uninterruptible sleep (D state)
d_state_count=$(ps -eo stat= | grep -c '^D' || true)

# Compare load1 against core count using awk for floating point math
ratio=$(awk -v l="$load1" -v n="$nproc_count" 'BEGIN{printf "%.2f", l/n}')

status="OK"
exit_code=0

if awk -v r="$ratio" -v c="$CRIT_RATIO" 'BEGIN{exit !(r>=c)}'; then
    status="CRITICAL"
    exit_code=2
elif awk -v r="$ratio" -v w="$WARN_RATIO" 'BEGIN{exit !(r>=w)}'; then
    status="WARNING"
    exit_code=1
fi

# Escalate/annotate if this looks I/O-bound rather than CPU-bound
note=""
if (( exit_code > 0 )) && (( iowait_pct > 20 || d_state_count > 0 )); then
    note=" (likely I/O-bound: high iowait/D-state, not CPU contention)"
fi

echo "${status}: load1=${load1} cores=${nproc_count} load_per_core=${ratio} cpu_used=${cpu_used_pct}% iowait=${iowait_pct}% d_state_procs=${d_state_count}${note} | load_per_core=${ratio};${WARN_RATIO};${CRIT_RATIO} cpu_used_pct=${cpu_used_pct} iowait_pct=${iowait_pct} d_state=${d_state_count}"

exit "$exit_code"