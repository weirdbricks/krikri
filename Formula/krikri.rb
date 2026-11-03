class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2285"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2285/krikri-v0.9.2285-darwin-arm64.tar.gz"
      sha256 "479a31cb3013931ad3df6a61e91fee47bd8e2af8c2ea837056d212e62a62cc01"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2285/krikri-v0.9.2285-darwin-x86_64.tar.gz"
      sha256 "cb535a832b0438a9881ad5991ee7f5006de7e3e35465d1e9ca13678fd8b51b58"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2285/krikri-v0.9.2285-linux-arm64.tar.gz"
      sha256 "fa2a534d4c0d85e64ec4280978c369af33965b3e69b4987084f5e0476a661b99"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2285/krikri-v0.9.2285-linux-x86_64.tar.gz"
      sha256 "f6732d673ba22c2ced4b890c0aa7c12a215f43dd2eb265c14e0ede12db7983f6"
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
