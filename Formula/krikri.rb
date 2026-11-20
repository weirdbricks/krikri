class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.3006"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3006/krikri-v0.9.3006-darwin-arm64.tar.gz"
      sha256 "472ac99c5c2354004c6ea51dc95d3fa2b3d64c4bcc3f3a56e05909869c7a764b"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3006/krikri-v0.9.3006-darwin-x86_64.tar.gz"
      sha256 "8f7965d3e567c470ca2c25fef7c57310eb7ea8cadde0801df47f536132bfe588"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3006/krikri-v0.9.3006-linux-arm64.tar.gz"
      sha256 "39d05a38577c47f98ac3f72eead9b3fc08a057188f46c558731d79ca467b7696"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3006/krikri-v0.9.3006-linux-x86_64.tar.gz"
      sha256 "3f734d2522e7a3d0124fe41c4f60ad9213203d2e6decf6f2cb8b2c0ef1daf8d6"
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
