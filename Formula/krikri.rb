class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1000"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1000/krikri-v0.9.1000-darwin-arm64.tar.gz"
      sha256 "93dc2c54e7062baea348391c8919cd0458834026842010d40167d689a3102061"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1000/krikri-v0.9.1000-darwin-x86_64.tar.gz"
      sha256 "a9886e7879b6aa5fc5788e384ac8a5e0b9657a4a8ace81fed4445b78c89263c1"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1000/krikri-v0.9.1000-linux-arm64.tar.gz"
      sha256 "f9f0c4ff9d6891e9d45d89a79f22908498435b0e842deeea1d1f0a44cd5927a3"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1000/krikri-v0.9.1000-linux-x86_64.tar.gz"
      sha256 "70fe0f629182d135a9db634ebac9db34df0aea1edee798b20cd688d3fb1b15ff"
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
