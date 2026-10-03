#!/bin/bash
# Runs INSIDE the kp-misc2-probes smoke container (root, ubuntu:22.04,
# ansible_connection=local). Installs ansible-core via pip plus the
# collections and apt packages the kop_misc2 probes need, then runs the
# smoke wrapper play twice (cold + warm) like a krikri-role-tester round
# does, and checks both runs emit the same set of KEYORDER|<probe>| lines.
# virt_net is skipped (no libvirt in a rootless container).
# Run from this repo checkout with:
#   podman run --rm --name kp-misc2-probes-smoke \
#     -v <repo>/testing/keyorder_probes:/probes:Z -w /probes ubuntu:22.04 \
#     bash /probes/kop_misc2/smoke_inside.sh
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq python3-pip python3-setuptools maven python3-lxml >/tmp/apt.log 2>&1 || true
dpkg --configure -a >/dev/null 2>&1 || true
apt-get install -y -qq -f >/dev/null 2>&1 || true
pip3 install -q 'ansible-core==2.17.8' >/dev/null 2>&1 || true
ansible-galaxy collection install community.general community.docker community.libvirt >/dev/null 2>&1 || true
echo "using: $(ansible-playbook --version 2>/dev/null | head -1)"
cd /probes
for i in 1 2; do
  echo "=== smoke run $i ==="
  ansible-playbook -i localhost, -c local kop_misc2/smoke_wrapper.yml > /tmp/run_$i.log 2>&1
  echo "run $i ansible-playbook rc=$?"
  grep -o 'KEYORDER|[a-zA-Z0-9_]*|' /tmp/run_$i.log | sort -u > /tmp/ko_$i.txt
done
echo "run1: $(wc -l < /tmp/ko_1.txt) probes, run2: $(wc -l < /tmp/ko_2.txt) probes"
if diff /tmp/ko_1.txt /tmp/ko_2.txt; then
  echo "SMOKE OK: same probe set both runs"
else
  echo "SMOKE WARN: probe sets differ between runs"
fi
echo "=== recap (run 1) ==="
grep -E 'failed=|unreachable=' /tmp/run_1.log | tail -2
exit 0
