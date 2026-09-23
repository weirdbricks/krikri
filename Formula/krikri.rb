class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1270"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1270/krikri-v0.9.1270-darwin-arm64.tar.gz"
      sha256 "da315a826f5768996366f5e18cbfe529d486f57f351a5fa83b96b9e757291296"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1270/krikri-v0.9.1270-darwin-x86_64.tar.gz"
      sha256 "b62186fbe8c279f79ab68d65480da206c41d95d281aff9f8eaabcb908c13c9e6"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1270/krikri-v0.9.1270-linux-arm64.tar.gz"
      sha256 "b6e6c991fbaea000e8be5ef81da65825cbf5c8cfecb691c96099627b4ac9870d"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1270/krikri-v0.9.1270-linux-x86_64.tar.gz"
      sha256 "24b5c95b0823b46d4d9bf37ad3d7561de5fbd40c170f570d0e4f7a445dd474c7"
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
