#!/usr/bin/env bash
# Tests for run_all.sh — parallel execution, aggregation, timeouts, crash isolation, locking, atomic prom file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$HERE/.."
export LOG_LEVEL=error
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
fresh_state() { SYSMON_STATE_DIR="$(mktemp -d)"; export SYSMON_STATE_DIR; }
FAST=(--mem-args "--interval 1" --load-args "--interval 1" --disk-args "--interval 1" --proc-args "--interval 1" --net-args "--interval 1")
run() { fresh_state; OUT="$(bash "${RUNNER:-$ROOT/run_all.sh}" "$@" 2>&1)"; RC=$?; }
chk() { if (( RC != $1 )); then bad "$2 (want rc=$1 got rc=$RC): ${OUT:0:500}"; return; fi
        if [[ -n "${3:-}" ]] && ! grep -qE -- "$3" <<<"$OUT"; then bad "$2 (rc ok, missing /$3/): ${OUT:0:500}"; return; fi; ok; }

# ---------------- parallelism & real-system output ---------------------------------------------------------------------
start=$SECONDS; run "${FAST[@]}"; took=$((SECONDS - start))
(( RC <= 3 )) && grep -qE '^(OK|WARNING|CRITICAL|UNKNOWN): ' <<<"$OUT" && ok || bad "text output (rc=$RC): ${OUT:0:300}"
for c in mem load disk proc net; do grep -qE "^ +[A-Z]+ +${c} *:" <<<"$OUT" && ok || bad "text output missing a line for '$c': ${OUT:0:400}"; done
(( took <= 9 )) && ok || bad "5 checks with 1s windows ran SEQUENTIALLY? took ${took}s (should be ~2-4s)"

# ---------------- json ---------------------------------------------------------------------------------------------------------
run "${FAST[@]}" -f json; json_rc=$RC
python3 - "$OUT" "$json_rc" <<'EOF' && ok || bad "json aggregate invalid: ${OUT:0:400}"
import json, sys
d = json.loads(sys.argv[1]); rc = int(sys.argv[2])
names = [c["check"] for c in d["checks"]]
assert sorted(names) == ["disk", "load", "mem", "net", "proc"], names
rank = {0: 1, 1: 2, 3: 3, 2: 4}
worst = max((c["status_code"] for c in d["checks"]), key=lambda s: rank[s])
assert d["status_code"] == worst == rc, (d["status_code"], worst, rc)
assert d["host"] and d["timestamp"].endswith("Z")
EOF

# ---------------- prom ----------------------------------------------------------------------------------------------------------
run "${FAST[@]}" -f prom
grep -q '^sysmon_overall_status [0-3]$' <<<"$OUT" && grep -q '^sysmon_mem_status [0-3]$' <<<"$OUT" && grep -q '^sysmon_net_status [0-3]$' <<<"$OUT" && ok || bad "prom output: ${OUT:0:300}"
PD="$(mktemp -d)"; run "${FAST[@]}" -f prom --prom-file "$PD/sysmon.prom"
[[ -s "$PD/sysmon.prom" ]] && grep -q 'sysmon_overall_status' "$PD/sysmon.prom" && ok || bad "prom file not written"
(( $(ls -A "$PD" | wc -l) == 1 )) && ok || bad "temp files left behind (write must be atomic via rename): $(ls -A "$PD")"
[[ -z "$OUT" ]] && ok || bad "with --prom-file nothing should go to stdout: $OUT"

# ---------------- selection & validation ------------------------------------------------------------------------------------------
run "${FAST[@]}" -c mem,net;                    (( RC <= 3 )) && grep -q ' mem ' <<<"$OUT" && ! grep -q ' disk ' <<<"$OUT" && ok || bad "--checks subset: $OUT"
run -c bogus;                                    chk 3 "unknown check name" ''
run -f xml;                                       chk 3 "unknown format" ''
run -t 0;                                          chk 3 "zero timeout rejected" ''
run -t abc;                                         chk 3 "non-numeric timeout rejected" ''
run --bogus;                                         chk 3 "bad option" ''

# ---------------- aggregation with a deterministic CRITICAL -------------------------------------------------------------------------
FX="$(mktemp -d)"; mkdir -p "$FX/pressure" "$FX/sys/kernel"; echo testhost > "$FX/sys/kernel/hostname"
printf 'MemTotal: 1000000 kB\nMemFree: 1000 kB\nMemAvailable: 40000 kB\n' > "$FX/meminfo"; printf 'oom_kill 0\n' > "$FX/vmstat"
fresh_state; OUT="$(SYSMON_PROC="$FX" bash "$ROOT/run_all.sh" -c mem --mem-args "--interval 0" 2>&1)"; RC=$?
chk 2 "overall = worst: CRITICAL memory → rc 2" '^CRITICAL: 1 of 1 checks not OK \(mem\)'
grep -qE '^ +CRITICAL +mem +:' <<<"$OUT" && ok || bad "per-check line: $OUT"

# ---------------- timeout: a stuck check must not stall the run ------------------------------------------------------------------------
start=$SECONDS; run -c mem,load -t 1 --mem-args "--interval 8" --load-args "--interval 0"; took=$((SECONDS - start))
chk 3 "check exceeding --timeout → UNKNOWN" 'UNKNOWN +mem +: mem check timed out after 1s'
grep -qE '^ +(OK|WARNING|CRITICAL) +load' <<<"$OUT" && ok || bad "other checks must still report when one times out: $OUT"
(( took <= 12 )) && ok || bad "timeout did not bound the run (took ${took}s)"
run -c mem,load -t 1 --mem-args "--interval 8" --load-args "--interval 0" -f json
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); m=[c for c in d["checks"] if c["check"]=="mem"][0]; assert m["status"]=="UNKNOWN" and "timed out" in m["summary"] and d["status_code"]==3' "$OUT" && ok || bad "json with a timed-out check must stay valid: $OUT"

# ---------------- crash isolation -------------------------------------------------------------------------------------------------------------
TMPR="$(mktemp -d)"; cp -r "$ROOT/." "$TMPR/"; printf '#!/usr/bin/env bash\necho oops >&2\nexit 7\n' > "$TMPR/mem_check.sh"
RUNNER="$TMPR/run_all.sh" run -c mem,load --load-args "--interval 0";   chk 3 "a crashing check is reported, not fatal" 'mem check crashed \(rc=7\): oops'
grep -qE '^ +(OK|WARNING|CRITICAL) +load' <<<"$OUT" && ok || bad "healthy checks must survive a crashing sibling: $OUT"
RUNNER=""

# ---------------- locking: overlapping runs are refused ---------------------------------------------------------------------------------------
LS="$(mktemp -d)"
( SYSMON_STATE_DIR="$LS" bash "$ROOT/run_all.sh" -c mem --mem-args "--interval 4" >/dev/null 2>&1 ) & FIRST=$!
sleep 1
OUT="$(SYSMON_STATE_DIR="$LS" bash "$ROOT/run_all.sh" -c mem --mem-args "--interval 0" 2>&1)"; RC=$?
chk 3 "second concurrent run is refused" 'previous run_all still running'
wait "$FIRST"
OUT="$(SYSMON_STATE_DIR="$LS" bash "$ROOT/run_all.sh" -c mem --mem-args "--interval 0" 2>&1)"; RC=$?
(( RC <= 2 )) && ok || bad "lock must be released when the first run finishes (rc=$RC): $OUT"

printf '\nrun_all: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
