#!/usr/bin/env bash
# Tests for load_check.sh.  CPU rates need two samples, so each scenario rewrites the fake /proc/stat
# in the BACKGROUND, 0.4s into the 1s sample window — the script sees a genuine delta, no test hooks in prod code.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$HERE/.."
export LOG_LEVEL=error
N="$(nproc)"                                  # load is normalised by CPU count → derive loads from it so tests are portable
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
fresh_state() { SYSMON_STATE_DIR="$(mktemp -d)"; export SYSMON_STATE_DIR; }
EMPTYSYS="$(mktemp -d)"

# statfile PATH  "name u n s i w irq sirq steal" ...   → writes /proc/stat-style content
statfile() { local f="$1"; shift; : > "$f"; local l; for l in "$@"; do printf '%s %s 0 0\n' "${l%% *}" "${l#* }" >> "$f"; done; }
# mk LOAD1 [psi_cpu] [psi_io]
mk() {
    local d; d="$(mktemp -d)"; mkdir -p "$d/pressure" "$d/sys/kernel"; echo testhost > "$d/sys/kernel/hostname"
    awk -v n="$N" -v m="$1" 'BEGIN{printf "%.2f %.2f %.2f 1/200 999\n", n*m, n*m, n*m}' > "$d/loadavg"
    statfile "$d/stat" "cpu 0 0 0 0 0 0 0 0" "cpu0 0 0 0 0 0 0 0 0"
    printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\n' "${2:-0.00}" > "$d/pressure/cpu"
    printf 'some avg10=%s avg60=0.00 avg300=0.00 total=0\n' "${3:-0.00}" > "$d/pressure/io"
    printf '%s' "$d"
}
# go FIXTURE FINAL_STAT [args]  → starts the background rewrite, runs the check with a 1s window; sets OUT, RC
go() {
    local fx="$1" final="$2"; shift 2; fresh_state
    ( sleep 0.4; cp "$final" "$fx/stat" ) &
    OUT="$(SYSMON_PROC="$fx" SYSMON_SYS="${SYSD:-$EMPTYSYS}" bash "$ROOT/load_check.sh" --interval 1 "$@" 2>&1)"; RC=$?
    wait
}
chk() {  # chk WANT_RC "label" [grep -E pattern]
    if (( RC != $1 )); then bad "$2 (want rc=$1 got rc=$RC): ${OUT:0:300}"; return; fi
    if [[ -n "${3:-}" ]] && ! grep -qE -- "$3" <<<"$OUT"; then bad "$2 (rc ok but missing /$3/): ${OUT:0:300}"; return; fi
    ok
}
T="$(mktemp -d)"

# ---------------- scenarios -------------------------------------------------------------------------
statfile "$T/idle"   "cpu 50 0 50 900 0 0 0 0"   "cpu0 50 0 50 900 0 0 0 0"
FX="$(mk 0.1)"; go "$FX" "$T/idle";                                                chk 0 "healthy & idle" '^OK: load .*cpu busy 10\.0%'

statfile "$T/io"     "cpu 50 0 50 300 600 0 0 0" "cpu0 50 0 50 300 600 0 0 0"
FX="$(mk 0.1)"; go "$FX" "$T/io";                                                  chk 2 "iowait 60% → CRITICAL" 'diagnosis: I/O-bound — iowait 60\.0%'

statfile "$T/steal"  "cpu 300 0 0 400 0 0 0 300" "cpu0 300 0 0 400 0 0 0 300"
FX="$(mk 0.1)"; go "$FX" "$T/steal";                                               chk 2 "steal 30% → CRITICAL" 'hypervisor CPU steal 30\.0%'

statfile "$T/usr"    "cpu 900 0 0 100 0 0 0 0"   "cpu0 900 0 0 100 0 0 0 0"
FX="$(mk 2.5)"; go "$FX" "$T/usr";                                                 chk 2 "CPU-bound userspace" 'CPU-bound in userspace \(user 90\.0%'

statfile "$T/sys"    "cpu 100 0 800 100 0 0 0 0" "cpu0 100 0 800 100 0 0 0 0"
FX="$(mk 2.5)"; go "$FX" "$T/sys";                                                 chk 2 "CPU-bound kernel heavy" 'kernel-heavy \(sys 80\.0% > user 10\.0%'

statfile "$T/1core"  "cpu 1000 0 0 3000 0 0 0 0" "cpu0 1000 0 0 0 0 0 0 0" "cpu1 0 0 0 1000 0 0 0 0" "cpu2 0 0 0 1000 0 0 0 0" "cpu3 0 0 0 1000 0 0 0 0"
FX="$(mk 2.5)"; go "$FX" "$T/1core";                                               chk 2 "single saturated core detected" 'single-thread bottleneck — one core at 100\.0% while average is 25\.0%'
grep -q '1 of 4 core(s)' <<<"$OUT" && ok || bad "hot core detail missing: $OUT"

statfile "$T/hi"     "cpu 900 0 0 100 0 0 0 0"   "cpu0 900 0 0 100 0 0 0 0"
FX="$(mk 0.1)"; go "$FX" "$T/hi";                                                  chk 0 "90% busy but NO queue → OK (USE method: saturation, not utilisation)" '^OK:'
FX="$(mk 0.1)"; go "$FX" "$T/hi" --cpu-warn 80 --cpu-crit 95;                      chk 1 "…unless you opt in to a utilisation threshold" '^WARNING:'

FX="$(mk 3)";   go "$FX" "$T/idle" --confirm 3;                                    chk 1 "load ratio 3.0 first run, --confirm 3 → WARNING" 'unconfirmed 1/3'

# ---------------- persistent vs transient D-state -----------------------------------------------------
FX="$(mk 0.1)"; mkdir -p "$FX/4242"
echo "4242 (my daemon) D 1 4242 4242 0 -1 4194560 100 0 0 0 1 1 0 0 20 0 1 0 100 1000 100 18446744073709551615" > "$FX/4242/stat"; echo "nfs_wait_bit_killable" > "$FX/4242/wchan"
go "$FX" "$T/idle";                                                                chk 1 "persistent D-state → WARNING" '1 process\(es\) stuck in D-state'
grep -q 'pid=4242 .*my_daemon .*wchan=nfs_wait_bit_killable' <<<"$OUT" && ok || bad "D-state detail line missing/incorrect: $OUT"

FX="$(mk 0.1)"; mkdir -p "$FX/4242"
echo "4242 (flaky) D 1 4242 4242 0 -1 4194560 100 0 0 0 1 1 0 0 20 0 1 0 100 1000 100 18446744073709551615" > "$FX/4242/stat"
echo "io_schedule" > "$FX/4242/wchan"
fresh_state; ( sleep 0.4; rm -rf "$FX/4242" ) &
OUT="$(SYSMON_PROC="$FX" SYSMON_SYS="$EMPTYSYS" bash "$ROOT/load_check.sh" --interval 1 2>&1)"; RC=$?; wait
chk 0 "TRANSIENT D-state (gone by 2nd sample) must NOT alert" '^OK:'

FX="$(mk 0.1)"; mkdir -p "$FX/4242"; echo "4242 (flaky) D 1 4242 4242 0" > "$FX/4242/stat"; echo io_schedule > "$FX/4242/wchan"
fresh_state; OUT="$(SYSMON_PROC="$FX" SYSMON_SYS="$EMPTYSYS" bash "$ROOT/load_check.sh" --interval 0 2>&1)"; RC=$?
chk 1 "--interval 0 cannot prove persistence → reports what it sees" 'stuck in D-state'

# 5+ stuck processes → CRITICAL
FX="$(mk 0.1)"; for p in 11 12 13 14 15; do mkdir -p "$FX/$p"; echo "$p (hung) D 1 0 0 0" > "$FX/$p/stat"; echo xfs_log_force > "$FX/$p/wchan"; done
fresh_state; OUT="$(SYSMON_PROC="$FX" SYSMON_SYS="$EMPTYSYS" bash "$ROOT/load_check.sh" --interval 1 2>&1)"; RC=$?
chk 2 "5 stuck D-state processes → CRITICAL" '5 process\(es\) stuck'

# ---------------- cgroup throttling, PSI, cgroup quota ---------------------------------------------------
SYSD="$(mktemp -d)"; mkdir -p "$SYSD/fs/cgroup"; printf 'nr_periods 100\nnr_throttled 10\nthrottled_usec 5\n' > "$SYSD/fs/cgroup/cpu.stat"
FX="$(mk 2.5)"
( sleep 0.4; printf 'nr_periods 200\nnr_throttled 60\nthrottled_usec 99\n' > "$SYSD/fs/cgroup/cpu.stat" ) &
go "$FX" "$T/idle";                                                                chk 2 "cgroup throttling detected" 'cgroup CPU throttling \(50 periods\)'
SYSD=""

FX="$(mk 0.1 70.00)"; go "$FX" "$T/idle";                                          chk 2 "PSI cpu 70% → CRITICAL" ''
FX="$(mk 0.1 0.00 25.00)"; go "$FX" "$T/idle";                                     chk 1 "PSI io 25% → WARNING" ''

SYSD="$(mktemp -d)"; mkdir -p "$SYSD/fs/cgroup"; echo "50000 100000" > "$SYSD/fs/cgroup/cpu.max"   # 0.5 CPU quota
FX="$(mk 0.1)"; go "$FX" "$T/idle";                                                chk 0 "cgroup quota → effective cpus" 'on 0\.50 CPU'
SYSD=""

# ---------------- output formats / errors / smoke ----------------------------------------------------------
FX="$(mk 0.1)"; go "$FX" "$T/idle" -f json
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["check"]=="load" and d["status"]=="OK" and "load_per_cpu" in d["metrics"] and d["metrics"]["cpu_busy_pct"]==10.0' "$OUT" && ok || bad "json: $OUT"
FX="$(mk 0.1)"; go "$FX" "$T/idle" -f prom; grep -q '^sysmon_load_cpu_busy_pct 10.0$' <<<"$OUT" && ok || bad "prom: $OUT"

fresh_state; SYSMON_PROC="$(mktemp -d)" bash "$ROOT/load_check.sh" >/dev/null 2>&1; rc=$?;     (( rc == 3 )) && ok || bad "unreadable /proc → UNKNOWN (rc=$rc)"
fresh_state; bash "$ROOT/load_check.sh" --bogus >/dev/null 2>&1; rc=$?;                         (( rc == 3 )) && ok || bad "bad option → 3 (rc=$rc)"
fresh_state; bash "$ROOT/load_check.sh" -w abc --interval 0 >/dev/null 2>&1; rc=$?;             (( rc == 3 )) && ok || bad "bad range → 3 (rc=$rc)"

fresh_state; unset SYSMON_PROC SYSMON_SYS; OUT="$(bash "$ROOT/load_check.sh" --interval 1 2>&1)"; rc=$?
(( rc <= 3 )) && grep -qE '^(OK|WARNING|CRITICAL|UNKNOWN): load ' <<<"$OUT" && ok || bad "real system smoke (rc=$rc): $OUT"

printf '\nload_check: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
