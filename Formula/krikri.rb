class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.3130"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3130/krikri-v0.9.3130-darwin-arm64.tar.gz"
      sha256 "bebcb0ebf535d2a8bc978c7258aceb2b34ef11ef9b2c5c9e6d4f2c01f222c8db"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3130/krikri-v0.9.3130-darwin-x86_64.tar.gz"
      sha256 "0679991fba0543a05f2566bbffc2859dcb5f8f0f79f6b9a18c4014060d9d9847"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3130/krikri-v0.9.3130-linux-arm64.tar.gz"
      sha256 "ca0f67a33cf4b1c24b3fabef8cf844b9f909f00c262e990607a693662b19a2ca"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3130/krikri-v0.9.3130-linux-x86_64.tar.gz"
      sha256 "fef3c3fc198d7349f03595cb95bcb1e1c21671b59c97e62bdbf0da0a4dcf853a"
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
