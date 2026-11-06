#!/usr/bin/env bash
# Tests for process_check.sh — a fake /proc is built per scenario (processes, fds, limits, D-state, zombies).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$HERE/.."
export LOG_LEVEL=error
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
fresh_state() { SYSMON_STATE_DIR="$(mktemp -d)"; export SYSMON_STATE_DIR; }

# ---- fixture builders ----------------------------------------------------------------------------------------
mk_proc() {  # mk_proc [pid_max] [threads_max]
    local d; d="$(mktemp -d)"; mkdir -p "$d/sys/kernel"
    echo testhost > "$d/sys/kernel/hostname"; echo "${1:-32768}" > "$d/sys/kernel/pid_max"; echo "${2:-100000}" > "$d/sys/kernel/threads-max"
    echo "10000.00 20000.00" > "$d/uptime"; printf '%s' "$d"
}
# addproc DIR PID COMM STATE PPID NTHREADS AGE_SECONDS RSS_PAGES [NFDS SOFT_LIMIT]
addproc() {
    local d="$1" pid="$2" comm="$3" st="$4" ppid="$5" thr="$6" age="$7" rss="$8" nfds="${9:-3}" soft="${10:-1024}" i
    local start=$(( (10000 - age) * 100 ))                        # uptime is 10000s; CLK_TCK=100
    mkdir -p "$d/$pid/fd"
    echo "$pid ($comm) $st $ppid 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 $thr 0 $start 1000000 $rss 0" > "$d/$pid/stat"
    echo "wait_event" > "$d/$pid/wchan"
    printf 'Limit                     Soft Limit           Hard Limit           Units\nMax open files            %s                 %s                 files\n' "$soft" "$soft" > "$d/$pid/limits"
    for (( i=0; i<nfds; i++ )); do : > "$d/$pid/fd/$i"; done
}
base() { local d; d="$(mk_proc "$@")"; addproc "$d" 1 systemd S 0 1 9000 500; addproc "$d" 800 sshd S 1 1 9000 300; addproc "$d" 900 bash S 800 1 100 200; printf '%s' "$d"; }

run() { fresh_state; OUT="$(SYSMON_PROC="$FX" SYSMON_SYS="${SYSD:-$(mktemp -d)}" PATH="${SHIMDIR:+$SHIMDIR:}$PATH" bash "$ROOT/process_check.sh" --interval 0 "$@" 2>&1)"; RC=$?; }
chk() { if (( RC != $1 )); then bad "$2 (want rc=$1 got rc=$RC): ${OUT:0:500}"; return; fi
        if [[ -n "${3:-}" ]] && ! grep -qE -- "$3" <<<"$OUT"; then bad "$2 (rc ok, missing /$3/): ${OUT:0:500}"; return; fi; ok; }

# ---------------- healthy / parsing robustness ------------------------------------------------------------------------
FX="$(base)"; run;                                                              chk 0 "healthy" '^OK: 3 processes / 3 threads'
FX="$(base)"; addproc "$FX" 1234 "my (weird) app" S 1 2 50 10; run;             chk 0 "command name with spaces AND parentheses parses" '4 processes / 5 threads'
FX="$(base)"; mkdir -p "$FX/777";                                                run; chk 0 "process that vanished mid-scan (no stat) is skipped" '3 processes'

# ---------------- zombies: blame the parent -----------------------------------------------------------------------------
FX="$(base)"; addproc "$FX" 500 badparent S 1 1 500 100; for p in 601 602 603 604 605 606; do addproc "$FX" $p "defunct" Z 500 1 50 0; done
run;                                                                              chk 1 "6 zombies → WARNING" '6 zombie\(s\)'
grep -q 'parent pid=500 .*badparent.* has 6 zombie' <<<"$OUT" && ok || bad "should name the PARENT: $OUT"
grep -q 'cannot be killed' <<<"$OUT" && ok || bad "should explain zombies cannot be killed: $OUT"
for p in $(seq 610 670); do addproc "$FX" $p "defunct" Z 500 1 50 0; done
run;                                                                              chk 2 "67 zombies → CRITICAL" '67 zombie'
FX="$(base)"; for p in 601 602 603 604 605 606; do addproc "$FX" $p defunct Z 999 1 50 0; done
run;                                                                              chk 1 "orphaned zombie parent (gone) is reported" 'reparented to init'
FX="$(base)"; for p in 601 602 603 604 605 606; do addproc "$FX" $p defunct Z 500 1 50 0; done; addproc "$FX" 500 badparent S 1 1 500 100
fresh_state; r1="$(SYSMON_PROC="$FX" bash "$ROOT/process_check.sh" --interval 0 --confirm 1 >/dev/null 2>&1; echo $?)"; (( r1 == 1 )) && ok || bad "zombie confirm baseline"

# ---------------- D-state: persistent vs transient ------------------------------------------------------------------------
FX="$(base)"; addproc "$FX" 4242 "nfs worker" D 1 1 500 10
fresh_state; OUT="$(SYSMON_PROC="$FX" SYSMON_SYS="$(mktemp -d)" bash "$ROOT/process_check.sh" --interval 1 2>&1)"; RC=$?
chk 1 "persistent D-state → WARNING" '1 process\(es\) stuck in D-state'
grep -q 'pid=4242 .*nfs_worker .*wchan=wait_event' <<<"$OUT" && ok || bad "D-state detail line: $OUT"
FX="$(base)"; addproc "$FX" 4242 flaky D 1 1 500 10
fresh_state; ( sleep 0.4; rm -rf "$FX/4242" ) &
OUT="$(SYSMON_PROC="$FX" SYSMON_SYS="$(mktemp -d)" bash "$ROOT/process_check.sh" --interval 1 2>&1)"; RC=$?; wait
chk 0 "TRANSIENT D-state must not alert" '^OK:'
FX="$(base)"; for p in 11 12 13 14 15; do addproc "$FX" $p hung D 1 1 500 10; done
fresh_state; OUT="$(SYSMON_PROC="$FX" SYSMON_SYS="$(mktemp -d)" bash "$ROOT/process_check.sh" --interval 1 2>&1)"; RC=$?
chk 2 "5 persistent D-state → CRITICAL" '5 process\(es\) stuck'

# ---------------- file-descriptor exhaustion --------------------------------------------------------------------------------
FX="$(base)"; addproc "$FX" 3000 leaky S 1 1 500 10 900 1024;   run;            chk 1 "900/1024 fds (87.9%) → WARNING" 'fd usage 87\.8%.*leaky pid=3000 \(900/1024\)'
grep -qE '^ +87\.8% +pid=3000 +leaky +900 / 1024 fds' <<<"$OUT" && ok || bad "fd detail line missing: $OUT"
FX="$(base)"; addproc "$FX" 3000 leaky S 1 1 500 10 1000 1024;  run;            chk 2 "1000/1024 fds (97.6%) → CRITICAL" 'fd usage 97\.6%'
FX="$(base)"; addproc "$FX" 3000 db S 1 1 500 10 5000 unlimited; run;           chk 0 "unlimited soft limit is ignored" '^OK:'
FX="$(base)"; addproc "$FX" 3000 busy S 1 1 500 10 500 1024;    run -w 1 2>/dev/null; true
FX="$(base)"; addproc "$FX" 3000 busy S 1 1 500 10 500 1024;    run --fd-warn 40 --fd-crit 90;  chk 1 "custom fd thresholds (48.8% > 40)" 'fd usage 48\.8%'

# ---------------- pid / thread exhaustion --------------------------------------------------------------------------------------
FX="$(mk_proc 1000 1000000)"; for p in $(seq 1 10); do addproc "$FX" $p "w$p" S 0 80 9000 10; done
run;                                                                              chk 1 "800 threads of pid_max 1000 (80%) → WARNING" 'task table 80\.0% of pid_max'
FX="$(mk_proc 1000 1000000)"; for p in $(seq 1 10); do addproc "$FX" $p "w$p" S 0 95 9000 10; done
run;                                                                              chk 2 "950/1000 → CRITICAL" 'task table 95\.0%'
FX="$(base 32768 1000)"; for p in $(seq 20 30); do addproc "$FX" $p "w$p" S 0 90 9000 10; done
run;                                                                              chk 2 "threads-max is checked too" 'threads-max'
SYSD="$(mktemp -d)"; mkdir -p "$SYSD/fs/cgroup"; echo 100 > "$SYSD/fs/cgroup/pids.max"; echo 95 > "$SYSD/fs/cgroup/pids.current"
FX="$(base)"; run;                                                                chk 2 "container pids.max at 95% → CRITICAL" 'cgroup pids\.max'
echo max > "$SYSD/fs/cgroup/pids.max"; run;                                       chk 0 "pids.max=max ignored" '^OK:'; SYSD=""

# ---------------- required processes & crash-loop detection --------------------------------------------------------------------------
FX="$(base)"; run --require sshd;                                                  chk 0 "required sshd present" '^OK:'
FX="$(base)"; run --require nginx;                                                 chk 2 "required nginx missing → CRITICAL" "nginx: 0/1 running"
FX="$(base)"; addproc "$FX" 2001 worker S 1 1 9000 10; addproc "$FX" 2002 worker S 1 1 9000 10
run --require worker:3;                                                            chk 2 "worker:3 with only 2 → CRITICAL" 'worker: 2/3 running'
run --require worker:2;                                                            chk 0 "worker:2 with 2 → OK" '^OK:'
FX="$(base)"; addproc "$FX" 2001 crashy S 1 1 30 10
run --require crashy;                                                              chk 1 "30s-old process → crash-loop WARNING" 'crashy restarted 30s ago'
run --require crashy --respawn-window 10;                                          chk 0 "…unless the window is shorter" '^OK:'
FX="$(base)"; addproc "$FX" 2001 a-very-long-pro S 1 1 9000 10                       # kernel truncates comm to 15 chars
run --require a-very-long-process-name;                                            chk 0 "long names are matched on the 15-char comm" '^OK:'
FX="$(base)"; run --require sshd,nginx:1,bash;                                      chk 2 "comma list: one missing is enough" 'nginx: 0/1'
FX="$(base)"; run --require 'sshd:x';                                               chk 3 "bad --require entry → UNKNOWN" ''

# ---------------- systemd failed units (via a systemctl shim) ---------------------------------------------------------------------------
SHIMDIR="$(mktemp -d /tmp/shim.XXXXXX)"
mkshim() { printf '#!/usr/bin/env bash\n%s\n' "$1" > "$SHIMDIR/systemctl"; chmod +x "$SHIMDIR/systemctl"; }
FX="$(base)"
mkshim 'printf "foo.service loaded failed failed Foo\nbar.service loaded failed failed Bar\n"';  run --failed-units;  chk 1 "2 failed units → WARNING" '2 failed systemd unit'
grep -q 'failed unit: foo.service' <<<"$OUT" && ok || bad "unit names should be listed"
mkshim 'printf "a.service x\nb.service x\nc.service x\nd.service x\n"';                          run --failed-units;  chk 2 "4 failed units → CRITICAL" '4 failed'
mkshim ':';                                                                                       run --failed-units;  chk 0 "no failed units" '^OK:'
mkshim 'exit 1';                                                                                  run --failed-units;  chk 0 "systemctl failing is a skipped check, not an alert" '^OK:'
mkshim 'sleep 30';                                                                                start=$SECONDS; run --failed-units; (( SECONDS - start < 20 )) && ok || bad "systemctl must be bounded by a timeout"
SHIMDIR=""

# ---------------- formats & errors --------------------------------------------------------------------------------------------------------
FX="$(base)"; run -f json
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["check"]=="proc" and d["status"]=="OK" and d["metrics"]["processes"]==3' "$OUT" && ok || bad "json: $OUT"
run -f prom; grep -q '^sysmon_proc_processes 3$' <<<"$OUT" && ok || bad "prom: $OUT"
fresh_state; SYSMON_PROC="$(mktemp -d)" bash "$ROOT/process_check.sh" >/dev/null 2>&1; (( $? == 3 )) && ok || bad "unreadable /proc → UNKNOWN"
fresh_state; bash "$ROOT/process_check.sh" --bogus >/dev/null 2>&1; (( $? == 3 )) && ok || bad "bad option → 3"

# ---------------- smoke on the real machine ---------------------------------------------------------------------------------------------------
fresh_state; OUT="$(unset SYSMON_PROC SYSMON_SYS; bash "$ROOT/process_check.sh" --interval 1 --require bash 2>&1)"; RC=$?
(( RC <= 3 )) && grep -qE '^(OK|WARNING|CRITICAL|UNKNOWN): [0-9]+ processes' <<<"$OUT" && ok || bad "real system smoke (rc=$RC): $OUT"

printf '\nprocess_check: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
