class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2691"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2691/krikri-v0.9.2691-darwin-arm64.tar.gz"
      sha256 "e5a0d0c43ba34ea8437a452ab4a7256d09f5ea5666004e788ee110aeb95f4e04"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2691/krikri-v0.9.2691-darwin-x86_64.tar.gz"
      sha256 "5dc8e071db628e2a91ed30a7798ff1330e7a5ffff83ebe71a3af0a2214ca2885"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2691/krikri-v0.9.2691-linux-arm64.tar.gz"
      sha256 "9d8e2c469ba631fadfd6cd837b96c802d6e3eed0e70825f28430027a24cd07bb"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2691/krikri-v0.9.2691-linux-x86_64.tar.gz"
      sha256 "16b9ca618e5a1939c55bbf9bca87fd119dcb049703a3fc54d34ac72af517e523"
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
