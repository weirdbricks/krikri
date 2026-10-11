class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1638"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1638/krikri-v0.9.1638-darwin-arm64.tar.gz"
      sha256 "0964bc7bbbf9d1b94f66028e2a39b29339328e97a28b0d5b5dc8ff07ca3e4eb8"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1638/krikri-v0.9.1638-darwin-x86_64.tar.gz"
      sha256 "93d300138371b9083de01de2b502293567eb5dabd3c736d3a79f4319b0a6e03f"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1638/krikri-v0.9.1638-linux-arm64.tar.gz"
      sha256 "2589c5e2cb01c7c359dc46567b53b0044610c6ac083e03b4e00e4c93b3dccfd2"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1638/krikri-v0.9.1638-linux-x86_64.tar.gz"
      sha256 "1ea88081694c1b8a2087501fe98fbeb814c0a24f9dd96bfc053276fa157e0a5e"
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
