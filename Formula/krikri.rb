class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1661"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1661/krikri-v0.9.1661-darwin-arm64.tar.gz"
      sha256 "e4aa0899355014ba784a5dd9ac9496f800d4b4c4093308f79c239c09cdf853cb"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1661/krikri-v0.9.1661-darwin-x86_64.tar.gz"
      sha256 "3485141abacbfe3972fb8c635908e3c3ded120e608de50f2f43d529bb2e44aa0"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1661/krikri-v0.9.1661-linux-arm64.tar.gz"
      sha256 "39a68c6524f53b347dcdee97f3327775c0f146e730ba1c05aa30f16262ce7874"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1661/krikri-v0.9.1661-linux-x86_64.tar.gz"
      sha256 "bb19c4b889afec4e410407c7c11a64e96c61e419bd2fa48346aca56fe279b60f"
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
