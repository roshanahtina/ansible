# sysmon — senior-level Linux health checks (bash)

Five checks — **memory, load/CPU, disk, process, network** — plus a parallel runner, written to be *operated in production* **and** *defended in an interview*. They are the senior counterpart of the five intermediate scripts in `../scripts/`.

```
senior-scripts/
├── lib/common.sh          shared library: logging, locking, state, thresholds, output formats, /proc helpers
├── mem_check.sh           MemAvailable · cgroup limit · swap ACTIVITY · OOM counter delta · PSI
├── load_check.sh          load/effective-CPU · cpu split · persistent D-state · per-core · throttling · diagnosis
├── disk_check.sh          bounded statfs (no NFS hangs) · inodes · time-to-full · read-only remount · deleted-open files · await
├── process_check.sh       zombies→parent · persistent D-state · fd exhaustion · pid/thread exhaustion · required procs · crash loops
├── network_check.sh       error RATES · retransmit % · listen drops · conntrack · CLOSE_WAIT · link flaps · connect/DNS/TLS probes
├── run_all.sh             all checks in parallel, timeout-bounded, aggregated (text | json | prom)
├── systemd/               sysmon.service + sysmon.timer (templates — see "Honest limitations")
└── tests/                 fixture-driven test suites (run: bash tests/run_all_tests.sh)
```

## Quick start
```bash
bash run_all.sh                                   # human-readable summary, exit code = worst status
bash run_all.sh -f json                           # one JSON document (valid even if a check times out)
bash run_all.sh -f prom --prom-file /var/lib/node_exporter/textfile/sysmon.prom   # atomic textfile for Prometheus
bash mem_check.sh -w 80 -c 90 --confirm 3         # a single check, Nagios/NRPE style
bash disk_check.sh --ttf-warn 48: --ttf-crit 12:  # alert when a filesystem will be full within 12h
bash process_check.sh --require sshd,chronyd,nginx:2
bash network_check.sh --target db01:5432 --dns internal.example.com --tls api.example.com:443 --require-up eth0
```
Exit codes everywhere: `0 OK · 1 WARNING · 2 CRITICAL · 3 UNKNOWN`. Thresholds use **Nagios range syntax**: `90` (alert if >90), `20:` (alert if <20), `~:10`, `10:20`, `@10:20`.
Nagios/NRPE: `command[check_mem]=/opt/sysmon/mem_check.sh -w 80 -c 90` — the output is a standard plugin line with perfdata.

## The 12 design principles (each is an interview answer)

| # | Principle | Where it shows up | The question it answers |
|---|---|---|---|
| 1 | **A check must never hang** | `disk_check`: every filesystem probed in parallel under `timeout`; polling loop instead of `wait`; probes detached from stdout. `run_all`: per-check hard timeout. | "How do you monitor NFS without your monitor freezing?" |
| 2 | **Rates, not counters** | `network_check` error/drop rates and retransmit % from two samples; `mem_check` swap pages/s and `oom_kill` delta | "Interface shows 4M errors — is that a problem?" (only if it's *gaining*) |
| 3 | **Saturation over utilisation (USE method)** | `load_check`: 90% busy with an empty run queue is OK; alerting is on queue/pressure/PSI | "CPU is at 95% — page someone?" |
| 4 | **Kernel signals, not log scraping** | OOM via `/proc/vmstat oom_kill`; PSI (`/proc/pressure/*`); `carrier_changes`; `/proc/net/tcp` | "Why not grep dmesg?" (rotates, races, locale) |
| 5 | **Diagnose, don't just report** | `load_check` classifies *steal / I/O-bound / CPU-bound / single-thread / throttled*; zombies point at the **parent** | "What does high load with low CPU mean?" |
| 6 | **Predict, don't just threshold** | `disk_check` stores usage between runs → *hours until full* | "70% used — fine?" (not if it fills in 3 hours) |
| 7 | **Persistence beats snapshots** | D-state counted only if the *same pid* is stuck in two samples | "Is a process in D-state a problem?" (transient: no) |
| 8 | **Flap suppression with state** | `--confirm N` + atomic state files (temp + `mv`) | "How do you stop alert storms?" |
| 9 | **Stable output contract** | nagios / json / prom from one result model; `json_escape`; atomic prom file | "How do you feed three different monitoring systems?" |
| 10 | **Container/cgroup awareness** | effective CPUs from `cpu.max`; memory from `memory.max`; `pids.max`; throttling counters | "Host looks idle but the app is slow in Kubernetes — why?" |
| 11 | **Testable by construction** | every `/proc` and `/sys` read goes through `$PROC`/`$SYS`; PATH shims fake `stat`/`systemctl`; counters mutated mid-window | "How do you test a monitoring script?" |
| 12 | **Safe by default** | strict mode, `umask 077`, key whitelists (no path traversal), host/port whitelists (no injection), `printf %q` cleanup stack, `flock` | "What could go wrong running this as root every minute?" |

## What each check says about *you* (use these as story hooks)

**mem_check** — "available, not free"; cgroup limit beats host RAM inside a container; *static* swap usage is noise, swap **activity** is the signal; OOM kills tracked as a counter delta so a log rotation can't hide one; PSI tells me tasks were *actually stalled*.

**load_check** — normalise by *effective* CPUs (quota-aware); split iowait / steal / irq; per-core scan finds the single hot thread an average hides; **cgroup throttling** explains "idle host, slow container"; it ends with a *diagnosis sentence* the on-call can act on.

**disk_check** — `df` hangs on a dead NFS mount and takes your monitor with it; so statfs runs under `timeout`, in parallel, with the poll loop (an unkillable D-state probe would hang a plain `wait`). Also: inodes, read-only remounts that fstab didn't ask for, deleted-but-open files (`df` says full, `du` says empty), per-device await from `/proc/diskstats`, and *time-to-full*.

**process_check** — zombies can't be killed, so it names the **parent**; fd usage per process against its own soft limit finds "too many open files" *before* it happens; thread count vs `pid_max`/`threads-max`/cgroup `pids.max` catches a fork bomb or thread leak; required processes with a minimum count and crash-loop detection from process age; one pass over `/proc`, zero per-process forks.

**network_check** — retransmit % is the "invisible latency" metric; listen-queue drops mean the *application* isn't accepting; CLOSE_WAIT means the *application* isn't closing; conntrack at 100% silently drops new flows; probes (TCP connect / DNS / TLS expiry) are each bounded by a timeout and inputs are whitelisted.

## Bugs the tests caught while this was being built (honest engineering story)
These are real defects found by the test suites — worth telling, because they show *why* the tests exist:
1. **errexit inside a background subshell** killed the probe before it could record its exit code, so a plain `statfs` error was reported as "unresponsive" (`disk_check`).
2. **`A || B && C` operator precedence** would have hidden zombie details unless debug mode was on (`process_check`).
3. **`$(< file)` on a vanished /proc entry aborted the script** and my `2>/dev/null` was applied too late; fixed with the group-redirect pattern `{ read -r x < file; } 2>/dev/null` (`lib`).
4. **Off-by-one in a state table** (`i<=23` instead of `21`) emitted an empty-named entry and crashed the socket-state parser on *every* run (`lib`/`network_check`).
5. **`head` + `set -o pipefail`** → SIGPIPE (rc 141) aborts the script: use `mapfile` and slice instead (`mem_check`); the same trap broke a `grep -q` in one of my own tests.
6. **A test helper with a bare `wait`** waited on every background job, including test listeners, and hung the whole suite for 5 minutes.
7. **Boundary semantics**: Nagios range `200` alerts when value **> 200** — an await of exactly 200 ms is only a WARNING; the test, not the script, was wrong.

## When NOT to use bash for this (the senior judgement call)
Bash is right for **host-local, dependency-free, short-lived checks** that must run on a bare RHEL/Ubuntu box. Move to Python/Go (or use `node_exporter`, `telegraf`, `Prometheus` + alert rules) when you need: long-lived state or history, many hosts from one place, complex parsing of structured data, concurrency beyond a handful of jobs, or a library ecosystem (TLS, HTTP, SNMP). The shell checks here are intentionally the *last-line, always-works* layer — not a replacement for a metrics pipeline.

## Testing
```bash
bash tests/run_all_tests.sh          # all suites with a summary table (≈3–4 minutes)
bash tests/test_lib.sh               # or any single suite
```
Fixture-driven: fake `/proc` and `/sys` trees, PATH shims for `stat`/`systemctl`, background rewrites of counters *during* the sample window so the code sees genuine deltas, real local TCP/TLS listeners for probes, and a real process holding a deleted file for the deleted-open scan. Each check also has a **smoke test on the live machine**.

## Honest limitations (so nobody is surprised in production or in an interview)
- **Built and tested in a Linux sandbox with bash 5.2, kernel 6.x, as root.** Not yet run on **RHEL 8/9 or Ubuntu LTS hosts**. RHEL 8 ships **bash 4.4**: the code avoids bash-5-only features and falls back when `EPOCHREALTIME` is missing, but that fallback path was **not** executed in tests.
- **`shellcheck` was not available** in the sandbox, so static analysis was *not* run — only `bash -n` and the test suites. Run `shellcheck -x *.sh lib/*.sh` before adopting.
- **systemd units are templates, unverified** (no systemd in the sandbox). Validate with `systemd-analyze verify`.
- **cgroup v1/v2 behaviour is tested via fixtures**, not on a real throttled container; PSI depends on the kernel (`psi=1` on some RHEL 8 builds).
- **Not covered by tests:** a truly *unkillable* hung NFS probe (the design handles it, but the sandbox can't create one), multi-NUMA effects, IPv6-only probes (hosts are whitelisted to `[A-Za-z0-9._-]`), and non-root fd coverage (the check reports how many processes it could actually see).
- Default thresholds are **starting points**, not policy — tune per workload.
- `diskstats`-based latency ignores partitions/loop devices by design; `dm-*`/`md*` are included, so stacked devices can appear twice.
