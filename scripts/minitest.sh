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
# KRIKRI_TEST_SHARDS), each running its tests with -p 8 worker fibers on ONE
# OS thread (CRYSTAL_WORKERS=1 - more threads hit GC double-free aborts, see
# below). Sharding by process is what actually uses the extra cores: within one
# process the fibers share a single OS thread, so CPU-bound work (process
# spawns, parsing) serializes. The processes no longer each need their own
# compile: every shard runs the SAME .minitest_all.bin and takes its share of
# the tests through MINITEST_SLICE_MAP (PluginSpecHelper::Slice), so a source
# change costs one compile no matter the shard count.
#
# Which tests a shard takes is decided per TEST, not per file, by
# scripts/minitest_stats.sh from measured weight (longest first onto the
# lightest shard). Splitting by file could not balance - one file's tests all
# land on one shard and test/integration/diff_mode_test.cr alone once carried a
# sixth of the suite's measured time - and a shard that got such a file ran for
# ~5 minutes while five others idled. Tests with no measurement yet (new ones)
# are hashed onto a shard, so nothing is dropped and no warm-up run is needed.
# The weighting statistics - and the warning about what a loaded run does to a
# wall-clock measurement - live in scripts/minitest_stats.sh. Keep the fiber
# count per shard at 8: -p 24 was measured turning the plugin watchdog's
# starvation into "hung for 180s and was killed" failures.
#
# KRIKRI_TEST_SHARDS=1 or --shard 1 falls back to the single-process path below.
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

# A playbook that never exits used to freeze its whole shard: the spec's
# Process.run waits for the child and for every holder of its captured
# pipes, and nothing in the engine bounds a local plugin or a grandchild
# that inherited them (issue #1189 - three shards silent for 470s while
# their playbooks sat at 0.2% CPU). Bound every playbook the suite spawns;
# on expiry it reports its own process tree and exits 124, so the spec
# fails naming the playbook instead of hanging. Inherited by the shards
# (they export their own env) and by the single-file path below.
export KRIKRI_PLAYBOOK_DEADLINE_SECONDS="${KRIKRI_PLAYBOOK_DEADLINE_SECONDS:-120}"

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

# `crystal run` used to strip the conventional `--` separator before the
# program saw ARGV; the bare binary doesn't, and OptionParser stops at it,
# so a leading -- would silently disable every option after it. shard_args
# was captured before the shift, so strip the leading -- here instead.
if [ ${#shard_args[@]} -gt 0 ] && [ "${shard_args[0]}" = "--" ]; then
  shard_args=("${shard_args[@]:1}")
fi
set -- ${shard_args[@]+"${shard_args[@]}"}

# Per-test wall-clock timings, recorded by run_one in test/minitest_helper.cr
# and read back by scripts/minitest_stats.sh to decide what runs where. One
# line per test per run: "<seconds>\t<serial|parallel>\t<test>\t<run>".
MINITEST_TIMINGS_PATH="${MINITEST_TIMINGS:-$ROOT/.minitest_timings.tsv}"
MINITEST_RUNS_KEPT="${MINITEST_RUNS_KEPT:-3}"
RUN_HISTORY="${MINITEST_RUN_HISTORY:-$ROOT/.minitest_runs.tsv}"
# Only a WHOLE-suite run may write statistics: anything after `--` (typically
# `-n /pattern/`) runs a subset, and recording its 0.00s non-runs would both
# poison the weights and prune real runs out of the file.
if [ $# -eq 0 ]; then
  touch "$MINITEST_TIMINGS_PATH"
  export MINITEST_TIMINGS="$MINITEST_TIMINGS_PATH"
  # One id shared by every shard process, so the balancer groups by run.
  export MINITEST_RUN_ID="${MINITEST_RUN_ID:-$(date +%s)-$$}"
  RECORD_TIMINGS=1
else
  RECORD_TIMINGS=0
fi

# Keep only the newest MINITEST_RUNS_KEPT runs' records. The balancer takes the
# MAX within a run (a test is recorded several times per run and only one of
# those records does the work) and the MIN across these runs: a loaded run
# inflates every record it touched, measured at up to ~2000x (0.14s recorded as
# 273s), and inflation only ever goes one way, so the smallest value is the
# closest thing to the test's own cost. Max-ever - what this used to keep - made
# one such sample permanent, which is how a 10-test file ended up outweighing a
# sixth of the suite.
compact_timings() {
  [ "$RECORD_TIMINGS" = 1 ] || return 0
  [ -s "$MINITEST_TIMINGS_PATH" ] || return 0
  local tmp
  tmp=$(mktemp)
  awk -F'\t' -v kept="$MINITEST_RUNS_KEPT" '
    { run = ($4 == "" ? "-" : $4)
      if (!(run in seen)) { seen[run] = 1; order[++n] = run }
      line[NR] = $0; r[NR] = run }
    END {
      first = (n > kept ? n - kept + 1 : 1)
      for (i = first; i <= n; i++) keep[order[i]] = 1
      for (i = 1; i <= NR; i++) if (r[i] in keep) print line[i]
    }' "$MINITEST_TIMINGS_PATH" > "$tmp"
  mv "$tmp" "$MINITEST_TIMINGS_PATH"
}

# "00:06:46.505734533" -> 406
clock_seconds() {
  awk -F'[.:]' '{ print $1 * 3600 + $2 * 60 + $3 }'
}

# The whole suite in ONE binary: minitest registers its tests in-process, so a
# single entrypoint has to require every test file. Every shard runs this same
# binary and picks its own tests (MINITEST_SLICE_MAP, see
# PluginSpecHelper::Slice). Per-shard binaries meant N ~2.4GB crystal builds at
# once, which is what made a shard count above two unpalatable on the 16GB dev
# box, and they still could not balance (see scripts/minitest_stats.sh).
hash=$(cat "${files[@]}" "${support_files[@]}" "${source_files[@]}" "$ROOT/shard.lock" | sha256sum | cut -d' ' -f1)

build_test_binary() {
  if [ -f "$HASHFILE" ] && [ "$(cat "$HASHFILE")" = "$hash" ] && [ -x "$BINARY" ]; then
    return 0
  fi
  tmp_ep="$ENTRYPOINT.tmp"
  : > "$tmp_ep"
  for file in "${files[@]}"; do
    printf 'require "./%s"\n' "${file#"$ROOT"/}" >> "$tmp_ep"
  done
  mv "$tmp_ep" "$ENTRYPOINT"
  # Hash first, binary second - but a failed build drops BOTH, or the next run
  # would "validate" against the hash and silently execute stale code.
  echo "$hash" > "$HASHFILE"
  if ! (cd "$ROOT" && crystal build --no-debug "$ENTRYPOINT" -o "$BINARY"); then
    rm -f "$BINARY" "$HASHFILE"
    return 1
  fi
}

# Default fiber count: 8. The workers share ONE OS thread per process
# (CRYSTAL_WORKERS=1 above), so this is about overlapping waits, not cores.
# Raising it was measured: -p 24 on four shards turned the plugin watchdog's
# starvation into "plugin ... hung for 180s and was killed" failures, so the
# per-shard fiber count stays where it is and extra parallelism comes from more
# shard PROCESSES. An explicit -p/--parallel on the command line wins.
fibers=8
parallel_given=false
prev_was_p=false
for arg in "$@"; do
  if [ "$prev_was_p" = true ]; then
    fibers="$arg"
    prev_was_p=false
    continue
  fi
  case "$arg" in
    -p|--parallel)   parallel_given=true; prev_was_p=true ;;
    -p[0-9]*)        parallel_given=true; fibers="${arg#-p}" ;;
    --parallel=*)    parallel_given=true; fibers="${arg#--parallel=}" ;;
  esac
done
if [ "$parallel_given" = false ]; then
  set -- "$@" -p "$fibers"
fi

# Kills a process and everything it spawned. The shard's `timeout` wrapper is
# not a process-group leader, so a plain `kill` would leave the test binary
# and the plugin children it is holding behind.
kill_tree() {
  local parent="$1" child
  for child in $(pgrep -P "$parent" 2>/dev/null || true); do
    kill_tree "$child"
  done
  kill -KILL "$parent" 2>/dev/null || true
}

# Prints a pid and every process below it: the shard is launched as
# `timeout -> test binary -> plugin children`, and the interesting thread is
# rarely the outermost (timeout just sits in sigsuspend).
process_tree() {
  local pid="$1" child
  echo "$pid"
  for child in $(pgrep -P "$pid" 2>/dev/null || true); do
    process_tree "$child"
  done
}

# Everything worth knowing about a shard that stopped making progress, in one
# file: where each OS thread is blocked, what it is running, and the log tail.
dump_stall() {
  # Outside RUN_TMP: that whole tree is removed by the EXIT trap, and the
  # report is the only thing worth keeping after a stall.
  local i="$1" pid="$2" silent="$3" node thread
  local out="$RUN_TMP-stall-shard_$i.txt"
  local -a dump_cmd
  local pids
  pids=$(process_tree "$pid")
  {
    echo "shard $i: no output for ${silent}s (pid $pid) at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "--- process tree"
    ps -o pid,ppid,stat,%cpu,wchan:24,args -p "$(echo "$pids" | tr ' ' ',')" 2>/dev/null || true
    echo "--- OS threads: state, wchan and syscall (what each one is blocked in)"
    for node in $pids; do
      for thread in /proc/"$node"/task/*; do
        [ -r "$thread/wchan" ] || continue
        echo "  pid $node tid $(basename "$thread")  state $(awk '{print $3}' "$thread/stat" 2>/dev/null)  wchan $(cat "$thread/wchan" 2>/dev/null)  syscall $(cat "$thread/syscall" 2>/dev/null || echo "?")"
      done
    done
    if command -v eu-stack >/dev/null 2>&1; then
      dump_cmd=(eu-stack -p)
    elif command -v gdb >/dev/null 2>&1; then
      dump_cmd=(gdb -batch -ex 'thread apply all bt' -p)
    else
      dump_cmd=()
    fi
    echo "--- stacks"
    if [ ${#dump_cmd[@]} -eq 0 ]; then
      echo "neither eu-stack nor gdb on PATH: thread stacks unavailable"
    fi
    for node in $pids; do
      if [ ${#dump_cmd[@]} -eq 0 ]; then break; fi
      echo "== pid $node: $(tr '\0' ' ' < /proc/"$node"/cmdline 2>/dev/null | cut -c1-200)"
      "${dump_cmd[@]}" "$node" 2>&1 || true
    done
    echo "--- shard log tail"
    tail -n 40 "$RUN_TMP/shard_$i.log" 2>/dev/null || true
  } >"$out" 2>&1
}

# A shard that stops printing is hung, not slow: the suite's slowest ordinary
# test is ~10s, while the process-level watchdog only fires at
# MINITEST_TIMEOUT (600s) - a whole run wasted, with the evidence gone
# (issue #1189: three shards froze, and the only clue was the child processes
# blocked on full stdout pipes). Follow each shard's log growth instead, and
# on a stall dump what the shard and its threads are doing and kill it, so the
# run fails in minutes with something to work from.
watch_shards_for_stalls() {
  local default_stall=120 stall i pid size now alive
  [ -n "${KRIKRI_SLOW_TESTS:-}" ] && default_stall=600
  stall="${KRIKRI_STALL_SECONDS:-$default_stall}"
  [ "${KRIKRI_NO_STALL_WATCHDOG:-0}" = "1" ] && return 0
  { [ "$stall" -gt 0 ]; } 2>/dev/null || return 0
  local -a last_size=() last_change=()
  now=$(date +%s)
  for ((i=0; i<shards; i++)); do
    last_size[$i]=-1
    last_change[$i]="$now"
  done
  while :; do
    sleep 5
    alive=0
    now=$(date +%s)
    for ((i=0; i<shards; i++)); do
      pid="${shard_pids[$i]}"
      kill -0 "$pid" 2>/dev/null || continue
      alive=1
      size=$(stat -c %s "$RUN_TMP/shard_$i.log" 2>/dev/null || echo 0)
      if [ "$size" != "${last_size[$i]}" ]; then
        last_size[$i]="$size"
        last_change[$i]="$now"
        continue
      fi
      if [ $(( now - last_change[i] )) -ge "$stall" ]; then
        dump_stall "$i" "$pid" "$(( now - last_change[i] ))"
        echo "test: shard $i stalled: no output for $(( now - last_change[i] ))s - killed, diagnostics in $RUN_TMP-stall-shard_$i.txt" >&2
        kill_tree "$pid"
        : > "$RUN_TMP/shard_$i.stalled"
        last_change[$i]="$now"
      fi
    done
    [ "$alive" -eq 1 ] || break
  done
}

# ---- sharded path: N processes, one binary, test-level slices ----
if [ "$shards" -ge 2 ]; then
  build_start=$(date +%s)
  build_test_binary || exit 1
  build_s=$(( $(date +%s) - build_start ))

  # Assign every MEASURED test to a shard by measured weight (LPT). A test with
  # no measurement - added since the last publish - is hashed onto a shard by
  # run_one instead of being skipped, so nothing is ever dropped and a cold
  # checkout needs no warm-up run.
  slice_dir="$RUN_TMP/slices"
  slice_map="$slice_dir/map.tsv"
  if ! scripts/minitest_stats.sh --slices "$shards" "$slice_dir" >/dev/null 2>"$RUN_TMP/slices.log"; then
    echo "test: slice assignment failed - every shard will hash-scatter all tests" >&2
    cat "$RUN_TMP/slices.log" >&2
  else
    sed 's/^stats: /test: /' "$RUN_TMP/slices.log" >&2 || true
  fi
  [ -s "$slice_map" ] || : > "$slice_map"

  echo "test: running $shards shards in parallel ($fibers fibers each, one binary)" >&2
  run_start=$(date +%s)
  # `exec`, so $! is the shard itself (not a wrapper subshell) and the stall
  # watchdog can inspect the pid that actually runs the tests.
  shard_pids=()
  for ((i=0; i<shards; i++)); do
    s_log="$RUN_TMP/shard_$i.log"
    (
      export TMPDIR="$RUN_TMP/s$i"
      mkdir -p "$TMPDIR"
      export MINITEST_SLICE_MAP="$slice_map" MINITEST_SLICE_INDEX="$i" MINITEST_SLICE_COUNT="$shards"
      exec timeout -k 5 "${MINITEST_TIMEOUT:-600}" "$BINARY" "$@"
    ) >"$s_log" 2>&1 &
    shard_pids[$i]=$!
  done
  watch_shards_for_stalls
  for ((i=0; i<shards; i++)); do
    crc=0
    wait "${shard_pids[$i]}" || crc=$?
    echo "$crc" > "$RUN_TMP/shard_$i.rc"
  done
  run_s=$(( $(date +%s) - run_start ))
  compact_timings

  rc_total=0
  total_tests=0
  total_fails=0
  total_errors=0
  slowest=0
  for ((i=0; i<shards; i++)); do
    s_log="$RUN_TMP/shard_$i.log"
    crc=$(cat "$RUN_TMP/shard_$i.rc")
    summary=$(grep -E '^[0-9]+ (tests|runs),' "$s_log" | tail -1 || true)
    echo "shard $i: exit=$crc  ${summary:-<no summary - see $s_log>}" >&2
    if [ -n "$summary" ]; then
      total_tests=$(( total_tests + $(echo "$summary" | sed -E 's/^([0-9]+).*/\1/') ))
      fails=$(echo "$summary" | sed -E 's/.* ([0-9]+) failures,.*/\1/' | grep -E '^[0-9]+$' || echo 0)
      total_fails=$(( total_fails + fails ))
      errs=$(echo "$summary" | sed -E 's/.* ([0-9]+) errors,.*/\1/' | grep -E '^[0-9]+$' || echo 0)
      total_errors=$(( total_errors + errs ))
    fi
    finished=$(grep -oE 'Finished in [0-9:.]+' "$s_log" | tail -1 | awk '{print $3}' || true)
    if [ -n "$finished" ]; then
      secs=$(echo "$finished" | clock_seconds)
      if [ "$secs" -gt "$slowest" ]; then slowest=$secs; fi
    fi
    if [ "$crc" -ne 0 ]; then
      rc_total=$crc
      if [ -f "$RUN_TMP/shard_$i.stalled" ]; then
        echo "--- shard $i stalled until killed (full report: $RUN_TMP-stall-shard_$i.txt) ---" >&2
        cat "$RUN_TMP-stall-shard_$i.txt" >&2 2>/dev/null || true
      else
        echo "--- shard $i output (last 120 lines; full log: $s_log) ---" >&2
        tail -n 120 "$s_log" >&2
      fi
    fi
  done

  # One line per run: enough to tell "the shard count helped" from "that run
  # happened to land well" weeks later. --publish promotes it into the repo.
  if [ "$RECORD_TIMINGS" = 1 ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
      "$shards" "$fibers" "$total_tests" "$total_fails" "$total_errors" "$build_s" "$run_s" "$slowest" >> "$RUN_HISTORY"
  fi
  echo "test: $shards shards x $fibers fibers: $total_tests tests, $total_fails failures, $total_errors errors, build ${build_s}s, run ${run_s}s, slowest shard ${slowest}s (scripts/minitest_stats.sh)" >&2
  exit "$rc_total"
fi

# ---- single-process path (shards=1): one entrypoint, one binary ----
build_test_binary || exit 1

# Not exec: the EXIT trap has to run after the suite to remove its TMPDIR.
rc=0
timeout -k 5 "${MINITEST_TIMEOUT:-600}" "$BINARY" "$@" || rc=$?
compact_timings
exit "$rc"
