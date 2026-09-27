class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1336"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1336/krikri-v0.9.1336-darwin-arm64.tar.gz"
      sha256 "0cee616ec138d989025eeec7bf1a43426b0aca0e4628815a190e64e985e6c2fa"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1336/krikri-v0.9.1336-darwin-x86_64.tar.gz"
      sha256 "c50d0367bed922436b0a37a36a0e68768d115c3c1a147b3028dcf30f05c93bbe"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1336/krikri-v0.9.1336-linux-arm64.tar.gz"
      sha256 "5776bafb0fee70f4b733441e77944bc1c58a2dbd2fc221d8315f8dd65bcb1a4c"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1336/krikri-v0.9.1336-linux-x86_64.tar.gz"
      sha256 "d792a7c3d4405796116f0f59b85248c09e973735649405a188971c5dcccde43c"
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
