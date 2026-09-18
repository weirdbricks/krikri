class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1154"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1154/krikri-v0.9.1154-darwin-arm64.tar.gz"
      sha256 "43efc5b40c2e6a60d1393a12e589d5362837bd2aa93a86921bd2fd17c4b7ed53"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1154/krikri-v0.9.1154-darwin-x86_64.tar.gz"
      sha256 "0d6424d5930025a5fd2658d2c06bff81e1df460e4a6d683c252cc8476fb3ab84"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1154/krikri-v0.9.1154-linux-arm64.tar.gz"
      sha256 "2cd572b2390e207cb9591ef1b8ef53132bd149b48521934d26d9e39a17f5752f"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1154/krikri-v0.9.1154-linux-x86_64.tar.gz"
      sha256 "174a8aac251e5d92fae5d0dfd8e57d3182dce9134b3df59df77579b6e3f2b729"
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
