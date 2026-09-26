class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1308"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1308/krikri-v0.9.1308-darwin-arm64.tar.gz"
      sha256 "7f2e8b1b43c665d1f4d54b640e44f7f8b9cbb7779033879cd547ad39e876c73f"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1308/krikri-v0.9.1308-darwin-x86_64.tar.gz"
      sha256 "b1f753f736dc0217f5fdc03a90c0395b1a88600ec1ccce8441e07b1e9315b722"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1308/krikri-v0.9.1308-linux-arm64.tar.gz"
      sha256 "57bc3bfc2433ad0a9c111ccfb4d9ec115dc7bb6bdadac8781558779d81c300c7"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1308/krikri-v0.9.1308-linux-x86_64.tar.gz"
      sha256 "ee1c7bf75d306a20bae8f8a5d6553f330f8b2590dd5450bf565ba6b11c0175ef"
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
