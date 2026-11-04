class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2344"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2344/krikri-v0.9.2344-darwin-arm64.tar.gz"
      sha256 "b0a2a403d7680e5cb9e826b931e1dc3b5c27063f0f710951eb09727030654556"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2344/krikri-v0.9.2344-darwin-x86_64.tar.gz"
      sha256 "fb0cb53bba6a785f666f67bdf82d8795e30b008ac342048119f7b8a5c3445365"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2344/krikri-v0.9.2344-linux-arm64.tar.gz"
      sha256 "e10db7bafaf29ba1ea7f10d38c95aa0d6ea6f26c1686021755001666dd2827b1"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2344/krikri-v0.9.2344-linux-x86_64.tar.gz"
      sha256 "470a34e74c2e54e994ca3d247009db4d78a3b4bb8053378cd93db1d68c3329b3"
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
