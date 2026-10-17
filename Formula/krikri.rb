class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1783"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1783/krikri-v0.9.1783-darwin-arm64.tar.gz"
      sha256 "e994f9aabcc9c3a85d9f0e031272f6d3b56e32711a8b64cff7ba6820884eda61"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1783/krikri-v0.9.1783-darwin-x86_64.tar.gz"
      sha256 "28cbf15668f1f13dc9fe967cae0e9478ddd822c3a218e0168c937b1e39a040d2"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1783/krikri-v0.9.1783-linux-arm64.tar.gz"
      sha256 "d476ae73f6b21061134cb8944471bd000423136cddbf7e7c65a3b22ba8235ba8"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1783/krikri-v0.9.1783-linux-x86_64.tar.gz"
      sha256 "1c16e3f714cfa3ed8dab512faace7f659f6dd4900055bd6332e371c67f4e0539"
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
