class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.691"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.691/krikri-v0.9.691-darwin-arm64.tar.gz"
      sha256 "8b9785077a9c262028aa215dc286caa84518b612d1b98441facd04193b78530d"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.691/krikri-v0.9.691-darwin-x86_64.tar.gz"
      sha256 "fe542d4f49cfe63d9b1b7a6685d8e4e8a914537e1d9b58a9a97620b41e9bb189"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.691/krikri-v0.9.691-linux-arm64.tar.gz"
      sha256 "e9d3b517ef81ab6ad3ebe9866f4009bf0569dba149b741bb30fb20de3e768205"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.691/krikri-v0.9.691-linux-x86_64.tar.gz"
      sha256 "2e025996f8717123e5d199399da0aa98b60f6414838ccd153d393c48591f1b4d"
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
