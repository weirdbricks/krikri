class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1733"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1733/krikri-v0.9.1733-darwin-arm64.tar.gz"
      sha256 "3835f078c56dfe87a3f0aed53a4a5f96864ee56f7291f6464328f726fca1a785"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1733/krikri-v0.9.1733-darwin-x86_64.tar.gz"
      sha256 "428f7c0df46298d21a826c82d34e436437c06e89d35250299b8fb10c9e7b8e02"
    end

    # Unlike the Linux binaries (fully static musl builds, zero runtime
    # deps), the macOS binaries are dynamically linked against these at
    # their Homebrew-installed paths (confirmed via the release build's
    # own link command: -lgc/-lpcre2-8 resolve to
    # /opt/homebrew/opt/{bdw-gc,pcre2}, -lssl/-lcrypto to openssl@3) -
    # without them declared here, a fresh `brew install` never pulls
    # them in and krikri-playbook fails at dyld load time (confirmed
    # live: "Library not loaded: .../bdw-gc/lib/libgc.1.dylib"). libz/
    # libbz2/liblzma/libiconv/libutil are all system-provided on macOS,
    # no formula needed for those.
    depends_on "openssl@3"
    depends_on "pcre2"
    depends_on "bdw-gc"
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1733/krikri-v0.9.1733-linux-arm64.tar.gz"
      sha256 "e199b18b7a86ea2837ef7abdf1bbf717a9277ba469c7d7a3deaf82ef176b0739"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1733/krikri-v0.9.1733-linux-x86_64.tar.gz"
      sha256 "1128399bc0ddbc421fc4c93fff1172ce5fe343f8567f0317670a5aba49ba690a"
    end
  end

  # Each Ansible module is its own small binary, dispatched from
  # src/krikri/plugin_manager.cr#get_local_plugin_path by resolving a
  # "plugins" directory next to krikri-playbook's own (symlink-resolved)
  # executable path - so plugins/ must land in the same Cellar bin/ dir
  # as the two top-level binaries, not the usual libexec/share split.
  def install
    bin.install "krikri-playbook"
    bin.install "krikri"
    bin.install "plugins"
  end

  test do
    assert_match "krikri #{version}", shell_output("#{bin}/krikri-playbook --version")
  end
end
