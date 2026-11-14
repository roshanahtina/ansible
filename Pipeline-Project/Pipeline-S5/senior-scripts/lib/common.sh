# shellcheck shell=bash
# ============================================================================
# lib/common.sh — shared library for the sysmon checks.  SOURCE it; never execute it.
#
# Design goals (each one is an interview talking point):
#   * Bounded runtime      — every external dependency is wrapped in timeout; no check can hang (NFS!)
#   * Rates, not counters  — kernel counters are cumulative; alert on deltas over a sample window
#   * Kernel signals       — read /proc & /sys directly (oom_kill counter, PSI) instead of scraping logs
#   * Stable output contract — nagios | json | prom, identical exit codes 0/1/2/3
#   * Flap suppression     — state file + "N consecutive runs" hysteresis
#   * Testable             — all /proc and /sys reads go through $PROC / $SYS so fixtures can replace them
#   * Safe by default      — strict mode, quoted everywhere, no eval on user input, umask 077, flock
# ============================================================================

if [[ -n "${_SYSMON_COMMON_LOADED:-}" ]]; then return 0; fi
_SYSMON_COMMON_LOADED=1

set -o errexit -o nounset -o pipefail
export LC_ALL=C
umask 077

readonly EXIT_OK=0 EXIT_WARN=1 EXIT_CRIT=2 EXIT_UNKNOWN=3

PROC="${SYSMON_PROC:-/proc}"
SYS="${SYSMON_SYS:-/sys}"
LOG_LEVEL="${LOG_LEVEL:-info}"
SYSMON_STATE_DIR="${SYSMON_STATE_DIR:-${XDG_RUNTIME_DIR:-/var/tmp}/sysmon-$(id -u)}"
OUTPUT_FORMAT="${OUTPUT_FORMAT:-nagios}"
SCRIPT_NAME="${SCRIPT_NAME:-sysmon}"
CHECK_NAME="${CHECK_NAME:-check}"
OVERALL_STATUS=0
HYST_STATUS=0
HYST_NOTE=""

# ---------------------------------------------------------------- logging ----
_log_num() { case "$1" in debug) echo 0 ;; info) echo 1 ;; warn) echo 2 ;; error) echo 3 ;; *) echo 1 ;; esac; }
log() {  # log LEVEL message...   → stderr only, so stdout stays a clean machine-readable contract
    local lvl="$1"; shift
    if (( $(_log_num "$lvl") < $(_log_num "$LOG_LEVEL") )); then return 0; fi
    printf '%s [%s] %s: %s\n' "$(date -u +%FT%TZ)" "$lvl" "$SCRIPT_NAME" "$*" >&2
}
die() { log error "$*"; exit "$EXIT_UNKNOWN"; }
have() { command -v "$1" >/dev/null 2>&1; }
require_cmds() { local c; for c in "$@"; do have "$c" || die "required command not found: $c"; done; }

# ------------------------------------------- cleanup stack & signal handling ----
declare -a _CLEANUP=()
on_exit() { _CLEANUP+=("$(printf '%q ' "$@")"); }     # printf %q → safe to eval later
_run_cleanup() {
    local i
    for (( i=${#_CLEANUP[@]}-1; i>=0; i-- )); do eval "${_CLEANUP[i]}" || true; done
}
trap _run_cleanup EXIT
trap 'exit 143' TERM          # convert signals into a normal exit so the EXIT trap (cleanup) always runs
trap 'exit 130' INT
tmpdir() {  # create (once) a private temp dir that is removed automatically
    if [[ -z "${_SYSMON_TMP:-}" ]]; then
        _SYSMON_TMP="$(mktemp -d "${TMPDIR:-/tmp}/sysmon.XXXXXX")"
        on_exit rm -rf "$_SYSMON_TMP"
    fi
    printf '%s' "$_SYSMON_TMP"
}

# --------------------------------------------------- locking & timeouts ----
acquire_lock() {  # acquire_lock NAME [WAIT_SECS]  → 0 if we hold the lock, 1 if another instance has it
    local name="$1" wait="${2:-0}"
    state_init
    exec {_LOCK_FD}>"$SYSMON_STATE_DIR/$name.lock"
    if (( wait == 0 )); then flock -n "$_LOCK_FD"; else flock -w "$wait" "$_LOCK_FD"; fi
}
with_timeout() { local secs="$1"; shift; timeout --kill-after=2 "$secs" "$@"; }   # rc 124 = timed out

retry() {  # retry ATTEMPTS BASE_DELAY -- command...   exponential backoff + jitter
    local attempts="$1" delay="$2" n=1 rc s
    shift 3                                              # drop attempts, delay and the "--"
    while true; do
        if "$@"; then return 0; else rc=$?; fi
        if (( n >= attempts )); then return "$rc"; fi
        s="$(awk -v d="$delay" -v n="$n" -v r="$RANDOM" 'BEGIN{printf "%.3f", d*(2^(n-1)) + (r%100)/1000}')"
        log debug "retry $n/$attempts failed (rc=$rc); sleeping ${s}s"
        sleep "$s"
        n=$((n + 1))
    done
}

# ------------------------------------------------------------ state store ----
state_init() { if [[ ! -d "$SYSMON_STATE_DIR" ]]; then mkdir -p -m 700 "$SYSMON_STATE_DIR"; fi; }
_valid_key() { [[ "$1" =~ ^[A-Za-z0-9_.@-]+$ ]]; }       # whitelist: blocks path traversal like ../../etc
state_key() {  # turn an arbitrary string (e.g. a mount point) into a safe, collision-resistant key
    local s="$1" sum
    sum="$(printf '%s' "$s" | cksum | awk '{print $1}')"
    printf '%s.%s' "${s//[^A-Za-z0-9_.@-]/_}" "$sum"
}
state_get() {
    local key="$1" def="${2-}"
    _valid_key "$key" || die "invalid state key: $key"
    if [[ -r "$SYSMON_STATE_DIR/$key" ]]; then cat "$SYSMON_STATE_DIR/$key"; else printf '%s' "$def"; fi
}
state_set() {  # atomic write: temp file + rename → a crash can never leave a half-written state file
    local key="$1" val="$2" tmp
    _valid_key "$key" || die "invalid state key: $key"
    state_init
    tmp="$(mktemp "$SYSMON_STATE_DIR/.tmp.XXXXXX")"
    printf '%s' "$val" > "$tmp"
    mv -f "$tmp" "$SYSMON_STATE_DIR/$key"
}
now_epoch() { printf '%(%s)T' -1; }                       # builtin: no fork

# ------------------------------------------------ numeric / threshold logic ----
pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0 == 0) print "0.0"; else printf "%.1f", a*100/b }'; }
fmath() { awk "BEGIN{printf \"%.2f\", $1}"; }                 # only ever called with script-built expressions
fcmp() {  # fcmp A OP B   OP ∈ lt le gt ge eq     → exit 0 when true
    awk -v a="$1" -v b="$3" -v op="$2" 'BEGIN{
        if (op=="lt") r=(a<b); else if (op=="le") r=(a<=b); else if (op=="gt") r=(a>b);
        else if (op=="ge") r=(a>=b); else r=(a==b); exit !r }'
}
# Nagios plugin range syntax (the de-facto standard for thresholds):
#   10      alert if value <0 or >10        10:     alert if value <10
#   ~:10    alert if value >10              10:20   alert if outside 10..20
#   @10:20  alert if value is INSIDE 10..20
# exit: 0 = ALERT, 1 = no alert, 2 = invalid input
range_alert() {
    awk -v v="$1" -v r="$2" '
        function isnum(x) { return (x ~ /^[-+]?[0-9]+([.][0-9]+)?$/) }
        BEGIN {
            if (!isnum(v)) exit 2
            inv = 0; loinf = 0; hiinf = 0
            if (substr(r,1,1) == "@") { inv = 1; r = substr(r,2) }
            n = index(r, ":")
            if (n == 0) { lo = "0"; hi = r } else { lo = substr(r,1,n-1); hi = substr(r,n+1) }
            if (lo == "")  lo = "0"
            if (lo == "~") loinf = 1
            if (hi == "")  hiinf = 1
            if (!loinf && !isnum(lo)) exit 2
            if (!hiinf && !isnum(hi)) exit 2
            outside = ((!loinf && v+0 < lo+0) || (!hiinf && v+0 > hi+0))
            alert = inv ? !outside : outside
            exit (alert ? 0 : 1)
        }'
}
classify() {  # classify VALUE WARN_RANGE CRIT_RANGE → echoes 0|1|2
    local v="$1" w="${2:-}" c="${3:-}" rc=0
    if [[ -n "$c" ]]; then
        range_alert "$v" "$c" || rc=$?
        case "$rc" in 0) echo 2; return 0 ;; 1) ;; *) die "invalid critical range '$c' (value '$v')" ;; esac
    fi
    if [[ -n "$w" ]]; then
        rc=0; range_alert "$v" "$w" || rc=$?
        case "$rc" in 0) echo 1; return 0 ;; 1) ;; *) die "invalid warning range '$w' (value '$v')" ;; esac
    fi
    echo 0
}

# ------------------------------------------ status aggregation & hysteresis ----
declare -A _RANK=([0]=1 [1]=2 [3]=3 [2]=4)               # CRITICAL > UNKNOWN > WARNING > OK
bump_status() { if (( _RANK[$1] > _RANK[$OVERALL_STATUS] )); then OVERALL_STATUS="$1"; fi; }
status_label() { case "$1" in 0) echo OK ;; 1) echo WARNING ;; 2) echo CRITICAL ;; *) echo UNKNOWN ;; esac; }

consecutive_streak() {  # consecutive_streak KEY BAD(0|1) → prints current run length of BAD results
    local key="streak.$1" bad="$2" s
    s="$(state_get "$key" 0)"
    if (( bad )); then s=$((s + 1)); else s=0; fi
    state_set "$key" "$s"
    printf '%s' "$s"
}
# apply_hysteresis RAW KEY N → sets HYST_STATUS / HYST_NOTE.  CRITICAL is reported as WARNING until it
# has been seen N runs in a row.  (Sets globals instead of echoing, because $(...) would lose them.)
apply_hysteresis() {
    local raw="$1" key="$2" n="${3:-1}" streak is_crit=0
    if (( raw == 2 )); then is_crit=1; fi
    streak="$(consecutive_streak "$key" "$is_crit")"
    HYST_STATUS="$raw"; HYST_NOTE=""
    if (( raw == 2 && streak < n )); then HYST_STATUS=1; HYST_NOTE=" (unconfirmed ${streak}/${n})"; fi
}

# ------------------------------------------------------------ output layer ----
declare -a _PERF_NAMES=() _DETAILS=() _SUMMARY=()
declare -A _PERF_VAL=() _PERF_UOM=() _PERF_WARN=() _PERF_CRIT=()
perf()    { _PERF_NAMES+=("$1"); _PERF_VAL["$1"]="$2"; _PERF_UOM["$1"]="${3:-}"; _PERF_WARN["$1"]="${4:-}"; _PERF_CRIT["$1"]="${5:-}"; }
detail()  { _DETAILS+=("$*"); }
summary() { _SUMMARY+=("$*"); }
_join_summary() {
    local out="" s
    for s in "${_SUMMARY[@]+"${_SUMMARY[@]}"}"; do out+="${out:+, }${s}"; done
    printf '%s' "${out:-no data}"
}
json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\r'/\\r}"; s="${s//$'\t'/\\t}"
    printf '%s' "$s" | tr -d '\000-\037'
}
_is_num() { [[ "$1" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }
_host() { local h; h="$(< "$PROC/sys/kernel/hostname")" 2>/dev/null || h="${HOSTNAME:-unknown}"; printf '%s' "$h"; }

emit_result() {  # emit_result STATUS SUMMARY
    local status="$1" summary_txt="$2" label n first=1
    label="$(status_label "$status")"
    case "$OUTPUT_FORMAT" in
        nagios|text)
            printf '%s: %s' "$label" "$summary_txt"
            if (( ${#_PERF_NAMES[@]} > 0 )); then
                printf ' |'
                for n in "${_PERF_NAMES[@]}"; do
                    printf " %s=%s%s;%s;%s" "$n" "${_PERF_VAL[$n]}" "${_PERF_UOM[$n]}" "${_PERF_WARN[$n]}" "${_PERF_CRIT[$n]}"
                done
            fi
            printf '\n'
            if (( ${#_DETAILS[@]} > 0 )); then printf '%s\n' "${_DETAILS[@]}"; fi
            ;;
        json)
            printf '{"check":"%s","host":"%s","timestamp":"%s","status":"%s","status_code":%s,"summary":"%s","metrics":{' \
                "$(json_escape "$CHECK_NAME")" "$(json_escape "$(_host)")" "$(date -u +%FT%TZ)" "$label" "$status" "$(json_escape "$summary_txt")"
            for n in "${_PERF_NAMES[@]+"${_PERF_NAMES[@]}"}"; do
                if (( first )); then first=0; else printf ','; fi
                if _is_num "${_PERF_VAL[$n]}"; then printf '"%s":%s' "$(json_escape "$n")" "${_PERF_VAL[$n]}"
                else printf '"%s":"%s"' "$(json_escape "$n")" "$(json_escape "${_PERF_VAL[$n]}")"; fi
            done
            printf '},"details":['
            first=1
            for n in "${_DETAILS[@]+"${_DETAILS[@]}"}"; do
                if (( first )); then first=0; else printf ','; fi
                printf '"%s"' "$(json_escape "$n")"
            done
            printf ']}\n'
            ;;
        prom)  # node_exporter textfile-collector format
            printf '# TYPE sysmon_%s_status gauge\nsysmon_%s_status %s\n' "$CHECK_NAME" "$CHECK_NAME" "$status"
            for n in "${_PERF_NAMES[@]+"${_PERF_NAMES[@]}"}"; do
                if _is_num "${_PERF_VAL[$n]}"; then printf 'sysmon_%s_%s %s\n' "$CHECK_NAME" "${n//[^a-zA-Z0-9_]/_}" "${_PERF_VAL[$n]}"; fi
            done
            ;;
        *) die "unknown output format: $OUTPUT_FORMAT (use nagios|json|prom)" ;;
    esac
}
finish() { emit_result "$OVERALL_STATUS" "$(_join_summary)"; exit "$OVERALL_STATUS"; }

# ------------------------------------------------- kernel / cgroup helpers ----
vmstat_counter() { awk -v k="$1" '$1==k {print $2; exit}' "$PROC/vmstat" 2>/dev/null || true; }
psi_avg10() {  # psi_avg10 RESOURCE [some|full] → percent, or empty if PSI unavailable
    local f="$PROC/pressure/$1" kind="${2:-some}"
    if [[ -r "$f" ]]; then awk -v k="$kind" '$1==k { for(i=2;i<=NF;i++){ split($i,a,"="); if(a[1]=="avg10") print a[2] } }' "$f" 2>/dev/null || true; fi
}
proc_net_get() {  # proc_net_get FILE PROTO KEY  (parses the header-line/value-line pairs in /proc/net/snmp|netstat)
    awk -v p="$2:" -v k="$3" '$1==p { if (!h) { for (i=2;i<=NF;i++) idx[$i]=i; h=1 } else { print $(idx[k]); exit } }' "$1"
}
effective_cpus() {  # CPUs actually usable: min(online CPUs, cgroup quota/period)
    local n q p; n="$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN)"
    if [[ -r "$SYS/fs/cgroup/cpu.max" ]]; then                                  # cgroup v2
        read -r q p < "$SYS/fs/cgroup/cpu.max" || true
        if [[ "${q:-max}" != max && "${p:-0}" -gt 0 ]]; then awk -v q="$q" -v p="$p" -v n="$n" 'BEGIN{x=q/p; printf "%.2f", (x<n?x:n)}'; return 0; fi
    elif [[ -r "$SYS/fs/cgroup/cpu/cpu.cfs_quota_us" ]]; then                   # cgroup v1
        q="$(< "$SYS/fs/cgroup/cpu/cpu.cfs_quota_us")"; p="$(< "$SYS/fs/cgroup/cpu/cpu.cfs_period_us")"
        if (( q > 0 && p > 0 )); then awk -v q="$q" -v p="$p" -v n="$n" 'BEGIN{x=q/p; printf "%.2f", (x<n?x:n)}'; return 0; fi
    fi
    printf '%s' "$n"
}
cgroup_mem() {  # prints "limit_bytes usage_bytes" if a real memory limit applies to us; prints nothing otherwise
    local lim use
    if [[ -r "$SYS/fs/cgroup/memory.max" ]]; then                                # v2
        lim="$(< "$SYS/fs/cgroup/memory.max")"; use="$(< "$SYS/fs/cgroup/memory.current")"
    elif [[ -r "$SYS/fs/cgroup/memory/memory.limit_in_bytes" ]]; then            # v1
        lim="$(< "$SYS/fs/cgroup/memory/memory.limit_in_bytes")"; use="$(< "$SYS/fs/cgroup/memory/memory.usage_in_bytes")"
    else return 0; fi
    if [[ "$lim" =~ ^[0-9]+$ ]] && (( lim < 4611686018427387904 )); then printf '%s %s' "$lim" "$use"; fi   # huge value == "unlimited"
}
tcp_state_counts() {  # reads /proc/net/tcp{,6} directly (no dependency on ss) → "ESTAB=n TIME_WAIT=n CLOSE_WAIT=n ..."
    awk 'FNR>1 { c[$4]++ } END {
        split("01 ESTAB 02 SYN_SENT 03 SYN_RECV 04 FIN_WAIT1 05 FIN_WAIT2 06 TIME_WAIT 07 CLOSE 08 CLOSE_WAIT 09 LAST_ACK 0A LISTEN 0B CLOSING", m, " ")
        for (i=1;i<=21;i+=2) printf "%s=%d ", m[i+1], c[m[i]] }' "$PROC/net/tcp" "$PROC/net/tcp6" 2>/dev/null || true
}

slurp() {  # slurp PATH [DEFAULT] → first line of a file that may be missing/vanishing; never fails, never prints errors
    local _l=""; { IFS= read -r _l < "$1"; } 2>/dev/null || true; printf '%s' "${_l:-${2-}}"
}

# ---- /proc process helpers (pure bash, no ps → fixture-testable and cheap) -------------------------------
dstate_list() {  # "pid comm wchan" for every process currently in uninterruptible sleep — from /proc, no ps needed
    local f line rest comm state pid w
    for f in "$PROC"/[0-9]*/stat; do
        [[ -r "$f" ]] || continue
        line=""; { IFS= read -r line < "$f"; } 2>/dev/null || [[ -n "$line" ]] || continue
        rest="${line##*) }"; state="${rest%% *}"                  # robust even if the command name contains spaces/parens
        if [[ "$state" == D ]]; then
            pid="${f#"$PROC"/}"; pid="${pid%%/*}"
            comm="${line#*(}"; comm="${comm%)*}"; comm="${comm// /_}"      # names may contain spaces → keep output one-token-per-field
            w=""; { IFS= read -r w < "$PROC/$pid/wchan"; } 2>/dev/null || true
            printf '%s %s %s\n' "$pid" "$comm" "${w:-?}"
        fi
    done
}
proc_stat_fields() {  # proc_stat_fields PID → sets PS_COMM PS_STATE PS_PPID PS_THREADS PS_START PS_RSS ; rc 1 if the process vanished
    local line rest; local -a f
    line=""; { IFS= read -r line < "$PROC/$1/stat"; } 2>/dev/null || [[ -n "$line" ]] || return 1   # group-redirect: errors suppressed, no subshell
    rest="${line##*) }"; PS_COMM="${line#*(}"; PS_COMM="${PS_COMM%)*}"; PS_COMM="${PS_COMM// /_}"   # comm may contain spaces/parens
    read -ra f <<<"$rest"
    PS_STATE="${f[0]:-?}"; PS_PPID="${f[1]:-0}"; PS_THREADS="${f[17]:-1}"; PS_START="${f[19]:-0}"; PS_RSS="${f[21]:-0}"
}
