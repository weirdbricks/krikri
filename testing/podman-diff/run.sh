#!/usr/bin/env bash
# Local differential-testing loop: runs the same edge-case fixture
# playbooks under real ansible-playbook (container A) and
# krikri-playbook (container B), both via ansible_connection=local
# inside their own throwaway podman container, and diffs the debug
# output lines so a single divergent case is visible without needing
# a full Atlantic.net round. See krikri/CLAUDE.md's "podman run
# --systemd=always ... remains sufficient" note - this is that
# replacement, scoped to module-level edge cases rather than full
# Galaxy roles.
#
#   ./run.sh                # run all cases/*.yml
#   ./run.sh file_edge_cases.yml   # run just one
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
DIFF_DIR="$(pwd)"
REPO_DIR="$(cd "$DIFF_DIR/../.." && pwd)"
IMAGE="docker.io/library/debian:bookworm-slim"
# Per-invocation suffix: container names are global to podman, so two
# concurrent run.sh sessions (e.g. two worktrees) would otherwise keep
# rm -f'ing each other's mid-run containers.
SUFFIX="-$(date +%s)-$$"
NAME_A="krikri-diff-real$SUFFIX"
NAME_B="krikri-diff-krikri$SUFFIX"
RESULTS="$DIFF_DIR/results"
mkdir -p "$RESULTS"

log() { echo "[podman-diff] $*" >&2; }

cleanup() {
  podman rm -f "$NAME_A" "$NAME_B" >/dev/null 2>&1
}
trap cleanup EXIT

log "starting containers"
podman run -d --name "$NAME_A" "$IMAGE" sleep infinity >/dev/null
podman run -d --name "$NAME_B" "$IMAGE" sleep infinity >/dev/null

log "installing ansible-core in $NAME_A"
podman exec "$NAME_A" bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends ansible-core python3 >/dev/null" \
  || { log "FATAL: ansible-core install failed"; exit 1; }

log "staging krikri-playbook in $NAME_B"
podman exec "$NAME_B" bash -c "apt-get update -qq && apt-get install -y -qq --no-install-recommends libxml2 libssl3 libyaml-0-2 libpcre2-8-0 >/dev/null" \
  || { log "FATAL: runtime lib install failed"; exit 1; }
podman exec "$NAME_B" bash -c "mkdir -p /opt/krikri/bin"
podman cp "$REPO_DIR/bin/krikri-playbook" "$NAME_B:/opt/krikri/bin/krikri-playbook"
podman cp "$REPO_DIR/bin/plugins" "$NAME_B:/opt/krikri/bin/plugins"
podman exec "$NAME_B" bash -c "chmod +x /opt/krikri/bin/krikri-playbook /opt/krikri/bin/plugins/*"

for container in "$NAME_A" "$NAME_B"; do
  podman exec "$container" mkdir -p /work
  podman cp "$DIFF_DIR/inventory.ini" "$container:/work/inventory.ini"
  podman cp "$DIFF_DIR/templates/." "$container:/tmp/"
done

cases=("$@")
if [ ${#cases[@]} -eq 0 ]; then
  cases=()
  while IFS= read -r f; do cases+=("$(basename "$f")"); done < <(find "$DIFF_DIR/cases" -name '*.yml' | sort)
fi

overall_rc=0
for case_file in "${cases[@]}"; do
  case_name="${case_file%.yml}"
  log "=== $case_name ==="
  podman cp "$DIFF_DIR/cases/$case_file" "$NAME_A:/work/case.yml"
  podman cp "$DIFF_DIR/cases/$case_file" "$NAME_B:/work/case.yml"

  podman exec "$NAME_A" bash -c \
    "cd /work && ANSIBLE_NOCOLOR=1 ansible-playbook -i inventory.ini case.yml" \
    > "$RESULTS/${case_name}_real.log" 2>&1
  rc_a=$?

  podman exec "$NAME_B" bash -c \
    "cd /work && /opt/krikri/bin/krikri-playbook -i inventory.ini case.yml" \
    > "$RESULTS/${case_name}_krikri.log" 2>&1
  rc_b=$?

  # Extract just the debug-line payloads. Real ansible-playbook prints
  # them as `"msg": "F1 failed=..."`, krikri-playbook as a plain
  # `  F1 failed=...` - the label+key=value pattern (not just "F1")
  # is what lets this match both formats while skipping TASK-name
  # lines like "F1 touch a file ..." that also contain "F1 " but no
  # trailing key=value. The label shape is general: one uppercase
  # letter (the case-file's prefix - F=file, T=template, S=set_fact,
  # C=command, ...), digits, and an optional lowercase a-c sub-case
  # suffix, so new case files only need to pick an unused prefix.
  msgs_a="$RESULTS/${case_name}_real.msgs"
  msgs_b="$RESULTS/${case_name}_krikri.msgs"
  extract() { grep -oE '\b[A-Z][0-9]+[a-c]? [a-zA-Z_]+=.*' "$1" | sed -E 's/\\n/ | /g; s/"\}?(,)?$//'; }
  extract "$RESULTS/${case_name}_real.log" > "$msgs_a"
  extract "$RESULTS/${case_name}_krikri.log" > "$msgs_b"

  if diff -u "$msgs_a" "$msgs_b" > "$RESULTS/${case_name}.diff"; then
    log "$case_name: MATCH (rc_real=$rc_a rc_krikri=$rc_b)"
    [ "$rc_a" = "$rc_b" ] || log "$case_name: WARNING rc mismatch despite matching debug output"
  else
    log "$case_name: DIVERGENT (rc_real=$rc_a rc_krikri=$rc_b) - see $RESULTS/${case_name}.diff"
    overall_rc=1
  fi
done

exit $overall_rc
