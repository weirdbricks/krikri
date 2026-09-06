#!/usr/bin/env bash
# Runs up to 4 roles concurrently, each its own fresh Kata pair.
#   ./run_batch.sh <results_dir> <role1> [role2] [role3] [role4]
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

results_dir="${1:?results_dir}"; shift
mkdir -p "$results_dir"

octet=10
pids=()
for role in "$@"; do
  oa=$((octet)); ob=$((octet+1))
  octet=$((octet+2))
  ./run_role.sh "$role" "$oa" "$ob" "$results_dir" &
  pids+=($!)
done

for pid in "${pids[@]}"; do
  wait "$pid"
done

echo "batch done:"
for role in "$@"; do
  printf '  %-55s %s\n' "$role" "$(cat "$results_dir/$role/status" 2>/dev/null || echo MISSING)"
done
