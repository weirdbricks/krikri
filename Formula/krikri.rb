class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1151"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1151/krikri-v0.9.1151-darwin-arm64.tar.gz"
      sha256 "53a70476072d7d19aff61744a78784084a325c1572ab26803bb2c31e8bb0dd05"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1151/krikri-v0.9.1151-darwin-x86_64.tar.gz"
      sha256 "87bede4f50c95a0c4b98b37f3716dfa0611a16f100d7921f42659b3f79c0e24c"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1151/krikri-v0.9.1151-linux-arm64.tar.gz"
      sha256 "f61d05deb638c95b37ab66db7b45534985410e22d2db588c026c3a832198093f"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1151/krikri-v0.9.1151-linux-x86_64.tar.gz"
      sha256 "7d960eec52def233d6e661d2458b095da62ac1750a215a3ea361329497c35b2f"
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
