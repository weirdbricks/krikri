class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1247"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1247/krikri-v0.9.1247-darwin-arm64.tar.gz"
      sha256 "9114c53271a86c3057798e37d171e835f2e4f5efaf077def737b063d9dc2a6d9"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1247/krikri-v0.9.1247-darwin-x86_64.tar.gz"
      sha256 "5df58816c814f10f48c2cf7382ecbcdb6f159986cba2d7a3747520b10d729b79"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1247/krikri-v0.9.1247-linux-arm64.tar.gz"
      sha256 "30cfff92ac0840b6765163145541d7d4c2e82d196ae1219ca8a0a3a5bd218838"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1247/krikri-v0.9.1247-linux-x86_64.tar.gz"
      sha256 "c6424ba3fd0d7a4e52ef95ce9ed59effb4f750ca45d5779315bcc2a53b3b9af3"
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
