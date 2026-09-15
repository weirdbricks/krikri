class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1085"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1085/krikri-v0.9.1085-darwin-arm64.tar.gz"
      sha256 "6e8f1da993ce953388c9f9aecaf8b0a3d06f760dbcd412f264b4f092b93a93a6"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1085/krikri-v0.9.1085-darwin-x86_64.tar.gz"
      sha256 "ee658f84f3f883ee3bfdb56331c302076d1ddfdfbda874a6ab9a44c47e588e40"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1085/krikri-v0.9.1085-linux-arm64.tar.gz"
      sha256 "0d114f35cb8810ed7e5e39508bda73e1860f12b215ffba36d3c84100101c5cd2"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1085/krikri-v0.9.1085-linux-x86_64.tar.gz"
      sha256 "818480f8decdb7af086ae80017fa16b70228b34cfb4bc6d9dc535d0b964e40f6"
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
