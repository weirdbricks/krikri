class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1516"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1516/krikri-v0.9.1516-darwin-arm64.tar.gz"
      sha256 "2a9a0775245256f0038d49f7e5bf0d4f13be6c7206f02e21ff8b1cf23dab8c58"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1516/krikri-v0.9.1516-darwin-x86_64.tar.gz"
      sha256 "00fceaef06da3a0f84ce766a9afd9c3d101749399e3c639cbc2935f7ef369a45"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1516/krikri-v0.9.1516-linux-arm64.tar.gz"
      sha256 "f622df240ffc1d7f343f5198e2ea2330777fe315361bc945b92d59e85b98cc7e"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1516/krikri-v0.9.1516-linux-x86_64.tar.gz"
      sha256 "f172740ab7b759d59ebaff1cf907260072238f53a2300736c29651f7e885e9fb"
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
