class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2356"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2356/krikri-v0.9.2356-darwin-arm64.tar.gz"
      sha256 "4f18806839347b5d478ab4a96aaca781a713d9e024b9991485d1e4fb01935a38"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2356/krikri-v0.9.2356-darwin-x86_64.tar.gz"
      sha256 "4c91716b86b3403f422f474dc4ac7d316551b4fd46b37e33a0ba3dcdd8265a1d"
    end

    # Unlike the Linux binaries (fully static musl builds, zero runtime
    # deps), the macOS binaries are dynamically linked against these at
    # their Homebrew-installed paths (confirmed via the release build's
    # own link command: -lgc/-lpcre2-8 resolve to
    # /opt/homebrew/opt/{bdw-gc,pcre2}, -lssl/-lcrypto to openssl@3) -
    # without them declared here, a fresh `brew install` never pulls
    # them in and krikri-playbook fails at dyld load time (confirmed
    # live: "Library not loaded: .../bdw-gc/lib/libgc.1.dylib").
    # gmp/libyaml are linked by the main binaries and xz's liblzma by
    # the plugin binaries; libz/libbz2/liblzma-the-lib/libiconv/
    # libutil are all system-provided on macOS, no formula needed
    # for those.
    depends_on "openssl@3"
    depends_on "pcre2"
    depends_on "bdw-gc"
    depends_on "gmp"
    depends_on "libyaml"
    depends_on "xz"
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2356/krikri-v0.9.2356-linux-arm64.tar.gz"
      sha256 "46a6eb97f96a0a49206dbf6501b6e5852f9e50cd7953ae8a0320790c3f5d89f7"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2356/krikri-v0.9.2356-linux-x86_64.tar.gz"
      sha256 "ecb0c3f5780803eb325fa670c538b133add2f5c016249cfdfa2d69ddd23d01f2"
    end
  end

  # Each Ansible module is its own small binary, dispatched from
  # src/krikri/plugin_manager.cr#get_local_plugin_path by resolving a
  # "plugins" directory next to krikri-playbook's own (symlink-resolved)
  # executable path - so plugins/ must land in the same Cellar bin/ dir
  # as the three top-level binaries, not the usual libexec/share split.
  def install
    bin.install "krikri-playbook"
    bin.install "krikri"
    bin.install "krikri-lint"
    bin.install "plugins"
  end

  test do
    assert_match "krikri #{version}", shell_output("#{bin}/krikri-playbook --version")
  end
end
