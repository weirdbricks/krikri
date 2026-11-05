class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2391"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2391/krikri-v0.9.2391-darwin-arm64.tar.gz"
      sha256 "ad9b5977bf97aab1967cbff4bee5d03155d55e8286a734c93fb7863e1dcb9268"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2391/krikri-v0.9.2391-darwin-x86_64.tar.gz"
      sha256 "f7d477ef00b34cd8f8b0834dc5a847d9cfeec7de1704e5a1126ed9ff039c998e"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2391/krikri-v0.9.2391-linux-arm64.tar.gz"
      sha256 "cca4a761d4770c38338c3c072d133c0bb15be87dbba5b77cc208481513ca1e96"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2391/krikri-v0.9.2391-linux-x86_64.tar.gz"
      sha256 "7b8605b538595717b9ba96f6a831139d262ab6b5a16808f0a3460a8441afdb8d"
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
