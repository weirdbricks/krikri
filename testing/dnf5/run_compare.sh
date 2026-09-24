#!/usr/bin/env bash
# Side-by-side dnf5 option parity harness: runs a playbook with BOTH real
# ansible-playbook and krikri-playbook against an identical, freshly-started
# Fedora 41 (dnf5) container each time (connection: local), so the two engines
# never share package state. Each run writes a canonical per-task status report
# (report-<engine>.txt); the script diffs them.
#
# Base image requirement: python3-libdnf5 present (the real dnf5 module needs
# it) - see the dnf5cmp-base image built from krikri-fedora-compat.
set -euo pipefail
WT="$(cd "$(dirname "$0")/../.." && pwd)"
PLAY="${1:-testing/dnf5/smoke.yml}"
BASE="${DNF5_BASE_IMAGE:-localhost/dnf5cmp-base:latest}"
OUTDIR="$WT/testing/dnf5"

run_engine() {
  local engine="$1"
  local c="dnf5run-${engine}"
  podman rm -f "$c" >/dev/null 2>&1 || true
  podman run -d --name "$c" -v "$WT:/repo" "$BASE" sleep infinity >/dev/null

  echo "### [$engine] running $PLAY"
  if [ "$engine" = "ansible" ]; then
    podman exec "$c" bash -lc "cd /repo && ANSIBLE_FORCE_COLOR=0 ANSIBLE_NOCOLOR=1 \
      /opt/ansible-venv/bin/ansible-playbook -i testing/dnf5/inventory '$PLAY'" \
      > "$OUTDIR/log-ansible.txt" 2>&1 || true
  else
    podman exec "$c" bash -lc "cd /repo && /repo/bin/krikri-playbook -i testing/dnf5/inventory '$PLAY'" \
      > "$OUTDIR/log-krikri.txt" 2>&1 || true
  fi

  if [ -f "$OUTDIR/last_report.txt" ]; then
    mv "$OUTDIR/last_report.txt" "$OUTDIR/report-${engine}.txt"
  else
    echo "!!! [$engine] no report produced" > "$OUTDIR/report-${engine}.txt"
  fi
  if [ -f "$OUTDIR/last_msgs.txt" ]; then
    mv "$OUTDIR/last_msgs.txt" "$OUTDIR/msgs-${engine}.txt"
  fi
  podman rm -f "$c" >/dev/null 2>&1 || true
}

run_engine ansible
run_engine krikri

echo
echo "=================== REPORT DIFF (ansible vs krikri) ==================="
if diff -u "$OUTDIR/report-ansible.txt" "$OUTDIR/report-krikri.txt"; then
  echo "IDENTICAL - no divergence"
else
  echo ">>> divergences above <<<"
fi

echo
echo "=================== FAILURE-MESSAGE DIFF (ansible vs krikri) ==================="
if [ -f "$OUTDIR/msgs-ansible.txt" ] && [ -f "$OUTDIR/msgs-krikri.txt" ]; then
  diff -u "$OUTDIR/msgs-ansible.txt" "$OUTDIR/msgs-krikri.txt" && echo "messages IDENTICAL"
fi

echo
echo "=================== PLAY RECAP comparison ==================="
echo "--- ansible ---"; grep -A6 "PLAY RECAP" "$OUTDIR/log-ansible.txt" | tail -7 || true
echo "--- krikri    ---"; grep -A6 "PLAY RECAP" "$OUTDIR/log-krikri.txt" | tail -7 || true
