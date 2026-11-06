#!/usr/bin/env bash
# Unit tests for lib/common.sh — plain bash, no framework needed.   Run: ./tests/test_lib.sh
set -uo pipefail          # NOT errexit: a test harness must keep going after a failing assertion
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export SYSMON_STATE_DIR; SYSMON_STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$SYSMON_STATE_DIR"' EXIT
export LOG_LEVEL=error SCRIPT_NAME=test_lib
# shellcheck source=../lib/common.sh
source "$HERE/../lib/common.sh"
set +o errexit            # the library enables errexit; the harness must not die on a failing command

pass=0; fail=0
ok()   { pass=$((pass + 1)); }
bad()  { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
assert_eq()  { if [[ "$1" == "$2" ]]; then ok; else bad "$3 (expected '$2', got '$1')"; fi; }
assert_rc()  { local want="$1" name="$2"; shift 2; "$@" >/dev/null 2>&1; local got=$?; if (( got == want )); then ok; else bad "$name (expected rc=$want, got rc=$got)"; fi; }

# ---- Nagios range syntax: exit 0 = ALERT, 1 = fine, 2 = invalid ----------------------------------
assert_rc 1 "5 within 10"          range_alert 5 10
assert_rc 0 "11 outside 10"        range_alert 11 10
assert_rc 0 "-1 outside 10 (neg)"  range_alert -1 10
assert_rc 0 "5 < 10:"              range_alert 5 "10:"
assert_rc 1 "15 ok for 10:"        range_alert 15 "10:"
assert_rc 0 "15 > ~:10"            range_alert 15 "~:10"
assert_rc 1 "5 ok for ~:10"        range_alert 5 "~:10"
assert_rc 1 "15 in 10:20"          range_alert 15 "10:20"
assert_rc 0 "25 out of 10:20"      range_alert 25 "10:20"
assert_rc 0 "5 out of 10:20"       range_alert 5 "10:20"
assert_rc 0 "15 inside @10:20"     range_alert 15 "@10:20"
assert_rc 1 "25 outside @10:20"    range_alert 25 "@10:20"
assert_rc 2 "non-numeric value"    range_alert abc 10
assert_rc 2 "garbage range"        range_alert 5 "x:y"

# ---- classify: critical wins over warning -----------------------------------------------------
assert_eq "$(classify 95 80 90)" 2 "95 vs w80/c90 → CRIT"
assert_eq "$(classify 85 80 90)" 1 "85 vs w80/c90 → WARN"
assert_eq "$(classify 50 80 90)" 0 "50 vs w80/c90 → OK"
assert_eq "$(classify 5 20: 10:)" 2 "5 vs 'less than' ranges → CRIT"
assert_eq "$(classify 15 20: 10:)" 1 "15 vs 'less than' ranges → WARN"
assert_eq "$(classify 7 '' '')" 0 "no thresholds → OK"

# ---- numeric helpers ---------------------------------------------------------------------------
assert_eq "$(pct 1 3)" "33.3" "pct 1/3"
assert_eq "$(pct 5 0)" "0.0" "pct divide-by-zero is safe"
fcmp 1.5 lt 2 && ok || bad "fcmp 1.5 lt 2"
fcmp 3 lt 2 && bad "fcmp 3 lt 2 should be false" || ok

# ---- JSON escaping (a wrong escape = invalid JSON = broken pipeline) ---------------------------
assert_eq "$(json_escape 'a"b\c')" 'a\"b\\c' "escape quote+backslash"
assert_eq "$(json_escape $'l1\nl2\ttab')" 'l1\nl2\ttab' "escape newline+tab"

# ---- state store: atomic, and key whitelist blocks path traversal -----------------------------
state_set k1 hello; assert_eq "$(state_get k1)" hello "state roundtrip"
assert_eq "$(state_get missing dflt)" dflt "state default"
( state_get '../../etc/passwd' >/dev/null 2>&1 ); (( $? != 0 )) && ok || bad "path traversal key must be rejected"
k1="$(state_key '/var/lib/my mount')"; k2="$(state_key '/var/lib/my_mount')"
[[ "$k1" != "$k2" ]] && ok || bad "state_key must not collide for different inputs"

# ---- hysteresis: CRIT only reported after N consecutive runs -----------------------------------
rm -f "$SYSMON_STATE_DIR"/streak.*
apply_hysteresis 2 t1 3; assert_eq "$HYST_STATUS" 1 "1st CRIT run downgraded"
apply_hysteresis 2 t1 3; assert_eq "$HYST_STATUS" 1 "2nd CRIT run downgraded"
apply_hysteresis 2 t1 3; assert_eq "$HYST_STATUS" 2 "3rd CRIT run confirmed"
apply_hysteresis 0 t1 3; assert_eq "$HYST_STATUS" 0 "recovery resets"
apply_hysteresis 2 t1 3; assert_eq "$HYST_STATUS" 1 "streak restarted after recovery"

# ---- status aggregation ------------------------------------------------------------------------
OVERALL_STATUS=0; bump_status 1; bump_status 0; assert_eq "$OVERALL_STATUS" 1 "warn sticks"
bump_status 3; assert_eq "$OVERALL_STATUS" 3 "unknown outranks warn"
bump_status 2; assert_eq "$OVERALL_STATUS" 2 "crit outranks unknown"
bump_status 0; assert_eq "$OVERALL_STATUS" 2 "OK never lowers"

# ---- retry with backoff -------------------------------------------------------------------------
cnt="$SYSMON_STATE_DIR/cnt"; echo 0 > "$cnt"
flaky() { local n; n="$(< "$cnt")"; n=$((n + 1)); echo "$n" > "$cnt"; (( n >= 3 )); }
retry 5 0 -- flaky && ok || bad "retry should succeed on 3rd attempt"
assert_eq "$(< "$cnt")" 3 "retry stopped as soon as it succeeded"
retry 2 0 -- false; assert_eq "$?" 1 "retry returns the last rc when attempts exhausted"

# ---- lock: second instance must not get the lock -----------------------------------------------
acquire_lock unit && ok || bad "first lock should succeed"
( acquire_lock unit ) && bad "second lock must fail while held" || ok

# ---- /proc/net/snmp style header/value parsing --------------------------------------------------
snmp="$SYSMON_STATE_DIR/snmp"
printf 'Tcp: RtoAlgorithm OutSegs RetransSegs\nTcp: 1 1000 25\nUdp: InDatagrams\nUdp: 7\n' > "$snmp"
assert_eq "$(proc_net_get "$snmp" Tcp RetransSegs)" 25 "proc_net_get Tcp RetransSegs"
assert_eq "$(proc_net_get "$snmp" Udp InDatagrams)" 7 "proc_net_get Udp InDatagrams"

# ---- PSI + vmstat helpers against a fixture ----------------------------------------------------
fx="$(mktemp -d)"; mkdir -p "$fx/pressure"
printf 'some avg10=12.50 avg60=3.00 avg300=1.00 total=99\nfull avg10=4.00 avg60=1.00 avg300=0.50 total=9\n' > "$fx/pressure/memory"
printf 'pswpin 10\noom_kill 3\n' > "$fx/vmstat"
PROC="$fx"
assert_eq "$(psi_avg10 memory)" "12.50" "psi some avg10"
assert_eq "$(psi_avg10 memory full)" "4.00" "psi full avg10"
assert_eq "$(psi_avg10 cpu)" "" "psi missing file → empty"
assert_eq "$(vmstat_counter oom_kill)" 3 "vmstat counter"
assert_eq "$(vmstat_counter nope)" "" "vmstat missing counter → empty"
PROC=/proc; rm -rf "$fx"

# ---- tcp_state_counts: regression test — the last state pair must not produce an empty-named entry ----
fx2="$(mktemp -d)"; mkdir -p "$fx2/net"
printf '  sl local rem st\n   0: A B 01 x\n   1: A B 01 x\n   2: A B 08 x\n   3: A B 0A x\n' > "$fx2/net/tcp"; : > "$fx2/net/tcp6"
PROC="$fx2"; tc="$(tcp_state_counts)"; PROC=/proc
[[ "$tc" == *"ESTAB=2 "* && "$tc" == *"CLOSE_WAIT=1 "* && "$tc" == *"LISTEN=1 "* ]] && ok || bad "tcp_state_counts wrong: $tc"
[[ "$tc" != *" =0 "* && "$tc" != "="* ]] && ok || bad "tcp_state_counts emitted an empty-named entry: $tc"
rm -rf "$fx2"

# ---- output contract: JSON must be valid, prom must be numeric ---------------------------------
OUTPUT_FORMAT=json; CHECK_NAME=unit; perf used_pct 42.5 % 80 90; perf label "a\"b"; detail 'line "1"'; summary 'all fine'
out="$(emit_result 0 'all fine')"
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["status"]=="OK" and d["metrics"]["used_pct"]==42.5 and d["details"][0]=="line \"1\""' "$out" \
    && ok || bad "emit_result json is not valid / wrong content: $out"
OUTPUT_FORMAT=prom
out="$(emit_result 1 x)"
grep -q '^sysmon_unit_used_pct 42.5$' <<<"$out" && grep -q '^sysmon_unit_status 1$' <<<"$out" && ok || bad "prom output wrong: $out"
OUTPUT_FORMAT=nagios
out="$(emit_result 2 'boom')"
grep -q "^CRITICAL: boom | used_pct=42.5%;80;90" <<<"$out" && ok || bad "nagios output wrong: $out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
