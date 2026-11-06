#!/usr/bin/env bash
# ============================================================================
# run_all.sh — run every check in PARALLEL, bounded by a timeout, and aggregate
#
#   * Runtime ≈ the slowest check (≈ the sample window), not the sum of all five
#   * Each check is isolated: one that crashes or hangs becomes an UNKNOWN entry, it never takes the others down
#   * flock → a slow run can never pile up behind itself when started from cron/systemd every minute
#   * Overall status = worst status (CRITICAL > UNKNOWN > WARNING > OK); exit code is that status
#   * Output: text | json (one document, valid even when checks fail) | prom (node_exporter textfile, written ATOMICALLY)
# ============================================================================
SCRIPT_NAME="run_all"; CHECK_NAME="all"
DIR="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
# shellcheck source=lib/common.sh
source "$DIR/lib/common.sh"

declare -A SCRIPT=([mem]=mem_check.sh [load]=load_check.sh [disk]=disk_check.sh [proc]=process_check.sh [net]=network_check.sh)
declare -A EXTRA=()
CHECKS="mem,load,disk,proc,net"; TIMEOUT=30; FORMAT=text; PROM_FILE=""

usage() { cat <<'EOF'
Usage: run_all.sh [options]
  -c, --checks LIST       comma list from: mem,load,disk,proc,net          [all]
  -t, --timeout SECS      per-check hard timeout                           [30]
  -f, --format FMT        text | json | prom                               [text]
      --prom-file PATH    (prom) write atomically to PATH instead of stdout
      --mem-args  "ARGS"  extra arguments for one check (also --load-args, --disk-args, --proc-args, --net-args)
  -d, --debug   -h, --help
Extra arguments are split on whitespace (no quoting). Exit code = worst check status (0 OK, 1 WARN, 2 CRIT, 3 UNKNOWN).
EOF
}
parse_args() {
    local parsed
    parsed="$(getopt -o 'c:t:f:dh' -l 'checks:,timeout:,format:,prom-file:,mem-args:,load-args:,disk-args:,proc-args:,net-args:,debug,help' -n "$SCRIPT_NAME" -- "$@")" \
        || { usage >&2; exit "$EXIT_UNKNOWN"; }
    eval set -- "$parsed"
    while true; do
        case "$1" in
            -c|--checks) CHECKS="$2"; shift 2 ;;     -t|--timeout) TIMEOUT="$2"; shift 2 ;;
            -f|--format) FORMAT="$2"; shift 2 ;;     --prom-file) PROM_FILE="$2"; shift 2 ;;
            --mem-args) EXTRA[mem]="$2"; shift 2 ;;  --load-args) EXTRA[load]="$2"; shift 2 ;;
            --disk-args) EXTRA[disk]="$2"; shift 2 ;; --proc-args) EXTRA[proc]="$2"; shift 2 ;;
            --net-args) EXTRA[net]="$2"; shift 2 ;;  -d|--debug) LOG_LEVEL=debug; shift ;;
            -h|--help) usage; exit 0 ;;              --) shift; break ;;
            *) die "internal option parsing error" ;;
        esac
    done
    [[ "$TIMEOUT" =~ ^[0-9]+$ ]] && (( TIMEOUT > 0 )) || die "--timeout must be a positive integer"
    case "$FORMAT" in text|json|prom) ;; *) die "unknown format '$FORMAT' (text|json|prom)" ;; esac
}

main() {
    parse_args "$@"
    local -a names; IFS=',' read -ra names <<<"$CHECKS"
    local c
    for c in "${names[@]}"; do [[ -n "${SCRIPT[$c]+x}" ]] || die "unknown check '$c' (valid: ${!SCRIPT[*]})"; done

    if ! acquire_lock run_all 0; then
        OUTPUT_FORMAT=nagios; summary "previous run_all still running — skipped to avoid pile-up"; OVERALL_STATUS=3; finish
    fi

    local td child_fmt; td="$(tmpdir)"
    case "$FORMAT" in text) child_fmt=nagios ;; *) child_fmt="$FORMAT" ;; esac

    # ---- launch everything in parallel; each job records its own exit code -----------------------------------------
    for c in "${names[@]}"; do
        # shellcheck disable=SC2086   # intentional word-splitting of the extra args
        ( rc=0; timeout --kill-after=2 "$TIMEOUT" bash "$DIR/${SCRIPT[$c]}" --format "$child_fmt" ${EXTRA[$c]:-} > "$td/$c.out" 2> "$td/$c.err" || rc=$?
          echo "$rc" > "$td/$c.rc" ) >/dev/null 2>&1 &
    done
    # poll instead of `wait`: robust even if a child is unkillable (uninterruptible sleep)
    local t n deadline=$(( (TIMEOUT + 6) * 10 ))
    for (( t=0; t<deadline; t++ )); do
        n=0; for c in "${names[@]}"; do [[ -f "$td/$c.rc" ]] && n=$((n + 1)); done
        (( n == ${#names[@]} )) && break
        sleep 0.1
    done

    # ---- collect ------------------------------------------------------------------------------------------------------
    local rc first reason label bad=0 json="" prom="" body="" sep="" badnames=""
    local -A ST=() FIRST=()
    for c in "${names[@]}"; do
        rc="$(slurp "$td/$c.rc" missing)"; reason=""
        case "$rc" in
            0|1|2|3) ;;
            124|137|missing) reason="timed out after ${TIMEOUT}s"; rc=3 ;;
            *) reason="crashed (rc=${rc}): $(head -c 200 "$td/$c.err" 2>/dev/null | head -1)"; rc=3 ;;
        esac
        ST[$c]="$rc"; bump_status "$rc"
        label="$(status_label "$rc")"
        if (( rc != 0 )); then bad=$((bad + 1)); badnames+="${badnames:+, }$c"; fi
        first="$(head -1 "$td/$c.out" 2>/dev/null || true)"
        [[ -n "$reason" ]] && first="UNKNOWN: ${c} check ${reason}"
        FIRST[$c]="$first"
        case "$FORMAT" in
            json)
                if [[ -z "$reason" ]] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$td/$c.out" 2>/dev/null; then json+="${sep}$(< "$td/$c.out")"
                else json+="${sep}{\"check\":\"$(json_escape "$c")\",\"status\":\"UNKNOWN\",\"status_code\":3,\"summary\":\"$(json_escape "${reason:-no/invalid output}")\",\"metrics\":{},\"details\":[]}"; fi
                sep="," ;;
            prom) if [[ -z "$reason" ]]; then prom+="$(< "$td/$c.out")"$'\n'; else prom+="sysmon_${c}_status 3"$'\n'; fi ;;
            text) local line="${first#*: }"; line="${line%% |*}"       # human view: drop the machine-readable perfdata after " |"
                  body+="$(printf '  %-9s %-5s: %s' "$label" "$c" "$line")"$'\n'
                  # nagios long output (details) — indent under the check
                  if [[ -z "$reason" ]]; then local extra; extra="$(tail -n +2 "$td/$c.out" 2>/dev/null | sed 's/^/      /')"; [[ -n "$extra" ]] && body+="${extra}"$'\n'; fi ;;
        esac
    done

    # ---- emit ---------------------------------------------------------------------------------------------------------------
    local overall; overall="$(status_label "$OVERALL_STATUS")"
    case "$FORMAT" in
        text)
            if (( bad == 0 )); then printf '%s: all %d checks OK\n' "$overall" "${#names[@]}"
            else printf '%s: %d of %d checks not OK (%s)\n' "$overall" "$bad" "${#names[@]}" "$badnames"; fi
            printf '%s' "$body" ;;
        json)
            printf '{"host":"%s","timestamp":"%s","status":"%s","status_code":%d,"checks":[%s]}\n' \
                "$(json_escape "$(_host)")" "$(date -u +%FT%TZ)" "$overall" "$OVERALL_STATUS" "$json" ;;
        prom)
            local doc; doc="$(printf '%s# TYPE sysmon_overall_status gauge\nsysmon_overall_status %d\n' "$prom" "$OVERALL_STATUS")"
            if [[ -n "$PROM_FILE" ]]; then
                local tmp; tmp="$(mktemp "${PROM_FILE}.XXXXXX")"; printf '%s\n' "$doc" > "$tmp"; chmod 644 "$tmp"; mv -f "$tmp" "$PROM_FILE"   # atomic: the scraper never sees a half-written file
            else printf '%s\n' "$doc"; fi ;;
    esac
    exit "$OVERALL_STATUS"
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
