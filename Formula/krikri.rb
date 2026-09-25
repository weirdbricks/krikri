class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1283"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1283/krikri-v0.9.1283-darwin-arm64.tar.gz"
      sha256 "18fd2bd6264c8d7ed542e8ab1333d4245dfb354da53ae4aacc3ed4f4646bff7a"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1283/krikri-v0.9.1283-darwin-x86_64.tar.gz"
      sha256 "52a2780363b90eaac5fb670da69849e31914d4fe4820fe83a0fcf96f127f814c"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1283/krikri-v0.9.1283-linux-arm64.tar.gz"
      sha256 "269e2dddc1ec3e4149b51f1cced6bc90afecb93db15e3869dc09245330934e9f"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1283/krikri-v0.9.1283-linux-x86_64.tar.gz"
      sha256 "cb6c92384b8b14b34aa09add34f88afe7a7c664862106557d509b8b5be6389bf"
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
