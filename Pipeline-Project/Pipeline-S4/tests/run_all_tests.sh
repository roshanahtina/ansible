#!/usr/bin/env bash
# Runs every test suite, each under its own timeout, and prints one summary table.
#   Usage: bash tests/run_all_tests.sh            (exit code 0 only if every suite passes)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITES=(lib mem load disk proc net all)
total_pass=0; total_fail=0; rows=(); worst=0

for s in "${SUITES[@]}"; do
    f="$HERE/test_${s}.sh"
    [[ -f "$f" ]] || continue
    start=$SECONDS
    out="$(timeout 240 bash "$f" 2>&1)"; rc=$?
    took=$((SECONDS - start))
    summary="$(grep -E '[0-9]+ passed, [0-9]+ failed' <<<"$out" | tail -1)"
    p="$(sed -nE 's/.*[^0-9]([0-9]+) passed.*/\1/p;s/^([0-9]+) passed.*/\1/p' <<<"$summary" | head -1)"; p="${p:-0}"
    fl="$(sed -nE 's/.* ([0-9]+) failed.*/\1/p' <<<"$summary" | head -1)"; fl="${fl:-0}"
    status="PASS"; if (( rc == 124 )); then status="TIMEOUT"; worst=1; elif (( rc != 0 )); then status="FAIL"; worst=1; fi
    total_pass=$((total_pass + p)); total_fail=$((total_fail + fl))
    rows+=("$(printf '%-8s %-8s %4s passed %3s failed  %4ss' "$s" "$status" "$p" "$fl" "$took")")
    if (( rc != 0 )); then printf -- '--- %s output (failures) ---\n%s\n' "$s" "$(grep -E '^FAIL' <<<"$out" | head -20)"; fi
done

printf '\n=================== TEST SUMMARY ===================\n'
printf '%s\n' "${rows[@]}"
printf -- '----------------------------------------------------\n'
printf 'TOTAL    %s passed, %s failed\n' "$total_pass" "$total_fail"
exit "$worst"
