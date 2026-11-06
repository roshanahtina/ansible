#!/usr/bin/env bash
# ============================================================================
# process_check.sh — senior-level process & resource-exhaustion check
#
#   * One pass over /proc in pure bash (no `ps` parsing, no per-process forks) → cheap enough to run every minute
#   * ZOMBIES: reports the PARENT responsible (a zombie cannot be killed — fix/restart its parent)
#   * D-STATE: only PERSISTENT D-state counts (same pid stuck across a sample window); shows wchan = where in the kernel
#   * FILE-DESCRIPTOR EXHAUSTION: per-process fds / soft limit, so "too many open files" is caught BEFORE the outage
#   * PID / THREAD exhaustion vs kernel.pid_max, kernel.threads-max and the cgroup pids.max (fork-bomb / leak detector)
#   * REQUIRED PROCESSES with minimum counts, plus crash-loop detection from process age
#   * Optional systemd failed-unit count
# ============================================================================
SCRIPT_NAME="process_check"; CHECK_NAME="proc"
# shellcheck source=lib/common.sh
source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/lib/common.sh"

ZOMBIE_WARN=5; ZOMBIE_CRIT=50
DSTATE_WARN=0; DSTATE_CRIT=4
FD_WARN=80; FD_CRIT=95
PID_WARN=70; PID_CRIT=90
UNITS_WARN=0; UNITS_CRIT=3
INTERVAL=2; TOP=5; CONFIRM=1; RESPAWN_WINDOW=120; FAILED_UNITS=0
REQUIRE=""

usage() { cat <<'EOF'
Usage: process_check.sh [options]
      --zombie-warn/--zombie-crit RANGE   zombie count                         [5 / 50]
      --dstate-warn/--dstate-crit RANGE   PERSISTENT D-state processes         [0 / 4]
      --fd-warn/--fd-crit RANGE           worst per-process fd usage, % of soft limit [80 / 95]
      --pid-warn/--pid-crit RANGE         threads as % of pid_max/threads-max/cgroup [70 / 90]
      --units-warn/--units-crit RANGE     failed systemd units (needs --failed-units) [0 / 3]
      --require LIST                      comma list of  name[:min]  that MUST be running  e.g. sshd,nginx:2
      --respawn-window SECS               warn if a required process is younger than this [120]
      --failed-units                      also count failed systemd units
      --interval SECS                     window used to prove D-state persistence [2]
      --top N                             lines of detail per category              [5]
      --confirm N                         CRITICAL only after N consecutive runs     [1]
  -f, --format FMT                        nagios | json | prom
  -d, --debug   -h, --help
Process names are matched against the kernel 'comm' (max 15 chars).  Run as root for full fd visibility.
Exit codes: 0 OK, 1 WARNING, 2 CRITICAL, 3 UNKNOWN
EOF
}
parse_args() {
    local parsed
    parsed="$(getopt -o 'f:dh' -l 'zombie-warn:,zombie-crit:,dstate-warn:,dstate-crit:,fd-warn:,fd-crit:,pid-warn:,pid-crit:,units-warn:,units-crit:,require:,respawn-window:,failed-units,interval:,top:,confirm:,format:,debug,help' \
              -n "$SCRIPT_NAME" -- "$@")" || { usage >&2; exit "$EXIT_UNKNOWN"; }
    eval set -- "$parsed"
    while true; do
        case "$1" in
            --zombie-warn) ZOMBIE_WARN="$2"; shift 2 ;; --zombie-crit) ZOMBIE_CRIT="$2"; shift 2 ;;
            --dstate-warn) DSTATE_WARN="$2"; shift 2 ;; --dstate-crit) DSTATE_CRIT="$2"; shift 2 ;;
            --fd-warn) FD_WARN="$2"; shift 2 ;;         --fd-crit) FD_CRIT="$2"; shift 2 ;;
            --pid-warn) PID_WARN="$2"; shift 2 ;;       --pid-crit) PID_CRIT="$2"; shift 2 ;;
            --units-warn) UNITS_WARN="$2"; shift 2 ;;   --units-crit) UNITS_CRIT="$2"; shift 2 ;;
            --require) REQUIRE="${REQUIRE:+$REQUIRE,}$2"; shift 2 ;;
            --respawn-window) RESPAWN_WINDOW="$2"; shift 2 ;; --failed-units) FAILED_UNITS=1; shift ;;
            --interval) INTERVAL="$2"; shift 2 ;;       --top) TOP="$2"; shift 2 ;;
            --confirm) CONFIRM="$2"; shift 2 ;;         -f|--format) OUTPUT_FORMAT="$2"; shift 2 ;;
            -d|--debug) LOG_LEVEL=debug; shift ;;       -h|--help) usage; exit 0 ;;
            --) shift; break ;;                         *) die "internal option parsing error" ;;
        esac
    done
    [[ "$INTERVAL" =~ ^[0-9]+$ && "$TOP" =~ ^[0-9]+$ && "$CONFIRM" =~ ^[0-9]+$ && "$RESPAWN_WINDOW" =~ ^[0-9]+$ ]] || die "--interval/--top/--confirm/--respawn-window must be integers"
}

read_soft_nofile() {  # read_soft_nofile PID → soft "Max open files" limit, or empty
    local l _ soft
    { while IFS= read -r l; do
        if [[ "$l" == "Max open files"* ]]; then read -r _ _ _ soft _ <<<"$l"; printf '%s' "$soft"; return 0; fi
    done < "$PROC/$1/limits"; } 2>/dev/null || true       # group-redirect so a vanished process cannot print or abort
    return 0
}

main() {
    parse_args "$@"
    [[ -d "$PROC" && -r "$PROC/uptime" ]] || { OVERALL_STATUS=3; summary "cannot read $PROC"; finish; }
    shopt -s nullglob

    local clk page uptime_s
    clk="$(getconf CLK_TCK 2>/dev/null || echo 100)"; page="$(getconf PAGESIZE 2>/dev/null || echo 4096)"
    read -r uptime_s _ < "$PROC/uptime"

    # ---- 1. single pass over /proc ---------------------------------------------------------------------
    declare -A COMM=() ZPAR=() NAMECOUNT=() NAMEAGE=()
    local d pid nproc=0 nthreads_total=0 nzomb=0 worst_bp=0 fd_worst_pct fd_worst="" fd_cov=0 fd_total=0
    local -a fds rss_lines=() fd_hits=()
    local soft bp n age
    for d in "$PROC"/[0-9]*; do
        pid="${d##*/}"
        proc_stat_fields "$pid" || continue                               # process may exit while we scan: that's normal
        nproc=$((nproc + 1)); nthreads_total=$((nthreads_total + PS_THREADS)); COMM["$pid"]="$PS_COMM"
        NAMECOUNT["$PS_COMM"]=$(( ${NAMECOUNT[$PS_COMM]:-0} + 1 ))
        age=$(( ${uptime_s%.*} - PS_START / clk )); if (( age < 0 )); then age=0; fi          # integer math: no fork per process
        if [[ -z "${NAMEAGE[$PS_COMM]+x}" ]] || (( age < NAMEAGE[$PS_COMM] )); then NAMEAGE["$PS_COMM"]="$age"; fi
        if [[ "$PS_STATE" == Z ]]; then nzomb=$((nzomb + 1)); ZPAR["$PS_PPID"]=$(( ${ZPAR[$PS_PPID]:-0} + 1 )); fi
        rss_lines+=("$(( PS_RSS * page / 1024 )) $pid $PS_COMM")
        fd_total=$((fd_total + 1))
        fds=("$d"/fd/*)
        if [[ -d "$d/fd" ]] && [[ -r "$d/fd" ]]; then
            fd_cov=$((fd_cov + 1)); n=${#fds[@]}
            soft="$(read_soft_nofile "$pid")"
            if [[ "$soft" =~ ^[0-9]+$ ]] && (( soft > 0 )); then
                bp=$(( n * 10000 / soft ))                                  # basis points: 10000 = 100.00%
                if (( bp > worst_bp )); then worst_bp="$bp"; fd_worst="$PS_COMM pid=$pid ($n/$soft)"; fi
                if (( bp >= 1000 )); then fd_hits+=("$bp $pid $PS_COMM $n $soft"); fi   # only >=10% usage is worth a closer look
            fi
        fi
    done
    fd_worst_pct="$(( worst_bp / 100 )).$(( (worst_bp % 100) / 10 ))"
    perf processes "$nproc"; perf threads "$nthreads_total"
    summary "${nproc} processes / ${nthreads_total} threads"

    # ---- 2. zombies → blame the parent --------------------------------------------------------------------
    local s
    perf zombies "$nzomb" "" "$ZOMBIE_WARN" "$ZOMBIE_CRIT"
    s="$(classify "$nzomb" "$ZOMBIE_WARN" "$ZOMBIE_CRIT")"
    apply_hysteresis "$s" proc.zombies "$CONFIRM"; bump_status "$HYST_STATUS"
    if (( nzomb > 0 )); then summary "${nzomb} zombie(s)${HYST_NOTE}"; fi
    if (( nzomb > 0 )) && { (( HYST_STATUS > 0 )) || [[ "$LOG_LEVEL" == debug ]]; }; then
        detail "Zombies cannot be killed (already dead) — the PARENT is not reaping them (missing wait()/SIGCHLD handling). Fix or restart the parent:"
        local ppid cnt; local -a zl=()
        for ppid in "${!ZPAR[@]}"; do zl+=("${ZPAR[$ppid]} $ppid"); done
        local i=0 line
        while read -r cnt ppid; do
            [[ -n "$cnt" ]] || continue
            if (( i < TOP )); then detail "$(printf '  parent pid=%-7s %-16s has %d zombie child(ren)' "$ppid" "${COMM[$ppid]:-<gone: reparented to init>}" "$cnt")"; fi
            i=$((i + 1))
        done < <(printf '%s\n' "${zl[@]}" | sort -rn)
    fi

    # ---- 3. persistent D-state ------------------------------------------------------------------------------
    local d1 d2 stuck="" nstuck=0
    d1="$(dstate_list)"
    if (( INTERVAL > 0 )); then
        sleep "$INTERVAL"; d2="$(dstate_list)"
        local p
        if [[ -n "$d1" && -n "$d2" ]]; then
            while read -r p _; do if [[ -n "$p" ]] && grep -q "^${p} " <<<"$d1"; then stuck+="$(grep "^${p} " <<<"$d2")"$'\n'; fi; done <<<"$d2"
        fi
    else stuck="$d1"; fi
    if [[ -n "${stuck//$'\n'/}" ]]; then nstuck="$(grep -c . <<<"$stuck")"; fi
    perf dstate_persistent "$nstuck" "" "$DSTATE_WARN" "$DSTATE_CRIT"
    s="$(classify "$nstuck" "$DSTATE_WARN" "$DSTATE_CRIT")"; bump_status "$s"
    if (( nstuck > 0 )); then
        summary "${nstuck} process(es) stuck in D-state"
        detail "Stuck in uninterruptible sleep (cannot be killed; usually storage/NFS) — wchan = where in the kernel:"
        local sp sc sw j=0
        while read -r sp sc sw; do [[ -n "$sp" ]] || continue; if (( j < TOP )); then detail "$(printf '  pid=%-7s %-16s wchan=%s' "$sp" "$sc" "$sw")"; fi; j=$((j + 1)); done <<<"$stuck"
    fi

    # ---- 4. file-descriptor exhaustion ---------------------------------------------------------------------------
    perf fd_worst_pct "$fd_worst_pct" % "$FD_WARN" "$FD_CRIT"; perf fd_coverage "${fd_cov}/${fd_total}"
    s="$(classify "$fd_worst_pct" "$FD_WARN" "$FD_CRIT")"; bump_status "$s"
    if (( s > 0 )); then
        summary "fd usage ${fd_worst_pct}% — ${fd_worst}"
        detail "Processes near their open-files limit (raise LimitNOFILE / fix the leak BEFORE 'too many open files'):"
        local k=0 hbp hpid hc hn hsoft
        while read -r hbp hpid hc hn hsoft; do
            [[ -n "$hbp" ]] || continue
            if (( $(classify "$(( hbp / 100 )).$(( (hbp % 100) / 10 ))" "$FD_WARN" "$FD_CRIT") > 0 && k < TOP )); then
                detail "$(printf '  %3d.%d%%  pid=%-7s %-16s %s / %s fds' "$(( hbp / 100 ))" "$(( (hbp % 100) / 10 ))" "$hpid" "$hc" "$hn" "$hsoft")"; k=$((k + 1))
            fi
        done < <(printf '%s\n' "${fd_hits[@]}" | sort -rn)
    fi
    if (( fd_total > 0 && fd_cov < fd_total )); then log warn "fd info readable for only ${fd_cov}/${fd_total} processes — run as root for full coverage"; fi

    # ---- 5. pid / thread exhaustion --------------------------------------------------------------------------------
    local pid_max thr_max cg_cur cg_max worst_cap=0 cap_name=""
    pid_max="$(slurp "$PROC/sys/kernel/pid_max" 0)"; thr_max="$(slurp "$PROC/sys/kernel/threads-max" 0)"
    local cap_pct
    if (( pid_max > 0 )); then cap_pct="$(pct "$nthreads_total" "$pid_max")"; worst_cap="$cap_pct"; cap_name="pid_max"; fi
    if (( thr_max > 0 )); then cap_pct="$(pct "$nthreads_total" "$thr_max")"; if fcmp "$cap_pct" gt "$worst_cap"; then worst_cap="$cap_pct"; cap_name="threads-max"; fi; fi
    if [[ -r "$SYS/fs/cgroup/pids.max" ]]; then
        cg_max="$(slurp "$SYS/fs/cgroup/pids.max" max)"; cg_cur="$(slurp "$SYS/fs/cgroup/pids.current" 0)"
        if [[ "$cg_max" =~ ^[0-9]+$ ]] && (( cg_max > 0 )); then cap_pct="$(pct "$cg_cur" "$cg_max")"; if fcmp "$cap_pct" gt "$worst_cap"; then worst_cap="$cap_pct"; cap_name="cgroup pids.max"; fi; fi
    fi
    perf pid_capacity_pct "$worst_cap" % "$PID_WARN" "$PID_CRIT"
    s="$(classify "$worst_cap" "$PID_WARN" "$PID_CRIT")"; bump_status "$s"
    if (( s > 0 )); then summary "task table ${worst_cap}% of ${cap_name} — fork bomb or thread leak?"; fi

    # ---- 6. required processes + crash-loop detection --------------------------------------------------------------
    if [[ -n "$REQUIRE" ]]; then
        local item name min have_n age_n
        local -a items; IFS=',' read -ra items <<<"$REQUIRE"
        for item in "${items[@]}"; do
            name="${item%%:*}"; min=1; [[ "$item" == *:* ]] && min="${item##*:}"
            [[ "$min" =~ ^[0-9]+$ ]] || die "invalid --require entry '$item'"
            name="${name:0:15}"; have_n="${NAMECOUNT[$name]:-0}"
            perf "running_${name//[^A-Za-z0-9]/_}" "$have_n"
            if (( have_n < min )); then bump_status 2; summary "${name}: ${have_n}/${min} running"; detail "CRITICAL required process '${name}' — found ${have_n}, need at least ${min}"
            else
                age_n="${NAMEAGE[$name]:-0}"
                if (( age_n < RESPAWN_WINDOW )); then bump_status 1; summary "${name} restarted ${age_n}s ago"; detail "WARNING '${name}' is only ${age_n}s old (< ${RESPAWN_WINDOW}s) — recent restart/crash loop? check journalctl -u ${name}"; fi
            fi
        done
    fi

    # ---- 7. systemd failed units (opt-in) ----------------------------------------------------------------------------
    if (( FAILED_UNITS )); then
        if have systemctl; then
            local out nf=0
            if out="$(with_timeout 10 systemctl --failed --no-legend --plain 2>/dev/null)"; then
                if [[ -n "$out" ]]; then nf="$(grep -c . <<<"$out")"; fi
                perf failed_units "$nf" "" "$UNITS_WARN" "$UNITS_CRIT"
                s="$(classify "$nf" "$UNITS_WARN" "$UNITS_CRIT")"; bump_status "$s"
                if (( nf > 0 )); then summary "${nf} failed systemd unit(s)"; while read -r u _; do [[ -n "$u" ]] && detail "  failed unit: $u"; done <<<"$out"; fi
            else log warn "systemctl --failed did not succeed (not systemd? timeout?) — skipped"; fi
        else log warn "--failed-units requested but systemctl not found"; fi
    fi

    # ---- 8. biggest memory consumers (context for the on-call) ------------------------------------------------------------
    if (( OVERALL_STATUS > 0 && TOP > 0 )); then
        detail "Largest processes by RSS:"
        local r=0 rk rp rc2
        while read -r rk rp rc2; do [[ -n "$rk" ]] || continue; if (( r < TOP )); then detail "$(printf '  pid=%-7s %-16s %8d MiB' "$rp" "$rc2" "$(( rk / 1024 ))")"; fi; r=$((r + 1)); done < <(printf '%s\n' "${rss_lines[@]}" | sort -rn)
    fi
    finish
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
