class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.3085"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3085/krikri-v0.9.3085-darwin-arm64.tar.gz"
      sha256 "057ea6d29742b1cce6cc8a9ae17cd0cdab3cee7a6de574ddf658df4bc8f78fe5"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3085/krikri-v0.9.3085-darwin-x86_64.tar.gz"
      sha256 "0b66c19b8d8f76a7b786c9b993dd08b7f99e09fd7e7389fbaecf13ba2b8ece7c"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3085/krikri-v0.9.3085-linux-arm64.tar.gz"
      sha256 "7cd6ca253eade8ddf4fff6ca5ffc44f099d2027c548eba92612535ddcbbb3b19"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3085/krikri-v0.9.3085-linux-x86_64.tar.gz"
      sha256 "75e67c45edcf231acd77737937dc4b53258568eec3d0bcfa4a72f0964d5952a1"
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
