class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.880"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.880/krikri-v0.9.880-darwin-arm64.tar.gz"
      sha256 "0ad66abb86e4fa38442c2f44afc22e882c15558b99ddb33d9357df3ff12a82c9"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.880/krikri-v0.9.880-darwin-x86_64.tar.gz"
      sha256 "ad19c66cb026120ee9ab1f83008de797567090afbc8476cc25ff18802f7dd57b"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.880/krikri-v0.9.880-linux-arm64.tar.gz"
      sha256 "05d90ade94885abecc4f83edf0fd0a59aa7b0b9e29bd45fe3f4ed6f3a30af061"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.880/krikri-v0.9.880-linux-x86_64.tar.gz"
      sha256 "d3d50bb9c31f99f092506e7b562df411edcd8c1a779e5187977f1d9337a5a777"
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
