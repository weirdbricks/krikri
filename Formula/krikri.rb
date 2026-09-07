class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.811"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.811/krikri-v0.9.811-darwin-arm64.tar.gz"
      sha256 "c268d6da993e3cd75f2dbb991dc6b4389a34f1bc9962b3a719d8d1423bfecc8a"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.811/krikri-v0.9.811-darwin-x86_64.tar.gz"
      sha256 "89606b9fcf0284409876f9faae91aa02dc5effe7c480285575e361b963a30b8a"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.811/krikri-v0.9.811-linux-arm64.tar.gz"
      sha256 "6af7a89f64c97fc90616945f7583f82362cb7390aff5b2142b1aad8d5e4fb7f4"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.811/krikri-v0.9.811-linux-x86_64.tar.gz"
      sha256 "bdc52e8dfcdc70d3c27755af1a587aa9e9ee2a16d2a19adbd5868cf8014cb9f9"
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
