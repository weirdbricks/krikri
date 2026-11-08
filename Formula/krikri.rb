class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2522"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2522/krikri-v0.9.2522-darwin-arm64.tar.gz"
      sha256 "bc61b12bd3c73f35b52b9eb449e3b775665c9f5e50f2a75ce412b984ac062b4c"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2522/krikri-v0.9.2522-darwin-x86_64.tar.gz"
      sha256 "e636c7f2671cd84cd3c252b811a7dbc413a938f2c5a99dea9ce5c977d2470525"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2522/krikri-v0.9.2522-linux-arm64.tar.gz"
      sha256 "fa31eadbf04a25727527732f996f26ba7df9d8c6968af79cdd3d334be6b65a21"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2522/krikri-v0.9.2522-linux-x86_64.tar.gz"
      sha256 "246e06252d4d885deac4d4d0eb0a679ea080ff6f09d4946a1fef0bb7ee55ef23"
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
