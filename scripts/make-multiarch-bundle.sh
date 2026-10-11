#!/usr/bin/env bash
# Assemble krikri-<tag>-linux-multiarch.tar.gz from the two per-arch Linux
# release tarballs: x86_64/ and aarch64/ each hold that arch's controller
# plus its own plugins/ and a plugins-<other arch>/ symlink to the other
# arch's plugins, which is where the controller looks for binaries to
# upload to a target of the other architecture.
#
# usage: make-multiarch-bundle.sh <tag> <dir-with-the-two-tarballs> <out-dir>
set -euo pipefail

tag=$1 src=$2 out=$3
pkg="krikri-${tag}-linux-multiarch"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/$pkg" "$out"
for pair in x86_64:x86_64 aarch64:arm64; do
  arch=${pair%%:*} rel=${pair##*:}
  tar -C "$work" -xzf "$src/krikri-${tag}-linux-${rel}.tar.gz"
  mv "$work/krikri-${tag}-linux-${rel}" "$work/$pkg/$arch"
done
ln -s ../aarch64/plugins "$work/$pkg/x86_64/plugins-aarch64"
ln -s ../x86_64/plugins "$work/$pkg/aarch64/plugins-x86_64"

cat > "$work/$pkg/README.txt" <<README
krikri ${tag} - Linux multi-arch bundle

Run the controller in the directory matching THIS machine's CPU
(uname -m): x86_64/krikri-playbook or aarch64/krikri-playbook. Each
directory also carries the other architecture's plugins
(plugins-aarch64/ or plugins-x86_64/), so one controller can manage
targets of both architectures. Keep each directory intact.
README

tar -C "$work" -czf "$out/${pkg}.tar.gz" "$pkg"
ls -lh "$out/${pkg}.tar.gz"
