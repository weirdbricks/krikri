class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1537"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1537/krikri-v0.9.1537-darwin-arm64.tar.gz"
      sha256 "f395426e711e66e4e55317df87d26f44f13ffd266213aee2ec669099c6edd23f"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1537/krikri-v0.9.1537-darwin-x86_64.tar.gz"
      sha256 "8bed2e2a11a09c97efb90f74d1875714cf0b16329ad2fcd3438dcb88bbb92667"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1537/krikri-v0.9.1537-linux-arm64.tar.gz"
      sha256 "fc42a597342258c11ddfe68758e71b12e91a25212bfab191f91220248777a488"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1537/krikri-v0.9.1537-linux-x86_64.tar.gz"
      sha256 "d6477de1d6968b9d8e8994fcbb508d237d26a22e7d050b859d3ead91345159d1"
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
