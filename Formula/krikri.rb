class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2254"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2254/krikri-v0.9.2254-darwin-arm64.tar.gz"
      sha256 "243c29e1e17b4e3257ea877df810904d41a84386b5f56d270ef1d914abf35b7e"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2254/krikri-v0.9.2254-darwin-x86_64.tar.gz"
      sha256 "608fa82107d55a99fb4bcce862c33cc10323ca89131c47e02818c01b02bc9afc"
    end

    # Unlike the Linux binaries (fully static musl builds, zero runtime
    # deps), the macOS binaries are dynamically linked against these at
    # their Homebrew-installed paths (confirmed via the release build's
    # own link command: -lgc/-lpcre2-8 resolve to
    # /opt/homebrew/opt/{bdw-gc,pcre2}, -lssl/-lcrypto to openssl@3) -
    # without them declared here, a fresh `brew install` never pulls
    # them in and krikri-playbook fails at dyld load time (confirmed
    # live: "Library not loaded: .../bdw-gc/lib/libgc.1.dylib").
    # The declared set must cover every Homebrew library the shipped
    # Mach-O binaries link at their /opt/homebrew (or /usr/local) paths -
    # verified against the release binaries' Mach-O load commands, the
    # main binaries additionally link gmp and libyaml, and the plugin
    # binaries also link xz's liblzma - a fresh `brew install` on a
    # machine that has none of them never pulls them in and the binary
    # dies at dyld load time. libz/libbz2/liblzma-the-lib/libiconv/
    # libutil are all system-provided on macOS, no formula needed for
    # those.
    depends_on "openssl@3"
    depends_on "pcre2"
    depends_on "bdw-gc"
    depends_on "gmp"
    depends_on "libyaml"
    depends_on "xz"
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2254/krikri-v0.9.2254-linux-arm64.tar.gz"
      sha256 "e73f4f90916ce32e8ee0431e13eedd676ff71ac878216f9e305d25598a4c96f2"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2254/krikri-v0.9.2254-linux-x86_64.tar.gz"
      sha256 "0504f9d7d9a18bcd3f78b65d9e4325395771d013767678e47017803ffc17645d"
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
