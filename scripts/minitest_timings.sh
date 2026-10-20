#!/usr/bin/env bash
# Summarize a MINITEST_TIMINGS file written by test/minitest_helper.cr.
#
#   MINITEST_TIMINGS=/tmp/t.tsv scripts/minitest.sh -- -p 6
#   scripts/minitest_timings.sh /tmp/t.tsv [top-N]
#
# run_one is entered several times per test (nested describes re-queue the
# inherited names) and only one of those entries does real work, so a test's
# time is the max over its records.
set -euo pipefail

file=${1:?usage: minitest_timings.sh <timings-file> [top-N]}
top=${2:-25}

awk -F'\t' '{ if ($1 > m[$3]) { m[$3] = $1; s[$3] = $2 } } END { for (k in m) print m[k] "\t" s[k] "\t" k }' "$file" |
  sort -rn |
  awk -F'\t' -v top="$top" '
    { rows[NR] = $0; total += $1; kind[$2] += $1; count[$2]++ }
    END {
      printf "%d tests, %.0fs summed (serial %.0fs over %d tests, parallel %.0fs over %d)\n\n", NR, total, kind["serial"], count["serial"], kind["parallel"], count["parallel"]
      for (i = 1; i <= top && i <= NR; i++) {
        split(rows[i], f, "\t")
        printf "%7.1fs %-8s %s\n", f[1], f[2], substr(f[3], 1, 110)
      }
    }'
