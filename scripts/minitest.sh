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
#   scripts/minitest.sh                 # whole minitest suite
#   scripts/minitest.sh test/unit/foo_test.cr   # a single file, passed through
#   scripts/minitest.sh -- -n /pattern/       # args after -- go to the binary
#
# Parallelism: pass -- -p N for N worker fibers. Workers run on fibers, so
# the suite's IO/sleep-bound tests genuinely overlap (~6x faster at -p 8),
# but the tests must then be parallel-safe: per-test tmp state comes from
# PluginSpecHelper.tmp_path (scoped by the run_one hook in
# test/minitest_helper.cr), and ENV/global-state tests serialize on
# PluginSpecHelper::ENV_MUTEX / ::STATE_MUTEX. The workers stay on ONE OS
# thread (CRYSTAL_WORKERS=1): spread over multiple threads the suite hits
# GC double-free aborts and futex deadlocks (Crystal 1.21 MT runtime), so
# the cap is set here unless overridden.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# A single explicit test file is run directly; no globbing needed.
if [ $# -gt 0 ] && [ -f "${1:-}" ]; then
  cd "$ROOT"
  exec crystal run "$@"
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

cd "$ROOT"
export CRYSTAL_WORKERS="${CRYSTAL_WORKERS:-1}"

# `crystal run` used to strip the conventional `--` separator before the
# program saw ARGV; the bare binary doesn't, and OptionParser stops at it,
# so a leading -- would silently disable every option after it.
[ "${1:-}" = "--" ] && shift

exec timeout -k 5 "${MINITEST_TIMEOUT:-600}" "$BINARY" "$@"
