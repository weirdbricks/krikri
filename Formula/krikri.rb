class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1256"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1256/krikri-v0.9.1256-darwin-arm64.tar.gz"
      sha256 "b9d8d94233072f3a8e486487fecb5baa2be18d397ff59a73cb52070da96c50ec"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1256/krikri-v0.9.1256-darwin-x86_64.tar.gz"
      sha256 "68380f37c6ec7e1d7691dc59e8400291c78124a22a6510596c0e5a1da4a322d0"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1256/krikri-v0.9.1256-linux-arm64.tar.gz"
      sha256 "5965dc2f2ddc07dc45d3650e7fca82a959e667607399dbef8e762f08107a90f4"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1256/krikri-v0.9.1256-linux-x86_64.tar.gz"
      sha256 "156572e66869cc7a00992fc02ad6dcfe260f474c866200e82e4b821be9229a43"
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
