#!/usr/bin/env bash
# Tests for disk_check.sh.  Filesystem numbers come from a `stat` shim placed first in PATH
# (the standard way to fake an external command — no test hooks in production code).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$HERE/.."
export LOG_LEVEL=error
REAL_STAT="$(command -v stat)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); printf 'FAIL: %s\n' "$1"; }
fresh_state() { SYSMON_STATE_DIR="$(mktemp -d)"; export SYSMON_STATE_DIR; }

# ---- the stat shim: "mountpoint|S b a f c d"  or  "mountpoint|HANG"  or  "mountpoint|FAIL" ---------------
SHIM="$(mktemp -d)"; MAP="$(mktemp)"
cat > "$SHIM/stat" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "-f" ]]; then
  target="\${@: -1}"
  val="\$(awk -F'|' -v t="\$target" '\$1==t {print \$2; exit}' "$MAP")"
  if [[ -z "\$val" ]]; then exec "$REAL_STAT" "\$@"; fi
  case "\$val" in HANG) exec sleep 30 ;; FAIL) exit 1 ;; *) echo "\$val"; exit 0 ;; esac
fi
exec "$REAL_STAT" "\$@"
EOF
chmod +x "$SHIM/stat" 2>/dev/null || true
# if the filesystem forbids +x, fall back to running via a wrapper dir on a tmpfs-like path
if [[ ! -x "$SHIM/stat" ]]; then SHIM="$(mktemp -d /tmp/shim.XXXXXX)"; cp /dev/null "$SHIM/stat"; fi

# fs LINE : set the fake statfs numbers.   percent helpers: S=4096 b=1000000
fsline() {  # fsline USED_PCT INODE_USED_PCT  → "4096 1000000 <avail> <free> 100000 <ifree>"
    awk -v u="$1" -v i="$2" 'BEGIN{ b=1000000; used=b*u/100; a=b-used; printf "4096 %d %d %d 100000 %d", b, a, a, 100000-(100000*i/100) }'
}
mk_proc() {  # mk_proc [mounts-text]
    local d; d="$(mktemp -d)"; mkdir -p "$d/sys/kernel"; echo testhost > "$d/sys/kernel/hostname"
    printf '%b' "${1:-/dev/sda1 / ext4 rw,relatime 0 0\ntmpfs /dev/shm tmpfs rw 0 0\n/dev/sdb1 /data xfs rw,noatime 0 0\n}" > "$d/mounts"
    printf '   8 0 sda 0 0 0 0 0 0 0 0 0 0 0\n   8 1 sda1 0 0 0 0 0 0 0 0 0 0 0\n' > "$d/diskstats"
    printf '%s' "$d"
}
FSTAB_F="$(mktemp)"; echo "/dev/sda1 / ext4 defaults 0 0" > "$FSTAB_F"
run() {  # run [args]   → sets OUT, RC.  Uses $FX (proc fixture) and the shim
    OUT="$(SYSMON_PROC="$FX" SYSMON_FSTAB="$FSTAB_F" PATH="$SHIM:$PATH" bash "$ROOT/disk_check.sh" --no-io "$@" 2>&1)"; RC=$?
}
setmap() { : > "$MAP"; local m; for m in "$@"; do echo "$m" >> "$MAP"; done; }
chk() { if (( RC != $1 )); then bad "$2 (want rc=$1 got rc=$RC): ${OUT:0:400}"; return; fi
        if [[ -n "${3:-}" ]] && ! grep -qE -- "$3" <<<"$OUT"; then bad "$2 (rc ok, missing /$3/): ${OUT:0:400}"; return; fi; ok; }

# ---------------- space / inode thresholds -------------------------------------------------------------------
FX="$(mk_proc)"
fresh_state; setmap "/|$(fsline 20 10)" "/data|$(fsline 30 10)";                run; chk 0 "healthy" '^OK: 2 filesystem\(s\) checked, worst 30\.0% \(/data\)'
fresh_state; setmap "/|$(fsline 20 10)" "/data|$(fsline 85 10)";                run; chk 1 "85% → WARNING" 'WARNING /data \(xfs\): 85\.0% space used'
fresh_state; setmap "/|$(fsline 95 10)" "/data|$(fsline 30 10)";                run; chk 2 "95% → CRITICAL" 'CRITICAL / \(ext4\): 95\.0% space used'
fresh_state; setmap "/|$(fsline 95 10)" "/data|$(fsline 30 10)";                run -w 96 -c 99; chk 0 "custom thresholds" '^OK:'
fresh_state; setmap "/|$(fsline 20 98)" "/data|$(fsline 30 10)";                run; chk 2 "inode exhaustion with free space → CRITICAL" '98\.0% INODES used.*inode exhaustion'
fresh_state; setmap "/|4096 1000000 800000 800000 0 0" "/data|$(fsline 30 10)"; run; chk 0 "dynamic-inode fs (c=0) must not divide by zero / alert" '^OK:'
fresh_state; setmap "/|$(fsline 20 10)" "/data|$(fsline 30 10)" "/dev/shm|$(fsline 99 99)"; run; chk 0 "tmpfs is excluded by default" '2 filesystem\(s\)'
fresh_state; setmap "/|$(fsline 20 10)" "/data|$(fsline 30 10)";                run --exclude-mount '^/data$'; chk 0 "--exclude-mount" '1 filesystem\(s\)'

# bind mounts of the same device are one filesystem, not two
FX="$(mk_proc '/dev/sda1 / ext4 rw 0 0\n/dev/sda1 /bind ext4 rw 0 0\n')"
fresh_state; setmap "/|$(fsline 20 10)" "/bind|$(fsline 20 10)";                run; chk 0 "bind mount de-duplicated" '1 filesystem\(s\)'

# nothing but pseudo filesystems (typical inside a container with overlay root) → fall back to "/"
FX="$(mk_proc 'overlay / overlay rw 0 0\ntmpfs /dev tmpfs rw 0 0\n')"
fresh_state; setmap "/|$(fsline 92 10)";                                         run; chk 2 "container fallback checks /" 'CRITICAL / '

# ---------------- hung / failing filesystems ---------------------------------------------------------------------
FX="$(mk_proc '/dev/sda1 / ext4 rw 0 0\nnfs01:/export /mnt/nfs nfs4 rw 0 0\n')"
fresh_state; setmap "/|$(fsline 20 10)" "/mnt/nfs|HANG"
start=$SECONDS; run --fs-timeout 1; took=$((SECONDS - start))
chk 2 "hung NFS mount → CRITICAL, not a hang" 'UNRESPONSIVE'
(( took <= 8 )) && ok || bad "hung mount must not stall the check (took ${took}s)"
fresh_state; setmap "/|$(fsline 20 10)" "/mnt/nfs|FAIL";                          run; chk 2 "statfs error" 'statfs failed rc=1'

# ---------------- read-only remount ----------------------------------------------------------------------------------
FX="$(mk_proc '/dev/sda1 / ext4 ro,relatime 0 0\n')"
fresh_state; setmap "/|$(fsline 20 10)";                                         run; chk 2 "unexpected ro remount" 'READ-ONLY but fstab does not say ro'
echo "/dev/sda1 / ext4 ro,defaults 0 0" > "$FSTAB_F"
fresh_state; run;                                                                 chk 0 "ro is fine when fstab says ro" '^OK:'
echo "/dev/sda1 / ext4 defaults 0 0" > "$FSTAB_F"
FX="$(mk_proc '/dev/sr0 /media/cd iso9660 ro 0 0\n')"; fresh_state; setmap "/media/cd|$(fsline 100 0)"; run --exclude-type '^$'; chk 2 "(100% full cd is CRITICAL space, but not 'read-only' noise)" '100\.0% space used'
grep -q 'READ-ONLY' <<<"$OUT" && bad "iso9660 must never trigger the read-only alarm" || ok

# ---------------- predictive: hours until full -------------------------------------------------------------------------
source "$ROOT/lib/common.sh"; set +o errexit
FX="$(mk_proc '/dev/sda1 / ext4 rw 0 0\n')"; fresh_state
now="$(date +%s)"; key="disk.use.$(state_key /)"
# now: used=700000*4096, avail=300000*4096.  an hour ago used was 600000*4096 → +409.6MB/h → 1.2288GB left ≈ 3.0h
echo "$((now - 3600)) $((600000 * 4096))" > "$SYSMON_STATE_DIR/$key"
setmap "/|4096 1000000 300000 300000 100000 90000"; run;                           chk 2 "fills in ~3h → CRITICAL even though only 70% used" 'FULL in 3\.0h'
grep -q 'ttf_hours_root=3.0' <<<"$OUT" && ok || bad "ttf perfdata missing: $OUT"
fresh_state; echo "$((now - 3600)) $((699000 * 4096))" > "$SYSMON_STATE_DIR/$key"; run; chk 0 "slow growth → fine" 'ttf_hours_root='
fresh_state; run;                                                                  chk 0 "first run only stores a baseline (no TTF yet)" ''
[[ -s "$SYSMON_STATE_DIR/$key" ]] && ok || bad "baseline state not written"
fresh_state; echo "$((now - 10)) $((100000 * 4096))" > "$SYSMON_STATE_DIR/$key"; run; chk 0 "samples <60s apart are ignored (noise)" ''
grep -q 'ttf_hours' <<<"$OUT" && bad "must not compute a rate from <60s of data" || ok

# ---------------- hysteresis ------------------------------------------------------------------------------------------
FX="$(mk_proc '/dev/sda1 / ext4 rw 0 0\n')"; fresh_state; setmap "/|$(fsline 95 10)"
run --confirm 2; r1=$RC; run --confirm 2; r2=$RC
(( r1 == 1 && r2 == 2 )) && ok || bad "confirm 2: expected rc 1 then 2, got $r1 then $r2"

# ---------------- deleted-but-open files (real process, real /proc) ----------------------------------------------------
df_file="$(mktemp -u /tmp/delme.XXXXXX)"
( exec 9>"$df_file"; rm -f "$df_file"; head -c 3145728 /dev/zero >&9; sleep 15 ) &
holder=$!; sleep 0.5
source "$ROOT/disk_check.sh"; set +o errexit
res="$(deleted_open 5)"
grep -q "^3145728 [0-9]* .* $df_file\$" <<<"$res" && ok || bad "deleted_open did not find the 3 MiB deleted file: $res"
FX="$(mk_proc '/dev/sda1 / ext4 rw 0 0\n')"; ln -s "/proc/$holder" "$FX/$holder"   # expose the REAL process through the fixture /proc
fresh_state; setmap "/|$(fsline 95 10)"; run
grep -q 'Deleted-but-still-open files' <<<"$OUT" && grep -q "$df_file" <<<"$OUT" && ok || bad "CRITICAL run should list deleted-open files: ${OUT:0:500}"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

# ---------------- I/O latency from /proc/diskstats (rewritten mid-window) ----------------------------------------------
FX="$(mk_proc '/dev/sda1 / ext4 rw 0 0\n')"; setmap "/|$(fsline 20 10)"
slow="$(mktemp)"; # sda: +100 reads taking 25000ms total → 250ms await; busy 900ms of ~1s; sda1 partition must be ignored; idle sdb has <5 IOs
printf '   8 0 sda 100 0 800 25000 0 0 0 0 0 900 25000\n   8 1 sda1 100 0 800 25000 0 0 0 0 0 900 25000\n   8 16 sdb 2 0 8 4 0 0 0 0 0 1 4\n' > "$slow"
fresh_state; ( sleep 0.4; cp "$slow" "$FX/diskstats" ) &
OUT="$(SYSMON_PROC="$FX" SYSMON_FSTAB="$FSTAB_F" PATH="$SHIM:$PATH" bash "$ROOT/disk_check.sh" --interval 1 2>&1)"; RC=$?; wait
chk 2 "250 ms await → CRITICAL" 'slow I/O on sda: 250\.0 ms'
grep -q 'io sda1' <<<"$OUT" && bad "partition devices must be ignored" || ok
grep -q 'io sdb' <<<"$OUT" && bad "devices with <5 IOs must be ignored (noise)" || ok
mid="$(mktemp)"; printf '   8 0 sda 100 0 800 6000 0 0 0 0 0 100 6000\n' > "$mid"
fresh_state; printf '   8 0 sda 0 0 0 0 0 0 0 0 0 0 0\n' > "$FX/diskstats"; ( sleep 0.4; cp "$mid" "$FX/diskstats" ) &
OUT="$(SYSMON_PROC="$FX" SYSMON_FSTAB="$FSTAB_F" PATH="$SHIM:$PATH" bash "$ROOT/disk_check.sh" --interval 1 2>&1)"; RC=$?; wait
chk 1 "60 ms await → WARNING" 'slow I/O on sda: 60\.0 ms'

# ---------------- formats & errors --------------------------------------------------------------------------------------------
FX="$(mk_proc)"; fresh_state; setmap "/|$(fsline 20 10)" "/data|$(fsline 30 10)"; run -f json
python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d["check"]=="disk" and d["status"]=="OK" and d["metrics"]["used_pct_data"]==30.0 and d["metrics"]["worst_used_pct"]==30.0' "$OUT" && ok || bad "json: $OUT"
run -f prom; grep -q '^sysmon_disk_used_pct_root 20.0$' <<<"$OUT" && ok || bad "prom: $OUT"
fresh_state; SYSMON_PROC="$(mktemp -d)" bash "$ROOT/disk_check.sh" >/dev/null 2>&1; (( $? == 3 )) && ok || bad "unreadable /proc/mounts → UNKNOWN"
fresh_state; bash "$ROOT/disk_check.sh" --bogus >/dev/null 2>&1; (( $? == 3 )) && ok || bad "bad option → 3"
fresh_state; bash "$ROOT/disk_check.sh" --fs-timeout x >/dev/null 2>&1; (( $? == 3 )) && ok || bad "non-integer timeout → 3"

# ---------------- smoke test on the real machine --------------------------------------------------------------------------------
fresh_state; OUT="$(unset SYSMON_PROC; bash "$ROOT/disk_check.sh" --interval 1 2>&1)"; RC=$?
(( RC <= 3 )) && grep -qE '^(OK|WARNING|CRITICAL|UNKNOWN): ' <<<"$OUT" && ok || bad "real system smoke (rc=$RC): $OUT"

printf '\ndisk_check: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
