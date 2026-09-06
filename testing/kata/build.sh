#!/usr/bin/env bash
# Builds the test-host image(s) with podman and imports them into
# containerd, where ctr (and therefore Kata) can see them. Generates the
# SSH keypair the harness uses if it isn't there yet.
#
#   ./build.sh            -> Debian image only (kata-krikri-systemd), the
#                             long-standing default
#   ./build.sh rocky      -> Rocky/RHEL-family image only (kata-krikri-systemd-rocky)
#   ./build.sh all        -> both
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
[ -f key ] || ssh-keygen -q -t ed25519 -N '' -f key

build_one() {
  local tag="$1" containerfile="$2"
  podman build -q -t "$tag" -f "$containerfile" . >/dev/null
  podman save --format oci-archive -o "/tmp/${tag}.tar" "localhost/${tag}:latest" >/dev/null 2>&1
  sudo -n ctr image import --base-name "localhost/${tag}" "/tmp/${tag}.tar" >/dev/null
  rm -f "/tmp/${tag}.tar"
  echo "localhost/${tag}:latest imported into containerd"
}

target="${1:-debian}"
case "$target" in
  debian) build_one "kata-krikri-systemd" "Containerfile" ;;
  rocky)  build_one "kata-krikri-systemd-rocky" "Containerfile.rocky" ;;
  all)
    build_one "kata-krikri-systemd" "Containerfile"
    build_one "kata-krikri-systemd-rocky" "Containerfile.rocky"
    ;;
  *) echo "usage: $0 [debian|rocky|all]" >&2; exit 2 ;;
esac
