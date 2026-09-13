class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1020"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1020/krikri-v0.9.1020-darwin-arm64.tar.gz"
      sha256 "33c82e61e00c008ee1df6af9ce2dd77d87dbb27ee93d1999b4e1a144126af829"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1020/krikri-v0.9.1020-darwin-x86_64.tar.gz"
      sha256 "61e6bf41943f89645b294666f5322cacff2d4f579ee922978da08657589e6d20"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1020/krikri-v0.9.1020-linux-arm64.tar.gz"
      sha256 "5ca12eb0052040006dcd82a3dc8daa0bca08dcbf1dcf82371bc0943b1302ca6a"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1020/krikri-v0.9.1020-linux-x86_64.tar.gz"
      sha256 "ee82c026631c587f25433f2e6b6dbb587512b42b7bd70a6fafd9331d6e20760d"
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
