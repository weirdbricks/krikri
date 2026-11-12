class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2654"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2654/krikri-v0.9.2654-darwin-arm64.tar.gz"
      sha256 "12bf04dd906df1007172c4d6b1471efae2d29b9b07d633e4304f73e5227ebf18"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2654/krikri-v0.9.2654-darwin-x86_64.tar.gz"
      sha256 "eaea957e9221ad6790cccd9072d2ccf68c2d53f3066ad10eaa2e1845c91cefda"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2654/krikri-v0.9.2654-linux-arm64.tar.gz"
      sha256 "070f48b6cc008aefb1574500eb4d9b21f6bf4ccf7aee638db64c1a571e0a4378"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2654/krikri-v0.9.2654-linux-x86_64.tar.gz"
      sha256 "3b0cb34f2405c83d48f412a7ff812fc54b253d418330d687dd771181bcdd2a4d"
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
