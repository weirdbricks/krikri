#!/usr/bin/env bash
# Parallel spec runner: runs the spec suite buckets concurrently, one
# crystal spec process per bucket.
#
# Why buckets instead of `crystal spec` once: the suite's wall time is
# dominated by the integration bucket (real playbooks against localhost),
# while unit and lint finish much earlier. Running the buckets side by
# side cuts total wall time roughly to the integration bucket's own time.
#
# Why one CRYSTAL_CACHE_DIR per bucket: concurrent `crystal spec` runs
# sharing a cache dir contend on the compiler lock and can appear to
# hang. Each bucket gets its own persistent cache dir (content-addressed,
# safe to keep), so re-runs are warm and buckets never fight over a lock.
#
# Usage:
#   scripts/spec-parallel.sh              # all buckets
#   scripts/spec-parallel.sh unit lint    # subset, still in parallel
#
# Exit code is non-zero if any bucket fails or exceeds its timeout.

set -u -o pipefail

SPEC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/spec"
CACHE_ROOT="${SPEC_PARALLEL_CACHE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/krikri-spec-parallel}"
# Sanity cap per bucket: integration alone legitimately runs ~2.5 min,
# so anything well past 5 min means something is stuck, not slow.
TIMEOUT_SECS="${SPEC_PARALLEL_TIMEOUT:-300}"

if [ ! -d "$SPEC_DIR" ]; then
  echo "error: spec dir not found at $SPEC_DIR" >&2
  exit 2
fi

BUCKETS=("$@")
if [ ${#BUCKETS[@]} -eq 0 ]; then
  BUCKETS=(unit integration lint)
fi

for bucket in "${BUCKETS[@]}"; do
  if [ ! -d "$SPEC_DIR/$bucket" ]; then
    echo "error: unknown spec bucket '$bucket' (no spec/$bucket dir)" >&2
    exit 2
  fi
done

mkdir -p "$CACHE_ROOT"
# Logs live in the repo (gitignored), not /tmp: /tmp files written by
# nested processes have proven unreliable to read back in this
# environment, and failed-run logs are exactly what needs inspecting.
LOG_DIR="${SPEC_PARALLEL_LOG_DIR:-$SPEC_DIR/../.spec-parallel-logs}/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$LOG_DIR"
# Keep the log dir from growing unboundedly: drop runs older than 7 days.
find "$(dirname "$LOG_DIR")" -maxdepth 1 -type d -name '20*' -mtime +7 -exec rm -rf {} + 2>/dev/null

declare -A PIDS RESULTS
# On interrupt, tear down the per-bucket crystal processes; logs stay on
# disk either way so a failed/flaky run can be inspected afterwards.
cleanup() {
  for pid in "${PIDS[@]}"; do
    kill "$pid" 2>/dev/null
  done
}
trap cleanup EXIT INT TERM

echo "Running ${#BUCKETS[@]} bucket(s) in parallel (cache: $CACHE_ROOT, timeout: ${TIMEOUT_SECS}s)"
echo "Logs: $LOG_DIR"
echo

for bucket in "${BUCKETS[@]}"; do
  export CRYSTAL_CACHE_DIR="$CACHE_ROOT/$bucket"
  (
    # exec so the subshell is replaced by timeout itself: the PID we
    # track (and kill on interrupt) is then timeout's, and timeout
    # forwards the signal to its crystal child.
    exec timeout -k 10 "$TIMEOUT_SECS" crystal spec "$SPEC_DIR/$bucket/" \
      >"$LOG_DIR/$bucket.log" 2>&1
  ) &
  PIDS[$bucket]=$!
done

for bucket in "${BUCKETS[@]}"; do
  if wait "${PIDS[$bucket]}"; then
    RESULTS[$bucket]=ok
  else
    rc=$?
    RESULTS[$bucket]="FAILED (exit $rc)"
  fi
done

echo "=== Results ==="
overall_rc=0
for bucket in "${BUCKETS[@]}"; do
  summary=$(grep -E '[0-9]+ examples?, ' "$LOG_DIR/$bucket.log" | tail -1)
  printf '%-12s %-16s %s\n' "$bucket" "${RESULTS[$bucket]}" "$summary"
  if [ "${RESULTS[$bucket]}" != ok ]; then
    overall_rc=1
    echo "  --- $bucket output (tail) ---"
    if [ -s "$LOG_DIR/$bucket.log" ]; then
      tail -40 "$LOG_DIR/$bucket.log"
    else
      echo "  (no output captured - see $LOG_DIR/$bucket.log)"
    fi
  fi
done

echo
echo "Full logs at: $LOG_DIR"
exit $overall_rc
