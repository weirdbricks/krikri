class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2057"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2057/krikri-v0.9.2057-darwin-arm64.tar.gz"
      sha256 "4f8cb29f42656139d739dbb8def73c37d359e4688d1c724acd9dc9d946d7e895"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2057/krikri-v0.9.2057-darwin-x86_64.tar.gz"
      sha256 "b2f69e88abd2d2d2620a5fff261acf69825006ddd061ec8e13a5ddf6ef277d7c"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2057/krikri-v0.9.2057-linux-arm64.tar.gz"
      sha256 "1a648c2dcae9fc9181ad53429cf69dafadfcb314049e6cd2981c82b72c949741"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2057/krikri-v0.9.2057-linux-x86_64.tar.gz"
      sha256 "f4fc640cc07c30ce2b754e8067ef4438e835e3a110b328a5e7479dae894078d7"
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
