class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1781"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1781/krikri-v0.9.1781-darwin-arm64.tar.gz"
      sha256 "5720ab219334516cbef6cb23059f9faad9f3268a57e976a5d7420ce22b4577fd"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1781/krikri-v0.9.1781-darwin-x86_64.tar.gz"
      sha256 "9a869689daf4d84fadb18f94d149fcf5b765b5b8a79a14a6db74b341ef7128f6"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1781/krikri-v0.9.1781-linux-arm64.tar.gz"
      sha256 "00ba59652f55651929952cf0f4b1a08a4d050db1e85f9850fc6f56c95dd40fec"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1781/krikri-v0.9.1781-linux-x86_64.tar.gz"
      sha256 "e4894bbff8bce80a18db81837257249350ba0f0f5ebc43a106f680290b40aa30"
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
