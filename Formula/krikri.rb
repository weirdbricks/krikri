class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.921"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.921/krikri-v0.9.921-darwin-arm64.tar.gz"
      sha256 "7ab81f354f7aca3ad90824a415d1006668c2e47cd05f5bdbe8bf4261df3e683b"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.921/krikri-v0.9.921-darwin-x86_64.tar.gz"
      sha256 "231d31bc9944add3e5b820ca3e28013f570cbc0f2d206656221edd8baae7a288"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.921/krikri-v0.9.921-linux-arm64.tar.gz"
      sha256 "1a56013f56787f4c872eb2dff365b6b1dba3997126ffe3e50f0564a6fd37277a"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.921/krikri-v0.9.921-linux-x86_64.tar.gz"
      sha256 "9b7e76de950329d3a96847aca30746da2e1ef44ccf75e496af806e78a9cf2f3c"
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
