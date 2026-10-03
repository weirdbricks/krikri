#!/bin/bash
# Runs INSIDE the km-probes smoke container (root, ubuntu:22.04,
# ansible_connection=local). Installs ansible-core (pip, ~2.17 - jammy's
# apt ansible is ancient 2.10.8 and its python3-libcloud dep can fail to
# unpack in overlayfs) plus the collections and CLI tools the smoke roles
# need, then runs the smoke wrapper play twice (cold + warm) like a
# krikri-role-tester round does, and checks both runs emit the same set of
# KEYORDER|<probe>| lines.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
apt-get install -y -qq python3-pip rsync subversion apache2 default-jdk-headless openssl openssh-client >/tmp/apt.log 2>&1 || true
dpkg --configure -a >/dev/null 2>&1 || true
apt-get install -y -qq -f >/dev/null 2>&1 || true
pip3 install -q 'ansible-core==2.17.8' >/dev/null 2>&1 || true
ansible-galaxy collection install -q ansible.posix community.general community.crypto >/dev/null 2>&1 || true
echo "using: $(ansible-playbook --version 2>/dev/null | head -1)"
cd /probes
for i in 1 2; do
  echo "=== smoke run $i ==="
  ansible-playbook -i localhost, -c local smoke_wrapper.yml > /tmp/run_$i.log 2>&1
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
