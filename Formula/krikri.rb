class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2270"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2270/krikri-v0.9.2270-darwin-arm64.tar.gz"
      sha256 "08b9f8b5467a97673bb756cc693d357dbcaaac7f91b2152c3672e57372ab7f0e"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2270/krikri-v0.9.2270-darwin-x86_64.tar.gz"
      sha256 "1e5cecc52f1666cfb3e599982c7ac1c1f8d6c886371854fa1ce2326328e84305"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2270/krikri-v0.9.2270-linux-arm64.tar.gz"
      sha256 "d2d1d76d5cbcda9aa0dff4dd7ee8c0442c299ca6f59462aa641cb5060bf80260"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2270/krikri-v0.9.2270-linux-x86_64.tar.gz"
      sha256 "2e43d34cc103ccbfc921837a01445ee8b0add3bb83f0daf7a07a604ae79317bf"
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
