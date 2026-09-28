#!/usr/bin/env bash
# Run the classic crystal spec suite under a hard timeout.
#
# The spec binary can wedge (rare, seen twice in one session: the process
# goes idle in the scheduler with no summary ever printed - a Crystal 1.21
# runtime/fork issue, same family as crystal-lang#12392). `crystal spec`
# has no timeout of its own and scripts/spec-parallel.sh only covers its
# own per-bucket invocations, so direct `crystal spec` calls go through
# here: on timeout the process gets SIGTERM then SIGKILL, exiting 124
# instead of hanging forever. Override the cap with SPEC_TIMEOUT (seconds).
#
# Usage: scripts/spec.sh [same args as crystal spec]

set -euo pipefail

exec timeout -k 5 "${SPEC_TIMEOUT:-900}" crystal spec "$@"
