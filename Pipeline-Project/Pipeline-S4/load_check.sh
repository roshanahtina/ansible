#!/usr/bin/env bash
# ============================================================================
# load_check.sh — senior-level load / CPU diagnosis
#
# The intermediate version reported numbers.  This one reaches a DIAGNOSIS:
#   * Load is normalised by EFFECTIVE cpus (cgroup quota aware), not just nproc
#   * Instantaneous CPU split from two /proc/stat samples: user / sys / iowait / irq+softirq / STEAL
#   * Persistent D-state detection (in D-state in BOTH samples) — a transient D is normal, a stuck one is an incident
#   * Per-core view: finds the single saturated core that the aggregate average hides
#   * cgroup CPU throttling (containers look "idle" while being throttled)
#   * PSI (cpu + io pressure): saturation measured directly, per the USE method
#   * Classifies the bottleneck:  hypervisor steal | I/O-bound | CPU-bound | single-thread | throttled
#   * Utilisation alone does not alert by default — USE method: alert on SATURATION (queue/pressure), not busy%.
# ============================================================================
SCRIPT_NAME="load_check"; CHECK_NAME="load"
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

WARN=1.0; CRIT=2.0                 # load1 per effective CPU
CPU_WARN=""; CPU_CRIT=""           # busy %  (off by default: utilisation != saturation)
IOW_WARN=20; IOW_CRIT=50           # iowait %
STEAL_WARN=5; STEAL_CRIT=20        # steal %
PSI_WARN=20; PSI_CRIT=60           # pressure 'some avg10' % (cpu and io)
DSTATE_WARN=0; DSTATE_CRIT=4       # PERSISTENT D-state process count
INTERVAL=2; TOP=5; CONFIRM=1

usage() { cat <<'EOF'
Usage: load_check.sh [options]
  -w, --warn RANGE        load1 per effective CPU            [1.0]
  -c, --crit RANGE                                           [2.0]
      --cpu-warn RANGE    CPU busy %   (off by default)
      --cpu-crit RANGE
      --iowait-warn RANGE iowait %                           [20]
      --iowait-crit RANGE                                    [50]
      --steal-warn RANGE  hypervisor steal %                 [5]
      --steal-crit RANGE                                     [20]
      --psi-warn RANGE    cpu/io pressure 'some avg10' %     [20]
      --psi-crit RANGE                                       [60]
      --dstate-warn RANGE persistent D-state processes       [0]
      --dstate-crit RANGE                                    [4]
      --interval SECS     sample window (0 = skip rates)     [2]
      --top N             list N stuck D-state processes     [5]
      --confirm N         CRITICAL only after N consecutive runs [1]
  -f, --format FMT        nagios | json | prom
  -d, --debug   -h, --help
Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
EOF
}
parse_args() {
    local parsed
    parsed="$(getopt -o 'w:c:f:dh' -l 'warn:,crit:,cpu-warn:,cpu-crit:,iowait-warn:,iowait-crit:,steal-warn:,steal-crit:,psi-warn:,psi-crit:,dstate-warn:,dstate-crit:,interval:,top:,confirm:,format:,debug,help' \
              -n "$SCRIPT_NAME" -- "$@")" || { usage >&2; exit "$EXIT_UNKNOWN"; }
    eval set -- "$parsed"
    while true; do
        case "$1" in
            -w|--warn) WARN="$2"; shift 2 ;;            -c|--crit) CRIT="$2"; shift 2 ;;
            --cpu-warn) CPU_WARN="$2"; shift 2 ;;       --cpu-crit) CPU_CRIT="$2"; shift 2 ;;
            --iowait-warn) IOW_WARN="$2"; shift 2 ;;    --iowait-crit) IOW_CRIT="$2"; shift 2 ;;
            --steal-warn) STEAL_WARN="$2"; shift 2 ;;   --steal-crit) STEAL_CRIT="$2"; shift 2 ;;
            --psi-warn) PSI_WARN="$2"; shift 2 ;;       --psi-crit) PSI_CRIT="$2"; shift 2 ;;
            --dstate-warn) DSTATE_WARN="$2"; shift 2 ;; --dstate-crit) DSTATE_CRIT="$2"; shift 2 ;;
            --interval) INTERVAL="$2"; shift 2 ;;       --top) TOP="$2"; shift 2 ;;
            --confirm) CONFIRM="$2"; shift 2 ;;         -f|--format) OUTPUT_FORMAT="$2"; shift 2 ;;
            -d|--debug) LOG_LEVEL=debug; shift ;;       -h|--help) usage; exit 0 ;;
            --) shift; break ;;                         *) die "internal option parsing error" ;;
        esac
    done
    [[ "$INTERVAL" =~ ^[0-9]+$ && "$TOP" =~ ^[0-9]+$ && "$CONFIRM" =~ ^[0-9]+$ ]] || die "--interval/--top/--confirm must be integers"
}

snap_stat() { awk '/^cpu[0-9]* /{ printf "%s %d %d %d %d %d %d %d %d\n", $1,$2,$3,$4,$5,$6,$7,$8,$9+0 }' "$PROC/stat"; }
cpu_deltas() {   # cpu_deltas SNAP1 SNAP2 → "AGG user sys idle iowait irq steal busy" + "CORES n max_busy n_hot"
    awk 'NR==FNR { for (i=2;i<=9;i++) a[$1,i]=$i; next }
         { n=$1; tot=0; for (i=2;i<=9;i++) { d[i]=$i-a[n,i]; if (d[i]<0) d[i]=0; tot+=d[i] }
           if (tot<=0) next
           busy=100*(tot-d[5]-d[6])/tot
           if (n=="cpu") printf "AGG %.1f %.1f %.1f %.1f %.1f %.1f %.1f\n", 100*(d[2]+d[3])/tot, 100*d[4]/tot, 100*d[5]/tot, 100*d[6]/tot, 100*(d[7]+d[8])/tot, 100*d[9]/tot, busy
           else { cores++; if (busy>max) max=busy; if (busy>=90) hot++ } }
         END { printf "CORES %d %.1f %d\n", cores+0, max+0, hot+0 }' "$1" "$2"
}
cg_throttled() {  # cumulative count of throttled periods for our cgroup (v2 or v1), empty if none
    local f
    for f in "$SYS/fs/cgroup/cpu.stat" "$SYS/fs/cgroup/cpu/cpu.stat"; do
        if [[ -r "$f" ]]; then awk '$1=="nr_throttled"{print $2; exit}' "$f"; return 0; fi
    done
}

main() {
    parse_args "$@"
    local l1 l5 l15 runq _
    [[ -r "$PROC/loadavg" ]] && read -r l1 l5 l15 runq _ < "$PROC/loadavg" || { OVERALL_STATUS=3; summary "cannot read $PROC/loadavg"; finish; }
    local cpus ratio running="${runq%%/*}" threads="${runq##*/}"
    cpus="$(effective_cpus)"
    ratio="$(awk -v l="$l1" -v c="$cpus" 'BEGIN{ if (c<=0) c=1; printf "%.2f", l/c }')"
    perf load1 "$l1"; perf load5 "$l5"; perf load15 "$l15"
    perf cpus "$cpus"; perf load_per_cpu "$ratio" "" "$WARN" "$CRIT"
    perf runnable "$running"; perf threads "$threads"
    local trend="steady"
    awk -v a="$l1" -v b="$l15" 'BEGIN{exit !(a > b*1.25 && a-b > 0.5)}' && trend="rising"
    awk -v a="$l1" -v b="$l15" 'BEGIN{exit !(b > a*1.25 && b-a > 0.5)}' && trend="falling"

    local s
    s="$(classify "$ratio" "$WARN" "$CRIT")"; local st_ratio="$s" st_iow=0 st_steal=0
    apply_hysteresis "$s" load.ratio "$CONFIRM"; bump_status "$HYST_STATUS"
    summary "load ${l1}/${l5}/${l15} on ${cpus} CPU (${ratio}/cpu, ${trend})${HYST_NOTE}"

    # ---- sample CPU counters, D-state set and cgroup throttling across the window -------------------
    local td snap_ok=0 agg="" cores="" d1="" d2="" thr1="" thr2="" stuck=""
    if (( INTERVAL > 0 )); then
        td="$(tmpdir)"
        snap_stat > "$td/s1"; d1="$(dstate_list)"; thr1="$(cg_throttled)"
        sleep "$INTERVAL"
        snap_stat > "$td/s2"; d2="$(dstate_list)"; thr2="$(cg_throttled)"
        local out; out="$(cpu_deltas "$td/s1" "$td/s2")"
        agg="$(grep '^AGG ' <<<"$out" || true)"; cores="$(grep '^CORES ' <<<"$out" || true)"
        [[ -n "$agg" ]] && snap_ok=1
        # PERSISTENT D-state = same pid in D in both samples
        if [[ -n "$d1" && -n "$d2" ]]; then
            local pid
            while read -r pid _; do [[ -n "$pid" ]] && grep -q "^${pid} " <<<"$d1" && stuck+="$(grep "^${pid} " <<<"$d2")"$'\n'; done <<<"$d2"
        fi
    else
        d2="$(dstate_list)"; stuck="$d2"      # no window → cannot prove persistence; report what we see
    fi
    local nstuck=0
    [[ -n "${stuck//$'\n'/}" ]] && nstuck="$(grep -c . <<<"$stuck")"
    perf dstate_persistent "$nstuck" "" "$DSTATE_WARN" "$DSTATE_CRIT"
    s="$(classify "$nstuck" "$DSTATE_WARN" "$DSTATE_CRIT")"; bump_status "$s"
    if (( nstuck > 0 )); then summary "$nstuck process(es) stuck in D-state"; fi

    local user="" sys="" idle="" iow="" irq="" steal="" busy="" ncores="" maxcore="" hot=""
    if (( snap_ok )); then
        read -r _ user sys idle iow irq steal busy <<<"$agg"
        read -r _ ncores maxcore hot <<<"$cores"
        perf cpu_user_pct "$user" %; perf cpu_sys_pct "$sys" %; perf cpu_idle_pct "$idle" %
        perf cpu_iowait_pct "$iow" % "$IOW_WARN" "$IOW_CRIT"; perf cpu_irq_pct "$irq" %
        perf cpu_steal_pct "$steal" % "$STEAL_WARN" "$STEAL_CRIT"; perf cpu_busy_pct "$busy" % "$CPU_WARN" "$CPU_CRIT"
        perf busiest_core_pct "$maxcore" %
        summary "cpu busy ${busy}% (user ${user} sys ${sys} iowait ${iow} steal ${steal})"
        st_iow="$(classify "$iow" "$IOW_WARN" "$IOW_CRIT")";       bump_status "$st_iow"
        st_steal="$(classify "$steal" "$STEAL_WARN" "$STEAL_CRIT")"; bump_status "$st_steal"
        if [[ -n "$CPU_WARN$CPU_CRIT" ]]; then bump_status "$(classify "$busy" "$CPU_WARN" "$CPU_CRIT")"; fi
    else
        log debug "no CPU delta available (interval=0 or counters did not advance)"
    fi

    # ---- cgroup throttling and pressure (saturation signals) -----------------------------------------
    local throttled=0
    if [[ -n "$thr1" && -n "$thr2" ]]; then throttled=$(( thr2 - thr1 )); perf cgroup_throttled "$throttled" c; fi
    local psi_cpu psi_io
    psi_cpu="$(psi_avg10 cpu some)"; psi_io="$(psi_avg10 io some)"
    if [[ -n "$psi_cpu" ]]; then perf psi_cpu_some_avg10 "$psi_cpu" % "$PSI_WARN" "$PSI_CRIT"; bump_status "$(classify "$psi_cpu" "$PSI_WARN" "$PSI_CRIT")"; fi
    if [[ -n "$psi_io" ]];  then perf psi_io_some_avg10  "$psi_io"  % "$PSI_WARN" "$PSI_CRIT"; bump_status "$(classify "$psi_io"  "$PSI_WARN" "$PSI_CRIT")"; fi

    # ---- DIAGNOSIS: order matters — most specific / most actionable cause first -----------------------
    local dx=""
    if (( snap_ok )); then
        if   (( st_steal > 0 ));                                      then dx="hypervisor CPU steal ${steal}% — host is oversubscribed/noisy neighbour; fix is outside this VM"
        elif (( nstuck > 0 )) && fcmp "$iow" ge 5;                   then dx="I/O-bound — ${nstuck} stuck D-state process(es), iowait ${iow}%; investigate storage/NFS, not CPU"
        elif (( st_iow > 0 ));                                         then dx="I/O-bound — iowait ${iow}%; check iostat -x for the saturated device"
        elif (( throttled > 0 ));                                      then dx="cgroup CPU throttling (${throttled} periods) — quota too low for this workload, host may look idle"
        elif fcmp "$busy" ge 85;                                       then
            if fcmp "$sys" gt "$user"; then dx="CPU-bound, kernel-heavy (sys ${sys}% > user ${user}%) — syscall/context-switch storm; check strace -c, pidstat -w"
            else dx="CPU-bound in userspace (user ${user}%); find the process with top/pidstat -u"; fi
        elif fcmp "$maxcore" ge 95 && fcmp "$busy" lt 50;             then dx="single-thread bottleneck — one core at ${maxcore}% while average is ${busy}%; look for a single-threaded hot process"
        elif (( st_ratio > 0 ));                                       then dx="run queue long but CPUs not saturated — short bursts, CPU affinity/cgroup limits, or lock contention"
        fi
    elif (( nstuck > 0 )); then dx="stuck D-state processes present — storage/NFS likely"
    fi
    if [[ -n "$dx" ]] && (( OVERALL_STATUS > 0 )); then summary "diagnosis: $dx"; fi
    if (( snap_ok )) && (( ${hot:-0} > 0 )); then detail "${hot} of ${ncores} core(s) >= 90% busy (busiest ${maxcore}%)"; fi

    if (( nstuck > 0 && TOP > 0 )); then
        detail "Stuck (persistent D-state) processes — wchan shows WHERE in the kernel they are blocked:"
        local i=0 pid comm w
        while read -r pid comm w; do
            [[ -n "$pid" ]] || continue
            (( i < TOP )) && detail "$(printf '  pid=%-7s %-16s wchan=%s' "$pid" "$comm" "$w")"
            i=$((i + 1))
        done <<<"$stuck"
    fi
    finish
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
