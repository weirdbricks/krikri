class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1143"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1143/krikri-v0.9.1143-darwin-arm64.tar.gz"
      sha256 "96191afc26b15c317a8801f100d59b8789ebaeb9ca2d5bdde8be39f81948a220"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1143/krikri-v0.9.1143-darwin-x86_64.tar.gz"
      sha256 "e32a236e79a5c489825895ba0ae14f9ae318e0bdaf0f807484054f666ea5c1fb"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1143/krikri-v0.9.1143-linux-arm64.tar.gz"
      sha256 "10491371016f6aa47193591b77a1925616820d36cdd5c15961e0d547e5f9847c"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1143/krikri-v0.9.1143-linux-x86_64.tar.gz"
      sha256 "7fadcd06578b6b55256f03deafae0752530eb8118bc83e34163be1875851ee44"
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
