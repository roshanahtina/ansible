#!/usr/bin/env bash
#
# disk_check.sh - Intermediate disk space, inode & I/O latency check
#
# Interview talking points:
#   - Checks BOTH space (%) and inodes (%) per filesystem, since "no space
#     left on device" with df -h showing free space is the classic
#     inode-exhaustion trap.
#   - Excludes pseudo/virtual filesystems (tmpfs, overlay, proc, etc.) so
#     the output isn't cluttered with irrelevant noise -- shows awareness
#     of the real vs virtual filesystem distinction.
#   - Optionally shells out to iostat (if installed) to surface await/%util
#     per physical device, connecting "the disk is full" checks with
#     "the disk is slow" checks in one script, which is exactly the kind
#     of holistic view an interviewer wants to see you reach for.
#   - Uses a real (not string-matched) exclusion list for filesystem types,
#     easy to extend.

set -euo pipefail

SPACE_WARN_PCT=80
SPACE_CRIT_PCT=90
INODE_WARN_PCT=80
INODE_CRIT_PCT=90

usage() {
    echo "Usage: $0 [-w space_warn_pct] [-c space_crit_pct] [-i inode_warn_pct] [-I inode_crit_pct]"
    exit 3
}

while getopts "w:c:i:I:h" opt; do
    case "$opt" in
        w) SPACE_WARN_PCT="$OPTARG" ;;
        c) SPACE_CRIT_PCT="$OPTARG" ;;
        i) INODE_WARN_PCT="$OPTARG" ;;
        I) INODE_CRIT_PCT="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done

EXCLUDE_FSTYPES="tmpfs|devtmpfs|overlay|squashfs|proc|sysfs|cgroup|cgroup2|devpts|mqueue|tracefs|debugfs"

worst_exit=0
echo "--- Filesystem space & inode usage ---"

# Read df output (POSIX format for stable column parsing), skip header
while read -r fs fstype size used avail pct_space mount; do
    [[ "$fs" == "Filesystem" ]] && continue
    [[ "$fstype" =~ ^($EXCLUDE_FSTYPES)$ ]] && continue

    space_pct=${pct_space%\%}

    # Grab matching inode line for this mount point
    inode_line=$(df -iP "$mount" 2>/dev/null | awk 'NR==2 {print $5}')
    inode_pct=${inode_line%\%}
    inode_pct=${inode_pct:-0}

    status="OK"
    ec=0
    if (( space_pct >= SPACE_CRIT_PCT )) || (( inode_pct >= INODE_CRIT_PCT )); then
        status="CRITICAL"; ec=2
    elif (( space_pct >= SPACE_WARN_PCT )) || (( inode_pct >= INODE_WARN_PCT )); then
        status="WARNING"; ec=1
    fi

    (( ec > worst_exit )) && worst_exit=$ec

    printf "%-8s %-20s space=%3d%% inodes=%3d%% mount=%s\n" "$status" "$fstype" "$space_pct" "$inode_pct" "$mount"
done < <(df -TP)

echo
echo "--- Disk I/O latency (iostat -x, 1 sample) ---"
if command -v iostat >/dev/null 2>&1; then
    # -x extended stats, skip the first (boot-average) report with -y equivalent via tail
    iostat -x 1 2 | awk '
        /^Device/ {header_seen++; if (header_seen==2) show=1; next}
        show && NF {print}
    '
else
    echo "iostat not installed (package: sysstat) - skipping I/O latency check"
fi

echo
if (( worst_exit == 2 )); then
    echo "Overall: CRITICAL"
elif (( worst_exit == 1 )); then
    echo "Overall: WARNING"
else
    echo "Overall: OK"
fi

exit "$worst_exit"