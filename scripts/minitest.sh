#!/usr/bin/env bash
# Run the minitest suite under test/.
#
# Minitest registers its tests in-process and runs them from an at_exit
# hook, so one entrypoint has to require every test file - there is no
# per-file discovery like `crystal spec` does. This script globs
# test/**/*_test.cr into .minitest_all.cr, builds .minitest_all.bin once,
# and reuses that binary until test/, src/, plugins/, lib/ or shard.lock change
# (content-hash-gated, same idea as build.sh's mtime skip) - `crystal run`
# would otherwise pay the
# full ~12-15s compile on every invocation.
#
# Usage:
#   scripts/minitest.sh                 # whole minitest suite, 6 shards by default
#   scripts/minitest.sh --shard 8       # whole suite on 8 shard processes
#   scripts/minitest.sh test/unit/foo_test.cr   # a single file, passed through
#   scripts/minitest.sh -- -n /pattern/       # args after -- go to the binary
#
# Parallelism: the full suite defaults to 6 OS processes (`--shard N`, or
# KRIKRI_TEST_SHARDS), each running its slice of the test files with -p 8
# worker fibers on ONE OS thread (CRYSTAL_WORKERS=1). Sharding by process is
# what actually uses the extra cores: within one process the fibers all
# share a single OS thread, so CPU-bound work (process spawns, parsing)
# serializes - 4 processes x -p 8 measured ~47% faster wall-clock than one
# process at -p 8 (41s vs 77s). The old "N=6 added nothing" measurement was
# made with count-based shard weights; re-measured interleaved against
# --shard 4 after the switch to measured-time weights, 6 was faster in
# every contemporaneous pairing (~5-11s, more under ambient load). Each
# shard needs its own compiled
# binary (the entrypoint only requires its own slice of test files), built
# concurrently and hash-gated like the single binary; the tradeoff is that a
# source change now costs N compiles instead of one (~45s parallel vs ~15s),
# which is still small next to the suite itself. KRIKRI_TEST_SHARDS=1 or
# --shard 1 falls back to the original single-process path below.
#
# The tests must then be parallel-safe both within a shard and across shard
# processes: per-test tmp state comes from PluginSpecHelper.tmp_path (scoped
# by the run_one hook in test/minitest_helper.cr), ENV/global-state tests
# serialize on PluginSpecHelper::ENV_MUTEX / ::STATE_MUTEX within their
# process, and there is no shared mutable suite state across processes by
# construction (each shard gets its own TMPDIR subtree). The workers stay on
# ONE OS thread per shard (CRYSTAL_WORKERS=1): spread over multiple threads
# the suite hits GC double-free aborts and futex deadlocks (Crystal MT
# runtime), so the cap is set here unless overridden.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Scratch from the suite goes under one TMPDIR per run (Dir.tempdir and File.tempname follow it),
# removed when the run ends. It lives on disk under the user's cache, not /tmp: /tmp is a RAM-backed
# tmpfs on the dev box, and the suite used to leave hundreds of krikri-* dirs there. It stays outside
# the checkout too: lint reports paths relative to the cwd when a file is inside it, and its import
# tests expect absolute paths. Files a rootless container wrote are owned by its subuid, which rm
# cannot remove, so podman unshare is the fallback.
RUN_TMP="${KRIKRI_TEST_TMPDIR:-${XDG_CACHE_HOME:-$HOME/.cache}/krikri-test-tmp}/run-$$"
mkdir -p "$RUN_TMP"
export TMPDIR="$RUN_TMP"
cleanup_run_tmp() {
  rm -rf "$RUN_TMP" 2>/dev/null || podman unshare rm -rf "$RUN_TMP" 2>/dev/null || true
}
trap cleanup_run_tmp EXIT

# The caller's ANSIBLE_* settings leak into every krikri-playbook the suite
# spawns: a developer shell with ANSIBLE_CACHE_PLUGIN=...pickle made
# cross-play hostvars reads pass locally (served from the pickle cache)
# while the same tests failed in CI. Tests that need an ANSIBLE_* value set
# it themselves. Same for the docker CLI's ambient connection settings: a
# DOCKER_HOST at a socket-activated podman daemon makes every plugin run
# that probes the daemon pay a ~2s activation (or ~0s when already warm -
# nondeterministic), and lets daemon-dependent smoke tests run against a
# "reachable" daemon they did not provision. Tests that need a connection
# set docker_host/_environment explicitly.
while IFS= read -r var; do
  unset "$var"
done < <(env | grep -o '^ANSIBLE_[A-Za-z0-9_]*')
unset DOCKER_HOST DOCKER_CONTEXT

# Shrink the apt retry helpers' inter-attempt backoff (1-3s sleeps) to
# milliseconds: the retry specs exercise the retry/booking logic and warn
# texts, not the wall-clock backoff, and the "Sleeping for N seconds"
# texts are computed from the unscaled delay so they stay live-captured.
# AptLockRetry#retry_sleep and the controller-side pause action plugin read
# it; the standalone plugins/pause.cr binary does NOT (its specs assert real
# elapsed time). Never set it outside the suite.
export KRIKRI_TEST_SLEEP_SCALE=0.01

# Most integration specs don't call engine code in-process: they spawn
# bin/krikri-playbook (and bin/plugins/*) and assert on what it prints.
# Those binaries are compiled ONLY by ./build.sh, while the suite binary
# below is rebuilt here from src/ + lib/ - so after an edit, or after
# `shards install`/`shards update` swaps the engine shard under lib/, the
# suite compiles against the new sources while every spawned binary keeps
# running the PREVIOUS build until someone remembers ./build.sh. The
# symptoms are a handful of order-dependent failures whose assertions are
# about the engine (groupby rendering [grouper, list] pairs rather than
# {grouper, list} objects is exactly that: it lives in lib/krikri-jinja,
# the shard bump lands in lib/ first, and ./build.sh is a separate step).
# Refresh the spawned binaries from the same sources the suite is built
# from, so both halves always come from one revision. build.sh is
# mtime-gated, so this is a no-op (one find) whenever they already agree.
spawned_binaries_stale() {
  local main_bin="$ROOT/bin/krikri-playbook"
  [ -x "$main_bin" ] || return 0 # never built: nothing to compare against
  [ -n "$(find "$ROOT/src" "$ROOT/lib" "$ROOT/plugins" -name '*.cr' -newer "$main_bin" -print -quit 2>/dev/null)" ]
}

if spawned_binaries_stale; then
  echo "test: bin/krikri-playbook is older than src//lib//plugins/ - building it first" >&2
  if ! (cd "$ROOT" && ./build.sh >&2); then
    echo "test: ./build.sh FAILED - specs that spawn bin/krikri-playbook will run against a stale build" >&2
  fi
fi

# A single explicit test file is run directly; no globbing needed.
if [ $# -gt 0 ] && [ -f "${1:-}" ]; then
  cd "$ROOT"
  crystal run "$@"
  exit 0
fi

# One heavy compile-or-suite activity at a time on this host: the shard builds below
# spawn one crystal compiler per shard, and a second suite (or fix-issues' build.sh and
# quick suite, which take the same lock) stacked on top OOM'd / hung the desktop. Held
# across the builds AND the run; released when the script and the children that
# inherited fd 9 exit. Single-file runs (the early exit above) stay lockless.
LOCK="${KRIKRI_COMPILE_LOCK:-${XDG_CACHE_HOME:-$HOME/.cache}/krikri-compile.lock}"
mkdir -p "$(dirname "$LOCK")"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "test: another compile or suite run holds $LOCK - waiting ..." >&2
  flock 9
fi

# The entrypoint has to live inside the project: `crystal run` only resolves
# relative requires against the entrypoint's own directory, and absolute
# requires are not resolved from a file outside the project root.
ENTRYPOINT="$ROOT/.minitest_all.cr"
BINARY="$ROOT/.minitest_all.bin"
HASHFILE="$ROOT/.minitest_all.hash"

files=()
while IFS= read -r file; do
  files+=("$file")
done < <(find "$ROOT/test" -name '*_test.cr' | sort)

if [ ${#files[@]} -eq 0 ]; then
  echo "no test/**/*_test.cr files found" >&2
  exit 2
fi

# Shard count for full-suite runs: --shard N on the command line wins over
# KRIKRI_TEST_SHARDS, which wins over the default of 6. 1 disables sharding.
shards="${KRIKRI_TEST_SHARDS:-6}"
shard_args=()
next_is_shard=false
for arg in "$@"; do
  if [ "$next_is_shard" = true ]; then
    shards="$arg"
    next_is_shard=false
    continue
  fi
  case "$arg" in
    --shard=*) shards="${arg#--shard=}" ;;
    --shard)   next_is_shard=true ;;
    *)         shard_args+=("$arg") ;;
  esac
done
if [ "$next_is_shard" = true ]; then
  echo "--shard given without a count" >&2
  exit 2
fi
if ! [ "$shards" -ge 1 ] 2>/dev/null; then
  echo "--shard/KRIKRI_TEST_SHARDS must be a positive integer, got '$shards'" >&2
  exit 2
fi

# Non-_test.cr support files (test/minitest_helper.cr) are pulled into the
# build transitively but aren't in `files`, so hash them too or a helper-only
# change would silently run a stale binary.
support_files=()
while IFS= read -r file; do
  support_files+=("$file")
done < <(find "$ROOT/test" -name '*.cr' ! -name '*_test.cr' | sort)

# The code under test (src/, plugins/) and the installed shards (lib/ -
# shard.lock alone isn't enough: lib/ can lag it after a rebase until the
# next `shards install`) are compiled into the binary too - leave them out
# and an engine-only change silently runs against the previous build.
source_files=()
while IFS= read -r file; do
  source_files+=("$file")
done < <(find "$ROOT/src" "$ROOT/plugins" "$ROOT/lib" -name '*.cr' | sort)

cd "$ROOT"
export CRYSTAL_WORKERS="${CRYSTAL_WORKERS:-1}"

# Per-test wall-clock timings, recorded by run_one in test/minitest_helper.cr
# and fed back as the NEXT full run's shard weights (see the sharded path).
# After each run the file is compacted to one max-per-name line, so it stays
# small and - crucially - stable between source changes: a changed timings
# file changes the shard assignment, which changes the hashed entrypoints
# and forces N recompiles. Max-over-runs is monotone, so weights only drift
# when a test genuinely got slower; whole-second quantization in the weights
# script absorbs the rest of the jitter.
MINITEST_TIMINGS_PATH="$ROOT/.minitest_timings.tsv"
touch "$MINITEST_TIMINGS_PATH"
export MINITEST_TIMINGS="$MINITEST_TIMINGS_PATH"

# Compact to one max-per-name record (same rule as minitest_timings.sh's
# summarizer). Run after every full-suite invocation - both paths below.
compact_timings() {
  local tmp
  tmp=$(mktemp)
  awk -F'\t' '{ t = $1 + 0; m[$3] = (t > m[$3] + 0 ? t : m[$3] + 0) }
    END { for (k in m) print m[k] + 0 "\tparallel\t" k }' "$MINITEST_TIMINGS_PATH" > "$tmp"
  mv "$tmp" "$MINITEST_TIMINGS_PATH"
}

# `crystal run` used to strip the conventional `--` separator before the
# program saw ARGV; the bare binary doesn't, and OptionParser stops at it,
# so a leading -- would silently disable every option after it. shard_args
# was captured before the shift, so strip the leading -- here instead.
if [ ${#shard_args[@]} -gt 0 ] && [ "${shard_args[0]}" = "--" ]; then
  shard_args=("${shard_args[@]:1}")
fi
set -- ${shard_args[@]+"${shard_args[@]}"}

# ---- sharded path: N OS processes, each with its own entrypoint/binary ----
if [ "$shards" -ge 2 ]; then
  # Default per-shard fiber count: 8 (measured 41s vs 45s at -p 4; -p 12
  # and CRYSTAL_WORKERS=2 added nothing). An explicit -p/--parallel on the
  # command line wins and applies to every shard.
  parallel_given=false
  for arg in "$@"; do
    case "$arg" in
      -p|--parallel) parallel_given=true ;;
      -p[0-9]*)      parallel_given=true ;;
    esac
  done
  if [ "$parallel_given" = false ]; then
    set -- "$@" -p 8
  fi

  # Balance the shards by measured weight, not by file count: a plain
  # round-robin leaves the slowest shard ~29% heavier than the lightest
  # (2632 vs 2051 tests), and the wall time IS the slowest shard. Weight
  # each file by the measured seconds of its tests (from the timings file
  # the previous run wrote; minitest_file_weights.sh reconstructs test
  # names per file the way minitest builds them, and falls back to the
  # seconds-per-test average times it-count for anything unmeasured - or
  # to pure it-counts, one awk pass, when no timings exist yet) and assign
  # heaviest-file-to-lightest-shard (LPT). Deterministic: the file
  # list is sorted and ties break on path, so the same sources + timings
  # always produce the same assignment - which matters because the assignment is
  # baked into each shard's hashed entrypoint.
  if [ -s "$MINITEST_TIMINGS_PATH" ]; then
    mapfile -t weighted < <(scripts/minitest_file_weights.sh "$MINITEST_TIMINGS_PATH" "${files[@]}")
  else
    mapfile -t weighted < <(awk '
      FNR == 1 { if (seen) print cnt "\t" prev; prev = FILENAME; cnt = 0; seen = 1 }
      /^[[:space:]]*it[[:space:]]/ { cnt++ }
      END { if (seen) print cnt "\t" prev }
    ' "${files[@]}" | sort -t$'\t' -k1,1nr -k2,2)
  fi
  shard_weights=()
  shard_flists=()
  shard_counts=()
  for ((i=0; i<shards; i++)); do
    shard_weights[$i]=0
    shard_counts[$i]=0
    shard_flists[$i]=""
  done
  while IFS=$'\t' read -r cnt fpath; do
    best=0
    for ((i=1; i<shards; i++)); do
      if (( shard_weights[$i] < shard_weights[$best] )); then best=$i
      # equal-weight tie-break on fewest files: zero-weight files would
      # otherwise all pile onto one shard (weight 0 + weight 0 = 0)
      elif (( shard_weights[$i] == shard_weights[$best] && shard_counts[$i] < shard_counts[$best] )); then best=$i
      fi
    done
    shard_weights[$best]=$(( shard_weights[$best] + cnt ))
    shard_counts[$best]=$(( shard_counts[$best] + 1 ))
    shard_flists[$best]+="$fpath"$'\n'
  done < <(printf '%s\n' "${weighted[@]}")

  shard_pids=()
  shard_built=()
  for ((i=0; i<shards; i++)); do
    s_ep="$ROOT/.minitest_shard_${i}.cr"
    s_bin="$ROOT/.minitest_shard_${i}.bin"
    s_hash="$ROOT/.minitest_shard_${i}.hash"
    s_tmp_ep="$s_ep.tmp"
    : > "$s_tmp_ep"
    reqs=()
    while IFS= read -r f; do
      reqs+=("${f#"$ROOT"/}")
    done < <(printf '%s' "${shard_flists[$i]}" | sort)
    for req in "${reqs[@]}"; do
      printf 'require "./%s"\n' "$req" >> "$s_tmp_ep"
    done
    mv "$s_tmp_ep" "$s_ep"
    # Same hash discipline as the single binary below: the shard's own file
    # slice, the non-_test.cr support files, all compiled sources and
    # shard.lock.
    s_h=$( (printf '%s\n' "${reqs[@]}"; cat "${support_files[@]}" "${source_files[@]}" "$ROOT/shard.lock") | sha256sum | cut -d' ' -f1)
    shard_built[$i]=0
    if [ ! -f "$s_hash" ] || [ "$(cat "$s_hash")" != "$s_h" ] || [ ! -x "$s_bin" ]; then
      # Hash first, binary second; on build failure drop BOTH or the next
      # run would "validate" against the hash and run stale code.
      echo "$s_h" > "$s_hash"
      ( crystal build --no-debug "$s_ep" -o "$s_bin" ) >"$RUN_TMP/build_$i.log" 2>&1 &
      shard_pids[$i]=$!
      shard_built[$i]=1
    fi
  done

  build_failed=0
  for ((i=0; i<shards; i++)); do
    if [ "${shard_built[$i]}" = 1 ]; then
      if ! wait "${shard_pids[$i]}"; then
        echo "test: shard $i BUILD FAILED:" >&2
        tail -20 "$RUN_TMP/build_$i.log" >&2
        rm -f "$ROOT/.minitest_shard_${i}.bin" "$ROOT/.minitest_shard_${i}.hash"
        build_failed=1
      fi
    fi
  done
  [ "$build_failed" = 0 ] || exit 1

  echo "test: running $shards shards in parallel" >&2
  for ((i=0; i<shards; i++)); do
    s_bin="$ROOT/.minitest_shard_${i}.bin"
    s_log="$RUN_TMP/shard_$i.log"
    (
      export TMPDIR="$RUN_TMP/s$i"
      mkdir -p "$TMPDIR"
      crc=0
      timeout -k 5 "${MINITEST_TIMEOUT:-600}" "$s_bin" "$@" >"$s_log" 2>&1 || crc=$?
      echo "$crc" > "$RUN_TMP/shard_$i.rc"
    ) &
  done
  wait
  compact_timings

  rc_total=0
  for ((i=0; i<shards; i++)); do
    s_log="$RUN_TMP/shard_$i.log"
    crc=$(cat "$RUN_TMP/shard_$i.rc")
    summary=$(grep -E '^[0-9]+ (tests|runs),' "$s_log" | tail -1)
    echo "shard $i: exit=$crc  ${summary:-<no summary - see $s_log>}" >&2
    if [ "$crc" -ne 0 ]; then
      rc_total=$crc
      echo "--- shard $i output (last 120 lines; full log: $s_log) ---" >&2
      tail -n 120 "$s_log" >&2
    fi
  done
  exit "$rc_total"
fi

# ---- single-process path (shards=1): one entrypoint, one binary ----

hash=$(cat "${files[@]}" "${support_files[@]}" "${source_files[@]}" "$ROOT/shard.lock" | sha256sum | cut -d' ' -f1)

if [ ! -f "$HASHFILE" ] || [ "$(cat "$HASHFILE")" != "$hash" ] || [ ! -f "$BINARY" ]; then
  tmp_ep="$ROOT/.minitest_all.cr.tmp"
  : > "$tmp_ep"
  for file in "${files[@]}"; do
    printf 'require "./%s"\n' "${file#"$ROOT"/}" >> "$tmp_ep"
  done
  mv "$tmp_ep" "$ENTRYPOINT"
  # Hash first, binary second - but if the build fails, drop BOTH the
  # recorded hash and the previous binary, or the next run would
  # "validate" against the hash and silently execute stale code.
  echo "$hash" > "$HASHFILE"
  if ! (cd "$ROOT" && crystal build --no-debug "$ENTRYPOINT" -o "$BINARY"); then
    rm -f "$BINARY" "$HASHFILE"
    exit 1
  fi
fi

# Default parallelism: 8 worker fibers. The suite is IO/sleep-bound, so
# the sleeps genuinely overlap and wall time drops ~35% vs -p 4 (measured:
# 1m25s vs 2m00s); the workers stay on ONE OS thread (CRYSTAL_WORKERS=1
# above), so this costs no extra cores. An explicit -p/--parallel on the
# command line wins.
parallel_given=false
for arg in "$@"; do
  case "$arg" in
    -p|--parallel) parallel_given=true ;;
    -p[0-9]*)      parallel_given=true ;;
  esac
done
if [ "$parallel_given" = false ]; then
  set -- "$@" -p 8
fi

# Not exec: the EXIT trap has to run after the suite to remove its TMPDIR.
rc=0
timeout -k 5 "${MINITEST_TIMEOUT:-600}" "$BINARY" "$@" || rc=$?
compact_timings
exit "$rc"
