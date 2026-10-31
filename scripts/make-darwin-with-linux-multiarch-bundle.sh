#!/usr/bin/env bash
# Assemble krikri-<tag>-darwin-with-linux-multiarch.tar.gz from the four release
# tarballs (darwin x86_64/arm64 + linux x86_64/arm64). A Mac controller
# can only upload Linux plugins to Linux targets, which need
# plugins-linux-<arch>/ next to the controller (see plugin_manager.cr
# platform_key), so each Mac controller dir carries:
#   plugins/                  its own (Mach-O) plugins, for Mac targets
#   plugins-<other mac arch>  symlink, for Mac targets of the other CPU
#   plugins-linux-<arch>      symlink to the shared Linux plugin sets
#
# usage: make-darwin-with-linux-multiarch-bundle.sh <tag> <dir-with-the-four-tarballs> <out-dir>
set -euo pipefail

tag=$1 src=$2 out=$3
pkg="krikri-${tag}-darwin-with-linux-multiarch"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/$pkg" "$out"
for pair in x86_64:x86_64 aarch64:arm64; do
  arch=${pair%%:*} rel=${pair##*:}
  tar -C "$work" -xzf "$src/krikri-${tag}-darwin-${rel}.tar.gz"
  mv "$work/krikri-${tag}-darwin-${rel}" "$work/$pkg/darwin-$arch"
  tar -C "$work" -xzf "$src/krikri-${tag}-linux-${rel}.tar.gz"
  mv "$work/krikri-${tag}-linux-${rel}/plugins" "$work/$pkg/plugins-linux-$arch"
  rm -rf "$work/krikri-${tag}-linux-${rel}"
done
for arch in x86_64 aarch64; do
  other=$([ "$arch" = x86_64 ] && echo aarch64 || echo x86_64)
  d="$work/$pkg/darwin-$arch"
  ln -s "../darwin-$other/plugins" "$d/plugins-$other"
  ln -s ../plugins-linux-x86_64 "$d/plugins-linux-x86_64"
  ln -s ../plugins-linux-aarch64 "$d/plugins-linux-aarch64"
done

cat > "$work/$pkg/README.txt" <<README
krikri ${tag} - macOS multi-arch bundle

Run the controller in the directory matching THIS Mac's CPU
(uname -m): darwin-aarch64/krikri-playbook (Apple silicon) or
darwin-x86_64/krikri-playbook (Intel). It can manage Linux targets of
both architectures (plugins-linux-x86_64/, plugins-linux-aarch64/) and
Mac targets of either CPU. Keep the whole directory tree intact.

The macOS binaries need Homebrew's openssl@3, pcre2, bdw-gc, gmp,
libyaml and xz (the plugin binaries link xz's liblzma).
README

tar -C "$work" -czf "$out/${pkg}.tar.gz" "$pkg"
ls -lh "$out/${pkg}.tar.gz"
