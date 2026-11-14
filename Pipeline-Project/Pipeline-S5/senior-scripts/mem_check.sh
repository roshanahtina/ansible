#!/usr/bin/env bash
# ============================================================================
# mem_check.sh — senior-level memory health check
#
# What makes this different from the intermediate version:
#   * Alerts on MemAvailable (not "free"), with a fallback for old kernels that lack it
#   * Container-aware: honours the cgroup memory limit (host RAM is irrelevant inside a limited cgroup)
#   * Swap ACTIVITY (pages/s over a sample window) instead of static "swap used %" — thrashing vs history
#   * OOM kills via the kernel's oom_kill COUNTER delta (survives dmesg rotation; no log scraping)
#   * PSI (Pressure Stall Information): "how long were tasks actually STALLED on memory" — the best modern signal
#   * Nagios range thresholds, flap suppression (--confirm N), nagios|json|prom output, fixture-testable
# ============================================================================
SCRIPT_NAME="mem_check"; CHECK_NAME="mem"
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

WARN=80; CRIT=90                 # memory USED % (100 - available%)
SWAPIO_WARN=100; SWAPIO_CRIT=1000  # swap in+out, pages/second
PSI_WARN=10; PSI_CRIT=40         # memory "some avg10" %
INTERVAL=2; TOP=5; CONFIRM=1

usage() { cat <<'EOF'
Usage: mem_check.sh [options]
  -w, --warn RANGE         memory USED %  (from MemAvailable)           [80]
  -c, --crit RANGE                                                      [90]
      --swapio-warn RANGE  swap in+out pages/sec over the window        [100]
      --swapio-crit RANGE                                               [1000]
      --psi-warn RANGE     memory pressure 'some avg10' %               [10]
      --psi-crit RANGE                                                  [40]
      --interval SECS      sample window for rate metrics (0 = skip)    [2]
      --top N              list the N largest processes by RSS          [5]
      --confirm N          report CRITICAL only after N consecutive runs [1]
  -f, --format FMT         nagios | json | prom                          [nagios]
  -d, --debug              verbose logging to stderr
  -h, --help
Ranges use Nagios syntax:  90 (alert if >90)   20: (alert if <20)   @10:20 (alert if inside)
Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
EOF
}

parse_args() {
    local parsed
    parsed="$(getopt -o 'w:c:f:dh' -l 'warn:,crit:,swapio-warn:,swapio-crit:,psi-warn:,psi-crit:,interval:,top:,confirm:,format:,debug,help' \
              -n "$SCRIPT_NAME" -- "$@")" || { usage >&2; exit "$EXIT_UNKNOWN"; }
    eval set -- "$parsed"       # safe: getopt re-quotes every token
    while true; do
        case "$1" in
            -w|--warn) WARN="$2"; shift 2 ;;            -c|--crit) CRIT="$2"; shift 2 ;;
            --swapio-warn) SWAPIO_WARN="$2"; shift 2 ;; --swapio-crit) SWAPIO_CRIT="$2"; shift 2 ;;
            --psi-warn) PSI_WARN="$2"; shift 2 ;;       --psi-crit) PSI_CRIT="$2"; shift 2 ;;
            --interval) INTERVAL="$2"; shift 2 ;;       --top) TOP="$2"; shift 2 ;;
            --confirm) CONFIRM="$2"; shift 2 ;;         -f|--format) OUTPUT_FORMAT="$2"; shift 2 ;;
            -d|--debug) LOG_LEVEL=debug; shift ;;       -h|--help) usage; exit 0 ;;
            --) shift; break ;;                         *) die "internal option parsing error" ;;
        esac
    done
    [[ "$INTERVAL" =~ ^[0-9]+$ && "$TOP" =~ ^[0-9]+$ && "$CONFIRM" =~ ^[0-9]+$ ]] || die "--interval/--top/--confirm must be integers"
}

main() {
    parse_args "$@"
    [[ -r "$PROC/meminfo" ]] || { OVERALL_STATUS=3; summary "cannot read $PROC/meminfo"; finish; }

    # ---- 1. parse /proc/meminfo once (builtins only; no awk per field) -----------------------------
    declare -A M=()
    local k v _
    while read -r k v _; do M["${k%:}"]="$v"; done < "$PROC/meminfo"
    local total="${M[MemTotal]:-0}" avail
    (( total > 0 )) || { OVERALL_STATUS=3; summary "MemTotal missing/zero"; finish; }
    if [[ -n "${M[MemAvailable]+x}" ]]; then
        avail="${M[MemAvailable]}"
    else   # kernels < 3.14: approximate what is reclaimable
        avail=$(( ${M[MemFree]:-0} + ${M[Buffers]:-0} + ${M[Cached]:-0} + ${M[SReclaimable]:-0} ))
        log warn "MemAvailable not provided by kernel; using an approximation"
    fi
    local used=$(( total - avail )) used_pct s
    used_pct="$(pct "$used" "$total")"
    perf used_pct "$used_pct" % "$WARN" "$CRIT"
    perf available_mb "$(( avail / 1024 ))" MB
    perf total_mb "$(( total / 1024 ))" MB
    summary "${used_pct}% used ($(( avail / 1024 )) MiB available of $(( total / 1024 )) MiB)"

    s="$(classify "$used_pct" "$WARN" "$CRIT")"
    apply_hysteresis "$s" mem.used "$CONFIRM"; bump_status "$HYST_STATUS"
    [[ -n "$HYST_NOTE" ]] && summary "memory$HYST_NOTE"

    # ---- 2. cgroup limit (containers / systemd MemoryMax): host numbers can be completely misleading --
    local cg lim cur cg_pct
    cg="$(cgroup_mem)"
    if [[ -n "$cg" ]]; then
        read -r lim cur <<<"$cg"
        cg_pct="$(pct "$cur" "$lim")"
        perf cgroup_used_pct "$cg_pct" % "$WARN" "$CRIT"
        summary "cgroup ${cg_pct}% of $(( lim / 1048576 )) MiB limit"
        bump_status "$(classify "$cg_pct" "$WARN" "$CRIT")"
    fi

    # ---- 3. swap: static usage is context only; ACTIVITY is the real signal -------------------------
    local swap_total="${M[SwapTotal]:-0}" swap_free="${M[SwapFree]:-0}" swap_pct=0
    if (( swap_total > 0 )); then
        swap_pct="$(pct "$(( swap_total - swap_free ))" "$swap_total")"
        perf swap_used_pct "$swap_pct" %
    fi
    local in1 out1 in2 out2 rate
    in1="$(vmstat_counter pswpin)"; out1="$(vmstat_counter pswpout)"
    if (( INTERVAL > 0 )) && [[ -n "$in1" && -n "$out1" ]]; then
        sleep "$INTERVAL"
        in2="$(vmstat_counter pswpin)"; out2="$(vmstat_counter pswpout)"
        rate="$(awk -v a="$in1" -v b="$out1" -v c="$in2" -v d="$out2" -v t="$INTERVAL" 'BEGIN{r=((c-a)+(d-b))/t; if(r<0)r=0; printf "%.1f", r}')"
        perf swap_io_pps "$rate" pps "$SWAPIO_WARN" "$SWAPIO_CRIT"
        s="$(classify "$rate" "$SWAPIO_WARN" "$SWAPIO_CRIT")"
        bump_status "$s"
        if (( s > 0 )); then summary "swapping ${rate} pages/s (swap ${swap_pct}% used)"; fi
    fi

    # ---- 4. OOM kills: counter delta since the last run ---------------------------------------------
    local oom_now oom_prev delta
    oom_now="$(vmstat_counter oom_kill)"
    if [[ -n "$oom_now" ]]; then
        oom_prev="$(state_get mem.oom_kill "")"; state_set mem.oom_kill "$oom_now"
        if [[ -n "$oom_prev" ]]; then
            delta=$(( oom_now - oom_prev )); if (( delta < 0 )); then delta=0; fi     # counter resets on reboot
            perf oom_kills_delta "$delta" c 0 0
            if (( delta > 0 )); then bump_status 2; summary "$delta OOM kill(s) since last check"; fi
        else
            log debug "first run: stored oom_kill baseline ($oom_now)"
        fi
    fi

    # ---- 5. PSI: share of time tasks were stalled waiting for memory --------------------------------
    local psi
    psi="$(psi_avg10 memory some)"
    if [[ -n "$psi" ]]; then
        perf psi_some_avg10 "$psi" % "$PSI_WARN" "$PSI_CRIT"
        s="$(classify "$psi" "$PSI_WARN" "$PSI_CRIT")"; bump_status "$s"
        if (( s > 0 )); then summary "memory pressure ${psi}% (tasks stalled)"; fi
    fi

    # ---- 6. kernel memory that cannot be reclaimed (slab leak signal), context only ------------------
    if [[ -n "${M[SUnreclaim]+x}" ]]; then perf slab_unreclaim_mb "$(( M[SUnreclaim] / 1024 ))" MB; fi

    # ---- 7. top consumers.  mapfile + slicing, NOT `ps | head`: under pipefail, head closing the pipe
    #         makes ps die with SIGPIPE (rc 141) and errexit would abort the whole script. ----------------
    if (( TOP > 0 )) && (( OVERALL_STATUS > 0 )) || [[ "$LOG_LEVEL" == debug ]]; then
        local -a lines=(); local i pid rss user comm
        mapfile -t lines < <(ps -eo pid=,user=,rss=,comm= --sort=-rss 2>/dev/null || true)
        detail "Top ${TOP} memory consumers:"
        for (( i=0; i<TOP && i<${#lines[@]}; i++ )); do
            read -r pid user rss comm <<<"${lines[i]}"
            detail "$(printf '  pid=%-7s %-10s %7d MiB  %s' "$pid" "$user" "$(( rss / 1024 ))" "$comm")"
        done
    fi
    finish
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
