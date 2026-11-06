#!/usr/bin/env bash
# ============================================================================
# disk_check.sh — senior-level storage health check
#
#   * NEVER HANGS: each filesystem is probed in parallel under `timeout`; a dead NFS server is reported as
#     "unresponsive" instead of freezing the monitoring run (plain `df` blocks forever on a hard NFS mount)
#   * Detached probes: background jobs have stdout/stderr closed, otherwise an orphaned probe keeps the
#     caller's pipe open and the caller waits for EOF forever
#   * Space AND inodes, using statfs(2) via `stat -f` (no fragile df column parsing)
#   * PREDICTIVE: stores usage between runs → growth rate → hours-until-full ("fills in 3h" beats "85%")
#   * Detects filesystems that silently went READ-ONLY after errors (remounted ro, but fstab says rw)
#   * Finds space held by DELETED-BUT-OPEN files via /proc/*/fd (the classic "df says full, du says empty")
#   * I/O latency from two /proc/diskstats samples (await, utilisation, IOPS) — no iostat dependency
# ============================================================================
SCRIPT_NAME="disk_check"; CHECK_NAME="disk"
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

WARN=80; CRIT=90
IWARN=80; ICRIT=90
TTF_WARN="24:"; TTF_CRIT="4:"          # hours until full — "less than" ranges
AWAIT_WARN=50; AWAIT_CRIT=200          # ms
FS_TIMEOUT=5; INTERVAL=2; CONFIRM=1; TOP=5; DO_IO=1; FIND_DELETED=0
EXCL_TYPE='^(tmpfs|devtmpfs|devpts|proc|sysfs|cgroup2?|overlay|squashfs|autofs|mqueue|hugetlbfs|debugfs|tracefs|securityfs|pstore|bpf|configfs|fusectl|binfmt_misc|rpc_pipefs|nsfs|efivarfs|ramfs|fuse\.gvfsd-fuse)$'
EXCL_MOUNT=""
FSTAB="${SYSMON_FSTAB:-/etc/fstab}"
RW_TYPES='^(ext[234]|xfs|btrfs|jfs|reiserfs|f2fs)$'      # types that should NOT be read-only unless fstab says so
IO_DEV='^(sd[a-z]+|vd[a-z]+|xvd[a-z]+|nvme[0-9]+n[0-9]+|md[0-9]+|dm-[0-9]+)$'

usage() { cat <<'EOF'
Usage: disk_check.sh [options]
  -w, --warn RANGE         space used %                         [80]
  -c, --crit RANGE                                              [90]
      --inode-warn RANGE   inode used %                         [80]
      --inode-crit RANGE                                        [90]
      --ttf-warn RANGE     hours until full (needs 2+ runs)     [24:]
      --ttf-crit RANGE                                          [4:]
      --await-warn RANGE   I/O latency, ms                      [50]
      --await-crit RANGE                                        [200]
      --fs-timeout SECS    per-filesystem probe timeout         [5]
      --exclude-type RE    filesystem types to skip             [pseudo/overlay/tmpfs…]
      --exclude-mount RE   mount points to skip
      --no-io              skip the /proc/diskstats latency sample
      --find-deleted       always scan for deleted-but-open files (auto when a mount is CRITICAL)
      --interval SECS      I/O sample window                    [2]
      --top N              list N largest deleted-open files    [5]
      --confirm N          CRITICAL only after N consecutive runs [1]
  -f, --format FMT         nagios | json | prom
  -d, --debug   -h, --help
Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
EOF
}
parse_args() {
    local parsed
    parsed="$(getopt -o 'w:c:f:dh' -l 'warn:,crit:,inode-warn:,inode-crit:,ttf-warn:,ttf-crit:,await-warn:,await-crit:,fs-timeout:,exclude-type:,exclude-mount:,no-io,find-deleted,interval:,top:,confirm:,format:,debug,help' \
              -n "$SCRIPT_NAME" -- "$@")" || { usage >&2; exit "$EXIT_UNKNOWN"; }
    eval set -- "$parsed"
    while true; do
        case "$1" in
            -w|--warn) WARN="$2"; shift 2 ;;            -c|--crit) CRIT="$2"; shift 2 ;;
            --inode-warn) IWARN="$2"; shift 2 ;;        --inode-crit) ICRIT="$2"; shift 2 ;;
            --ttf-warn) TTF_WARN="$2"; shift 2 ;;       --ttf-crit) TTF_CRIT="$2"; shift 2 ;;
            --await-warn) AWAIT_WARN="$2"; shift 2 ;;   --await-crit) AWAIT_CRIT="$2"; shift 2 ;;
            --fs-timeout) FS_TIMEOUT="$2"; shift 2 ;;   --exclude-type) EXCL_TYPE="$2"; shift 2 ;;
            --exclude-mount) EXCL_MOUNT="$2"; shift 2 ;; --no-io) DO_IO=0; shift ;;
            --find-deleted) FIND_DELETED=1; shift ;;    --interval) INTERVAL="$2"; shift 2 ;;
            --top) TOP="$2"; shift 2 ;;                 --confirm) CONFIRM="$2"; shift 2 ;;
            -f|--format) OUTPUT_FORMAT="$2"; shift 2 ;; -d|--debug) LOG_LEVEL=debug; shift ;;
            -h|--help) usage; exit 0 ;;                 --) shift; break ;;
            *) die "internal option parsing error" ;;
        esac
    done
    [[ "$FS_TIMEOUT" =~ ^[0-9]+$ && "$INTERVAL" =~ ^[0-9]+$ && "$TOP" =~ ^[0-9]+$ && "$CONFIRM" =~ ^[0-9]+$ ]] || die "--fs-timeout/--interval/--top/--confirm must be integers"
}

mname() { local n="${1#/}"; n="${n//[^A-Za-z0-9]/_}"; printf '%s' "${n:-root}"; }       # "/var/log" → var_log, "/" → root
fstab_opts() { [[ -r "$FSTAB" ]] && awk -v m="$1" '$1 !~ /^#/ && $2 == m { print $4; exit }' "$FSTAB" || true; }
has_opt() { [[ ",$1," == *",$2,"* ]]; }
now_precise() { if [[ -n "${EPOCHREALTIME:-}" ]]; then printf '%s' "$EPOCHREALTIME"; else date +%s.%N; fi; }

# Files that were deleted while a process still has them open: the space is NOT freed until the process closes them.
deleted_open() {  # deleted_open N → "size pid comm path" for the N largest
    local l t size pid comm out=""
    shopt -s nullglob
    for l in "$PROC"/[0-9]*/fd/*; do
        t="$(readlink "$l" 2>/dev/null)" || continue
        [[ "$t" == *" (deleted)" && "$t" != /memfd:* && "$t" == /* ]] || continue
        size="$(stat -L -c %s "$l" 2>/dev/null || echo 0)"
        pid="${l#"$PROC"/}"; pid="${pid%%/*}"
        comm="$(< "$PROC/$pid/comm")" 2>/dev/null || comm="?"
        out+="${size} ${pid} ${comm// /_} ${t% (deleted)}"$'\n'
    done
    shopt -u nullglob
    [[ -n "$out" ]] && sort -rn <<<"$out" | awk -v n="$1" 'NR<=n' || true
}
io_deltas() {  # io_deltas SNAP1 SNAP2 ELAPSED → "dev r_await w_await util% iops" for devices with >=5 completed IOs
    awk -v el="$3" -v re="$IO_DEV" '
        NR==FNR { r[$3]=$4; rt[$3]=$7; w[$3]=$8; wt[$3]=$11; it[$3]=$13; next }
        ($3 in r) && ($3 ~ re) {
            dr=$4-r[$3]; dw=$8-w[$3]; n=dr+dw; if (n < 5) next
            ra = dr>0 ? ($7-rt[$3])/dr : 0;  wa = dw>0 ? ($11-wt[$3])/dw : 0
            util = ($13-it[$3])/(el*1000)*100; if (util>100) util=100; if (util<0) util=0
            printf "%s %.1f %.1f %.1f %.1f\n", $3, ra, wa, util, n/el }' "$1" "$2"
}

main() {
    parse_args "$@"
    [[ -r "$PROC/mounts" ]] || { OVERALL_STATUS=3; summary "cannot read $PROC/mounts"; finish; }

    # ---- 1. enumerate real filesystems --------------------------------------------------------------
    local -a T=() TY=() SR=() OP=()
    local -A seen=()
    local src tgt type opts _
    while read -r src tgt type opts _; do
        tgt="$(printf '%b' "$tgt")"                                         # decode \040 (space) etc.
        [[ "$type" =~ $EXCL_TYPE ]] && continue
        [[ -n "$EXCL_MOUNT" && "$tgt" =~ $EXCL_MOUNT ]] && continue
        if [[ "$src" == /dev/* ]]; then [[ -n "${seen[$src]+x}" ]] && continue; seen["$src"]=1; fi   # bind mounts: same device, count once
        T+=("$tgt"); TY+=("$type"); SR+=("$src"); OP+=("$opts")
    done < "$PROC/mounts"
    if (( ${#T[@]} == 0 )); then T=("/"); TY=("?"); SR=("?"); OP=("rw"); log debug "no filesystems after filtering; checking / (container?)"; fi

    # ---- 2. probe ALL of them in parallel, each bounded by timeout --------------------------------------
    local td i; td="$(tmpdir)"
    for i in "${!T[@]}"; do
        # NB: the subshell inherits errexit — without the `|| prc=$?` a failing probe would kill the subshell BEFORE it
        # records its exit code, and a plain error would be misreported as "unresponsive".
        ( prc=0; timeout --kill-after=1 "$FS_TIMEOUT" stat -f -c '%S %b %a %f %c %d' -- "${T[i]}" > "$td/$i.out" 2>/dev/null || prc=$?
          echo "$prc" > "$td/$i.rc" ) >/dev/null 2>&1 &
    done
    # Poll instead of `wait`: a probe stuck in uninterruptible sleep (hard NFS) cannot be killed, and `wait` would hang with it.
    local deadline=$(( (FS_TIMEOUT + 3) * 10 )) t done_n
    for (( t=0; t<deadline; t++ )); do
        done_n=0; for i in "${!T[@]}"; do [[ -f "$td/$i.rc" ]] && done_n=$((done_n + 1)); done
        (( done_n == ${#T[@]} )) && break
        sleep 0.1
    done

    # ---- 3. evaluate each filesystem -------------------------------------------------------------------------
    local worst_pct=0 worst_mnt="" nproblem=0 any_crit_space=0 nfs_checked=0
    local S b a f c d rc used_pct inode_pct m s st_space st_inode st_ttf st_ro eff ro_expected
    local now used_bytes avail_bytes prev prev_ts prev_used dt rate ttf key
    now="$(now_epoch)"
    for i in "${!T[@]}"; do
        m="$(mname "${T[i]}")"; nfs_checked=$((nfs_checked + 1))
        rc="$(cat "$td/$i.rc" 2>/dev/null || echo hung)"
        if [[ "$rc" != 0 ]]; then
            bump_status 2; nproblem=$((nproblem + 1))
            if [[ "$rc" == 124 || "$rc" == 137 || "$rc" == hung ]]; then detail "CRITICAL ${T[i]} (${TY[i]}, ${SR[i]}): UNRESPONSIVE — statfs did not return within ${FS_TIMEOUT}s (dead NFS/SAN path?)"
            else detail "CRITICAL ${T[i]} (${TY[i]}): statfs failed rc=$rc"; fi
            summary "${T[i]} unresponsive"; perf "unresponsive_${m}" 1
            continue
        fi
        read -r S b a f c d < "$td/$i.out"
        used_pct="$(awk -v b="$b" -v a="$a" -v f="$f" 'BEGIN{u=b-f; t=u+a; if(t<=0) print "0.0"; else printf "%.1f", u*100/t}')"
        inode_pct="$(awk -v c="$c" -v d="$d" 'BEGIN{ if (c<=0) print "-1"; else printf "%.1f", (c-d)*100/c }')"
        perf "used_pct_${m}" "$used_pct" % "$WARN" "$CRIT"
        st_space="$(classify "$used_pct" "$WARN" "$CRIT")"
        apply_hysteresis "$st_space" "disk.$(state_key "${T[i]}")" "$CONFIRM"; eff="$HYST_STATUS"; bump_status "$eff"
        if (( eff > 0 )); then
            nproblem=$((nproblem + 1)); detail "$(status_label "$eff") ${T[i]} (${TY[i]}): ${used_pct}% space used${HYST_NOTE}"
            if (( st_space == 2 )); then any_crit_space=1; fi
        fi
        if fcmp "$used_pct" gt "$worst_pct"; then worst_pct="$used_pct"; worst_mnt="${T[i]}"; fi

        # inodes (xfs/btrfs allocate dynamically: c can be 0 → skipped)
        if fcmp "$inode_pct" ge 0; then
            perf "inode_pct_${m}" "$inode_pct" % "$IWARN" "$ICRIT"
            st_inode="$(classify "$inode_pct" "$IWARN" "$ICRIT")"; bump_status "$st_inode"
            if (( st_inode > 0 )); then nproblem=$((nproblem + 1)); detail "$(status_label "$st_inode") ${T[i]}: ${inode_pct}% INODES used (space is ${used_pct}% — 'no space left' with free bytes = inode exhaustion)"; fi
        fi

        # unexpected read-only (kernel remounts ro after I/O/metadata errors)
        if has_opt "${OP[i]}" ro && [[ "${TY[i]}" =~ $RW_TYPES ]]; then
            ro_expected=0; has_opt "$(fstab_opts "${T[i]}")" ro && ro_expected=1
            if (( ro_expected == 0 )); then bump_status 2; nproblem=$((nproblem + 1)); detail "CRITICAL ${T[i]} (${TY[i]}): mounted READ-ONLY but fstab does not say ro — likely remounted after filesystem/disk errors (check dmesg)"; summary "${T[i]} read-only"; perf "readonly_${m}" 1; fi
        fi

        # predictive: growth rate since the last stored sample (>= 60s apart so noise does not dominate)
        used_bytes=$(( (b - f) * S )); avail_bytes=$(( a * S )); key="disk.use.$(state_key "${T[i]}")"
        prev="$(state_get "$key" "")"
        if [[ -z "$prev" ]]; then state_set "$key" "$now $used_bytes"
        else
            read -r prev_ts prev_used <<<"$prev"; dt=$(( now - prev_ts ))
            if (( dt >= 60 )); then
                rate="$(awk -v u="$used_bytes" -v p="$prev_used" -v t="$dt" 'BEGIN{printf "%.0f", (u-p)/t}')"
                if (( rate > 0 )); then
                    ttf="$(awk -v a="$avail_bytes" -v r="$rate" 'BEGIN{printf "%.1f", a/r/3600}')"
                    perf "ttf_hours_${m}" "$ttf" h "$TTF_WARN" "$TTF_CRIT"
                    perf "growth_kb_s_${m}" "$(( rate / 1024 ))" KB/s
                    st_ttf="$(classify "$ttf" "$TTF_WARN" "$TTF_CRIT")"; bump_status "$st_ttf"
                    if (( st_ttf > 0 )); then nproblem=$((nproblem + 1)); detail "$(status_label "$st_ttf") ${T[i]}: growing $(( rate / 1024 )) KB/s → FULL in ${ttf}h (currently ${used_pct}%)"; summary "${T[i]} full in ${ttf}h"; fi
                fi
                state_set "$key" "$now $used_bytes"
            fi
        fi
    done
    summary "${nfs_checked} filesystem(s) checked, worst ${worst_pct}% (${worst_mnt:-n/a})"
    perf worst_used_pct "$worst_pct" % "$WARN" "$CRIT"

    # ---- 4. space that df counts but du can't see ---------------------------------------------------------
    if (( any_crit_space || FIND_DELETED )); then
        local lines; lines="$(deleted_open "$TOP")"
        if [[ -n "$lines" ]]; then
            detail "Deleted-but-still-open files (space is freed only when the process closes/restarts):"
            local sz pid comm path
            while read -r sz pid comm path; do detail "$(printf '  %8d MiB  pid=%-7s %-14s %s' "$(( sz / 1048576 ))" "$pid" "$comm" "$path")"; done <<<"$lines"
        fi
    fi

    # ---- 5. block-device latency over a sample window -----------------------------------------------------------
    if (( DO_IO && INTERVAL > 0 )) && [[ -r "$PROC/diskstats" ]]; then
        local t1 t2 el; cp "$PROC/diskstats" "$td/ds1"; t1="$(now_precise)"; sleep "$INTERVAL"; cp "$PROC/diskstats" "$td/ds2"; t2="$(now_precise)"
        el="$(awk -v a="$t1" -v b="$t2" 'BEGIN{printf "%.3f", b-a}')"
        local dev ra wa util iops worst_aw=0 aw worst_dev="" worst_util=0
        while read -r dev ra wa util iops; do
            [[ -n "$dev" ]] || continue
            aw="$ra"; if fcmp "$wa" gt "$ra"; then aw="$wa"; fi
            if fcmp "$aw" gt "$worst_aw"; then worst_aw="$aw"; worst_dev="$dev"; fi
            if fcmp "$util" gt "$worst_util"; then worst_util="$util"; fi
            detail "io ${dev}: read await ${ra} ms, write await ${wa} ms, util ${util}%, ${iops} IOPS"
        done < <(io_deltas "$td/ds1" "$td/ds2" "$el")
        if [[ -n "$worst_dev" ]]; then
            perf worst_await_ms "$worst_aw" ms "$AWAIT_WARN" "$AWAIT_CRIT"; perf worst_util_pct "$worst_util" %
            s="$(classify "$worst_aw" "$AWAIT_WARN" "$AWAIT_CRIT")"; bump_status "$s"
            if (( s > 0 )); then summary "slow I/O on ${worst_dev}: ${worst_aw} ms await (util ${worst_util}%)"; fi
        fi
    fi
    finish
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
