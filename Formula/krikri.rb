class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1849"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1849/krikri-v0.9.1849-darwin-arm64.tar.gz"
      sha256 "5fe62bee4d5f7c0e4bbb0b5fb7b2015698d50cc8e17fb173d309786ffccf6ff8"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1849/krikri-v0.9.1849-darwin-x86_64.tar.gz"
      sha256 "6f0080678e98251892d86d2d62a89c6996a206a8fef787ebc17d6a56fb212d0c"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1849/krikri-v0.9.1849-linux-arm64.tar.gz"
      sha256 "06d0606dd82df82f41a4f2586444d2d27008bd4fcf86c04dcb49db0620879686"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1849/krikri-v0.9.1849-linux-x86_64.tar.gz"
      sha256 "ebadea9ed2ddd6b07661dcaa9d6e3e99566b8cafdcbc61b8a2296861c6cf1fe9"
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
