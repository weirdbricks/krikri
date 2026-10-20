class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1799"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1799/krikri-v0.9.1799-darwin-arm64.tar.gz"
      sha256 "e1e295880035ad632b2538872040695efea23393cb9712951f62d53955ff7554"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1799/krikri-v0.9.1799-darwin-x86_64.tar.gz"
      sha256 "ef148dc1cb4acbd49c66c475cef099cb3f6388984a542de369770d4956b08c37"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1799/krikri-v0.9.1799-linux-arm64.tar.gz"
      sha256 "ec8432773f2216f7c1fd6096ae5957b81d402604a3befc766b0d780122bb4a13"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1799/krikri-v0.9.1799-linux-x86_64.tar.gz"
      sha256 "f619a77f90e646e45ecdb51b7a6a74b4f879d97e084f3fda0ae01b9764572c13"
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
