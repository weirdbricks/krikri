class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.738"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.738/krikri-v0.9.738-darwin-arm64.tar.gz"
      sha256 "1b903ba39e0263d0a618fa813f4e8bbee81e6d16eb1eaf1b9898e90c1b20e6a6"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.738/krikri-v0.9.738-darwin-x86_64.tar.gz"
      sha256 "a3ee657525721f6fbe6402d7a16251c6a35dcef988d5bd1a4061c520cf64a040"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.738/krikri-v0.9.738-linux-arm64.tar.gz"
      sha256 "5209e532b079fbc7c315f990dfa7da0bba82e08eb8c73e5f6ea55edd974e18e2"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.738/krikri-v0.9.738-linux-x86_64.tar.gz"
      sha256 "721d9665a2e26f9bb5d301ba6542386e52c9b79203b54730a54be84b319bea1b"
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
