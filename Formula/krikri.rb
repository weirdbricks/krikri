class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.3181"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3181/krikri-v0.9.3181-darwin-arm64.tar.gz"
      sha256 "4fa4e9e9f0a9ee0fd6035732cb0e8c61ae5d64ff7983fa476717ad3fbebdf2d3"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3181/krikri-v0.9.3181-darwin-x86_64.tar.gz"
      sha256 "40eb5ef72f71ba2eab4fcc46dbed7db63858737e2c8fac3340c2bb782d497ef9"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3181/krikri-v0.9.3181-linux-arm64.tar.gz"
      sha256 "70431a875a1de9bde01d5085d0c0be643fe5512a0875934054e15bde30e3f03f"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3181/krikri-v0.9.3181-linux-x86_64.tar.gz"
      sha256 "abab12b5e9efc2d2a3ca4b39ed36c451ce976c434cb3b0e0911b964250cdbd8e"
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
