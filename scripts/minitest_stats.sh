#!/usr/bin/env bash
# Per-test timing statistics for the minitest suite: what is slow, how evenly
# a given shard count can split it, and which measurement each shard gets.
#
#   scripts/minitest_stats.sh                     # report: slowest tests, imbalance, history
#   scripts/minitest_stats.sh --slices 4 DIR      # write DIR/<map>.tsv for scripts/minitest.sh
#   scripts/minitest_stats.sh --publish           # refresh the tracked baseline + history
#
# Where the numbers come from: run_one in test/minitest_helper.cr appends one
# "<seconds>\t<serial|parallel>\t<test>\t<run>" line per test to the file in
# MINITEST_TIMINGS (.minitest_timings.tsv for a scripts/minitest.sh run).
#
# Two things make a raw record untrustworthy, and both are handled here:
#
#   * A test is recorded several times per run (minitest re-queues the inherited
#     names of nested describes; only one of those records does the work), so a
#     run's time for a test is the MAX over its records in that run.
#   * A shard runs all of its fibers on ONE OS thread (CRYSTAL_WORKERS=1), so a
#     CPU-hogging test inflates the wall clock of every test that ran alongside
#     it - measured at up to ~2000x (0.14s recorded as 273s) on a loaded box.
#     That only ever makes a record too big, so the best estimate of a test's
#     own cost is the MIN across the last RUNS_KEPT runs.
#
# Keeping max-ever (what scripts/minitest.sh used to do) let one such sample
# poison the weights permanently: a 10-test file ended up with a 5469s weight,
# more than a sixth of the suite, and the shard that got it ran alone for 5
# minutes while five others idled.
#
# The weights baseline that ships in the repo is test/minitest_weights.tsv
# ("<seconds>\t<test>", MIN across runs at publish time), so a cold checkout or
# CI can balance without a warm-up run. The local history is .minitest_runs.tsv
# (gitignored); --publish promotes the newest line into test/minitest_runs.tsv
# so the effect of a change can be compared across weeks. krikri-role-tester
# keeps the equivalent for benchmark rounds in a DuckDB stats DB; the suite's
# numbers are small enough that diffable TSVs are more use than a database.

set -euo pipefail
export LC_ALL=C

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE="$ROOT/test/minitest_weights.tsv"
LOCAL_RUNS="$ROOT/.minitest_runs.tsv"
TRACKED_RUNS="$ROOT/test/minitest_runs.tsv"
RAW_TIMINGS="${MINITEST_TIMINGS:-$ROOT/.minitest_timings.tsv}"

# How many of the most recent runs a test's weight may look back over.
RUNS_KEPT="${MINITEST_RUNS_KEPT:-3}"

usage() {
  sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-2}"
}

mode=print
shards=""
out_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --slices)  mode=slices; shards="${2:-}"; out_dir="${3:-}"; shift 3 ;;
    --publish) mode=publish; shift ;;
    --print)   mode=print; shift ;;
    -h|--help) usage 0 ;;
    *)         break ;;
  esac
done

# ---- weights -------------------------------------------------------------
#
# Emits "<seconds>\t<test>", heaviest first. Inputs may be raw MINITEST_TIMINGS
# files (4 columns, run id last; a 3-column file from before run ids counts as
# one run) and/or an already-reduced baseline (2 columns). A test measured in a
# raw file wins over the baseline: the raw file is this machine's current data.
weight_files=()
for f in "$RAW_TIMINGS" "$@"; do
  [ -n "$f" ] && [ -s "$f" ] && weight_files+=("$f")
done
[ -s "$BASELINE" ] && weight_files+=("$BASELINE")

weights() {
  awk -F'\t' -v kept="$RUNS_KEPT" '
    NF == 2 { base[$2] = $1 + 0; next }
    {
      name = $3
      run = ($4 == "" ? "-" : $4)
      key = name SUBSEP run
      if ($1 + 0 > per_run[key]) per_run[key] = $1 + 0
      if (!(key in seen)) {
        seen[key] = 1
        order[name] = (name in order ? order[name] "|" : "") run
      }
    }
    END {
      for (name in order) {
        n = split(order[name], runs, "|")
        first = (n > kept ? n - kept + 1 : 1)
        best = 0
        for (i = first; i <= n; i++) {
          v = per_run[name SUBSEP runs[i]]
          if (best == 0 || v < best) best = v
        }
        if (best > 0) print best "\t" name
      }
      for (name in base) if (!(name in order)) print base[name] "\t" name
    }
  ' "${weight_files[@]}" | sort -t$'\t' -k1,1gr -k2,2
}

# ---- LPT assignment ------------------------------------------------------

# Reads "<seconds>\t<test>" and emits "<test>\t<shard>", then one "# ..." summary line.
# per shard on stderr. Longest-processing-time first onto the lightest shard:
# deterministic (ties break on name), so the same inputs always give the same
# map, which is what makes a run's numbers comparable with the next one.
assign() {
  local n=$1
  awk -F'\t' -v n="$n" '
    { w[NR] = $1 + 0; t[NR] = $2 }
    END {
      for (i = 0; i < n; i++) { load[i] = 0; count[i] = 0 }
      for (i = 1; i <= NR; i++) {
        best = 0
        for (j = 1; j < n; j++) if (load[j] < load[best]) best = j
        load[best] += w[i]; count[best]++
        print t[i] "\t" best
      }
      total = 0
      for (i = 1; i <= NR; i++) total += w[i]
      max = 0
      for (i = 0; i < n; i++) if (load[i] > max) max = load[i]
      printf "# balanced %d measured tests over %d shards: %.0fs known work, heaviest %.0fs (%.1fx ideal)\n", NR, n, total, max, (total / n > 0 ? max / (total / n) : 0)
      for (i = 0; i < n; i++) printf "# shard %d: %d tests, %.0fs\n", i, count[i], load[i]
    }
  '
}

# ---- modes ---------------------------------------------------------------

case "$mode" in
  slices)
    [ -n "$shards" ] && [ -n "$out_dir" ] || usage
    mkdir -p "$out_dir"
    weights > "$out_dir/weights.tsv"
    if [ -s "$out_dir/weights.tsv" ]; then
      assign "$shards" < "$out_dir/weights.tsv" | tee "$out_dir/assign.tsv" | grep -v '^#' > "$out_dir/map.tsv"
      grep '^#' "$out_dir/assign.tsv" | sed 's/^# /stats: /' >&2
    else
      : > "$out_dir/map.tsv"
      echo "stats: no measurements yet, every test will be hashed onto a shard" >&2
    fi
    echo "$out_dir/map.tsv"
    ;;

  publish)
    weights | awk -F'\t' -v min="${MINITEST_WEIGHTS_MIN:-0.05}" '$1 + 0 >= min' > "$BASELINE.tmp"
    # A publish that measured nothing (an aborted run) must not wipe the baseline.
    if [ -s "$BASELINE.tmp" ]; then
      mv "$BASELINE.tmp" "$BASELINE"
      echo "published $(wc -l < "$BASELINE") weights to ${BASELINE#"$ROOT"/}" >&2
    else
      rm -f "$BASELINE.tmp"
      echo "no measurements to publish - baseline left alone" >&2
    fi
    if [ -s "$LOCAL_RUNS" ]; then
      header=$(grep -c '^#' "$TRACKED_RUNS" 2>/dev/null || true)
      newest=$(tail -1 "$LOCAL_RUNS")
      if ! grep -qxF "$newest" "$TRACKED_RUNS" 2>/dev/null; then
        if [ ! -s "$TRACKED_RUNS" ]; then
          printf '# date\tcommit\tshards\tfibers\ttests\tfailures\terrors\tbuild_s\trun_s\tslowest_shard_s\n' >> "$TRACKED_RUNS"
        fi
        printf '%s\n' "$newest" >> "$TRACKED_RUNS"
        echo "recorded run: $newest" >&2
      fi
    fi
    ;;

  print)
    reduced=$(mktemp)
    trap 'rm -f "$reduced"' EXIT
    weights > "$reduced"
    echo "== slowest tests (min across the last $RUNS_KEPT runs)"
    if [ -s "$reduced" ]; then
      awk -F'\t' '{ s += $1 } END { printf "%d measured tests, %.0fs of measured work\n", NR, s }' "$reduced"
      head -15 "$reduced" |
        awk -F'\t' '{ printf "%8.2fs  %s\n", $1, substr($2, 1, 110) }'
    else
      echo "  none yet - run the suite once (scripts/minitest.sh)"
    fi
    echo
    echo "== how evenly can the measured work be split?"
    for n in 2 4 6 8; do
      assign "$n" < "$reduced" | grep -v '^# shard' | grep '^#' | sed 's/^# */  /'
    done
    echo
    echo "== recent runs (test/minitest_runs.tsv, then local .minitest_runs.tsv)"
    for f in "$TRACKED_RUNS" "$LOCAL_RUNS"; do
      [ -s "$f" ] || continue
      echo "  ${f#"$ROOT"/}:"
      tail -5 "$f" | sed 's/^/    /'
    done
    ;;
esac
