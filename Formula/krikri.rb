class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.3073"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3073/krikri-v0.9.3073-darwin-arm64.tar.gz"
      sha256 "aa846c0c0895382f943d904a5cb813fb76f802d579d9795b6fdc2d2d53deb12a"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3073/krikri-v0.9.3073-darwin-x86_64.tar.gz"
      sha256 "bc8777daf5af520cfc237c201265087f8972cbba83a27211131a2d4ef438bcd2"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3073/krikri-v0.9.3073-linux-arm64.tar.gz"
      sha256 "60a75bc3c479487eaed2bbbfa0c4ffc8e113655abc6387129ac1420d046b0e3d"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3073/krikri-v0.9.3073-linux-x86_64.tar.gz"
      sha256 "ac8181e9b305b09eae7c3841699da9e21c31fd17c9cff9ac6b5369a3c971fa6c"
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
