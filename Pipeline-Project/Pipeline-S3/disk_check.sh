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

# disk_check.sh - Disk space, inode & I/O latency check
#
# Output ends with "Overall: OK|WARNING|CRITICAL"
# Exit codes: 0=OK, 1=WARNING, 2=CRITICAL, 3=usage error

set -euo pipefail
export LC_ALL=C

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

    space_raw=${pct_space%\%}
    inode_raw=$(df -iP "$mount" 2>/dev/null | awk 'NR==2 {print $5}')
    inode_raw=${inode_raw%\%}

    # df prints "-" when a filesystem has no usage/inode data.
    # Use 0 for the comparisons and "n/a" for display.
    if is_num "$space_raw"; then space_pct=$space_raw; space_disp=$space_raw
    else space_pct=0; space_disp="n/a"; fi

    if is_num "$inode_raw"; then inode_pct=$inode_raw; inode_disp=$inode_raw
    else inode_pct=0; inode_disp="n/a"; fi

    status="OK"
    ec=0
    if (( space_pct >= SPACE_CRIT_PCT )) || (( inode_pct >= INODE_CRIT_PCT )); then
        status="CRITICAL"; ec=2
    elif (( space_pct >= SPACE_WARN_PCT )) || (( inode_pct >= INODE_WARN_PCT )); then
        status="WARNING"; ec=1
    fi

    if (( ec > worst_exit )); then worst_exit=$ec; fi

    printf "%-8s %-8s space=%4s%% inodes=%4s%% mount=%s\n" \
        "$status" "$fstype" "$space_disp" "$inode_disp" "$mount"
done < <(df -TP)

echo
echo "--- Disk I/O latency (iostat -dx, live sample) ---"
if command -v iostat >/dev/null 2>&1; then
    # 2 samples: the first is the since-boot average, so print only the second.
    # Columns are located by header name, so it works across sysstat versions.
    iostat -dx 1 2 | awk '
        /^Device/ {
            seen++
            for (k in col) delete col[k]
            for (i=1; i<=NF; i++) col[$i]=i
            next
        }
        seen==2 && NF && $1 !~ /^(dm-|loop)/ {
            rw = ("r_await" in col) ? $(col["r_await"]) : $(col["await"])
            ww = ("w_await" in col) ? $(col["w_await"]) : $(col["await"])
            printf "%-10s r_await=%-7s w_await=%-7s util=%s%%\n", $1, rw, ww, $(col["%util"])
        }'
else
    echo "iostat not installed (package: sysstat) - skipping I/O latency check"
fi

echo
# if (( worst_exit == 2 )); then
#     echo "Overall: CRITICAL"
# elif (( worst_exit == 1 )); then
#     echo "Overall: WARNING"
# else
#     echo "Overall: OK"
# fi
case "$worst_exit" in
    2) echo "Overall: CRITICAL" ;;
    1) echo "Overall: WARNING"  ;;
    *) echo "Overall: OK"       ;;
esac

exit "$worst_exit"