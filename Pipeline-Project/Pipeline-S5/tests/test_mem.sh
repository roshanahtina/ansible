#!/usr/bin/env bash
# Tests for mem_check.sh using fake /proc fixtures (SYSMON_PROC) — deterministic, no real memory pressure needed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$HERE/.."
export LOG_LEVEL=error
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }

fresh_state() { SYSMON_STATE_DIR="$(mktemp -d)"; export SYSMON_STATE_DIR; }
# mk_fixture TOTAL_KB AVAIL_KB [pswpin pswpout oom_kill psi_avg10]
mk_fixture() {
    local d; d="$(mktemp -d)"; mkdir -p "$d/pressure" "$d/sys/kernel"; echo testhost > "$d/sys/kernel/hostname"
    printf 'MemTotal: %s kB\nMemFree: 1000 kB\nMemAvailable: %s kB\nSwapTotal: 1000000 kB\nSwapFree: 900000 kB\nSUnreclaim: 20480 kB\n' "$1" "$2" > "$d/meminfo"
    printf 'pswpin %s\npswpout %s\noom_kill %s\n' "${3:-0}" "${4:-0}" "${5:-0}" > "$d/vmstat"
    printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\nfull avg10=0.00 avg60=0.00 avg300=0.00 total=0\n' "${6:-0.00}" > "$d/pressure/memory"
    printf '%s' "$d"
}
run() { SYSMON_PROC="$FIX" bash "$ROOT/mem_check.sh" --interval 0 "$@"; }   # prints stdout; rc via $?
expect() {  # expect RC "label" [extra args...]  — runs against $FIX with fresh state
    local want="$1" label="$2"; shift 2; fresh_state
    OUT="$(run "$@" 2>&1)"; local rc=$?
    if (( rc == want )); then ok; else bad "$label (want rc=$want got rc=$rc)  out: ${OUT:0:160}"; fi
}

FIX="$(mk_fixture 1000000 800000)"; expect 0 "healthy 20% used"
grep -q '^OK: 20.0% used' <<<"$OUT" && ok || bad "healthy output text: $OUT"
FIX="$(mk_fixture 1000000 150000)"; expect 1 "85% used → WARNING"
FIX="$(mk_fixture 1000000 50000)";  expect 2 "95% used → CRITICAL"
FIX="$(mk_fixture 1000000 50000)";  expect 1 "custom thresholds -w 99 -c 100 → WARNING at 95%" -w 90 -c 99
FIX="$(mk_fixture 1000000 800000)"; expect 2 "'less-than' range on used% (-c 10:)" -c "30:"

# available% semantics with a 'low available' range is not what -w means; verify PSI thresholds instead
FIX="$(mk_fixture 1000000 800000 0 0 0 55.00)"; expect 2 "PSI 55% → CRITICAL"
grep -q 'memory pressure 55.00%' <<<"$OUT" && ok || bad "PSI text: $OUT"
FIX="$(mk_fixture 1000000 800000 0 0 0 15.00)"; expect 1 "PSI 15% → WARNING"

# MemAvailable missing → fallback approximation, must still work
FIX="$(mk_fixture 1000000 1)"; sed -i '/MemAvailable/d' "$FIX/meminfo"; expect 0 "no MemAvailable → fallback does not crash" -w 100 -c 100

# OOM counter: first run records a baseline (no alert), next run with a higher counter → CRITICAL
fresh_state; FIX="$(mk_fixture 1000000 800000 0 0 5)"
run >/dev/null 2>&1; rc=$?; (( rc == 0 )) && ok || bad "OOM first run must only record a baseline (rc=$rc)"
sed -i 's/oom_kill 5/oom_kill 7/' "$FIX/vmstat"
OUT="$(run 2>&1)"; rc=$?; (( rc == 2 )) && grep -q '2 OOM kill(s)' <<<"$OUT" && ok || bad "OOM delta of 2 must be CRITICAL (rc=$rc) $OUT"
OUT="$(run 2>&1)"; rc=$?; (( rc == 0 )) && ok || bad "OOM delta resets once reported (rc=$rc)"
sed -i 's/oom_kill 7/oom_kill 0/' "$FIX/vmstat"
run >/dev/null 2>&1; rc=$?; (( rc == 0 )) && ok || bad "counter reset after reboot must not alert (rc=$rc)"

# Flap suppression: CRITICAL shows as WARNING twice, CRITICAL on the 3rd consecutive run
fresh_state; FIX="$(mk_fixture 1000000 50000)"
r1="$(run --confirm 3 2>&1; echo "rc=$?")"; r2="$(run --confirm 3 2>&1; echo "rc=$?")"; r3="$(run --confirm 3 2>&1; echo "rc=$?")"
grep -q 'rc=1' <<<"$r1" && grep -q 'rc=1' <<<"$r2" && grep -q 'rc=2' <<<"$r3" && ok || bad "hysteresis sequence wrong: $r1 / $r2 / $r3"

# cgroup limit awareness (fixture SYS): host is idle but the cgroup is at 95% of its limit
FIX="$(mk_fixture 1000000 800000)"; SYSD="$(mktemp -d)"; mkdir -p "$SYSD/fs/cgroup"
echo 1000000000 > "$SYSD/fs/cgroup/memory.max"; echo 950000000 > "$SYSD/fs/cgroup/memory.current"
fresh_state; OUT="$(SYSMON_SYS="$SYSD" run 2>&1)"; rc=$?; (( rc == 2 )) && grep -q 'cgroup 95.0%' <<<"$OUT" && ok || bad "cgroup at 95% must be CRITICAL (rc=$rc) $OUT"
echo max > "$SYSD/fs/cgroup/memory.max"
fresh_state; OUT="$(SYSMON_SYS="$SYSD" run 2>&1)"; rc=$?; (( rc == 0 )) && ok || bad "'max' (unlimited) cgroup must be ignored (rc=$rc)"

# Output formats
FIX="$(mk_fixture 1000000 800000)"; fresh_state
run -f json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["check"]=="mem" and d["status"]=="OK" and d["metrics"]["used_pct"]==20.0' && ok || bad "json output"
OUT="$(run -f prom)"   # capture first: `run | grep -q` would SIGPIPE the producer and trip pipefail
grep -q '^sysmon_mem_used_pct 20.0$' <<<"$OUT" && ok || bad "prom output: $OUT"

# Error handling → UNKNOWN (3), never a stack trace
expect 3 "bad option" --bogus
expect 3 "non-numeric threshold" -w abc
expect 3 "bad format" -f xml
EMPTY="$(mktemp -d)"; fresh_state; SYSMON_PROC="$EMPTY" bash "$ROOT/mem_check.sh" >/dev/null 2>&1; rc=$?; (( rc == 3 )) && ok || bad "unreadable /proc → UNKNOWN (rc=$rc)"

# Smoke test against the REAL system
fresh_state; unset SYSMON_PROC; OUT="$(bash "$ROOT/mem_check.sh" --interval 1 2>&1)"; rc=$?
(( rc <= 3 )) && grep -qE '^(OK|WARNING|CRITICAL|UNKNOWN): ' <<<"$OUT" && ok || bad "real system smoke test (rc=$rc): $OUT"

printf '\nmem_check: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
