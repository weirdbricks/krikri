#!/usr/bin/env bash
# Builds the test-host image with podman and imports it into containerd,
# where ctr (and therefore Kata) can see it. Generates the SSH keypair the
# harness uses if it isn't there yet.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[ -f key ] || ssh-keygen -q -t ed25519 -N '' -f key
podman build -q -t kata-krikri-systemd -f Containerfile . >/dev/null
podman save --format oci-archive -o /tmp/kata-krikri-systemd.tar \
  localhost/kata-krikri-systemd:latest >/dev/null 2>&1
sudo -n ctr image import --base-name localhost/kata-krikri-systemd \
  /tmp/kata-krikri-systemd.tar >/dev/null
rm -f /tmp/kata-krikri-systemd.tar
echo "localhost/kata-krikri-systemd:latest imported into containerd"
