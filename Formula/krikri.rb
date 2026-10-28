class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2058"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2058/krikri-v0.9.2058-darwin-arm64.tar.gz"
      sha256 "036513198e0839398831435e7dd3a1b07f0510a0086b6ca641a426a5508de581"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2058/krikri-v0.9.2058-darwin-x86_64.tar.gz"
      sha256 "579a6c8ec0f419409a2617e42d8400211b0011cf02805ca82c6b4e890c92740b"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2058/krikri-v0.9.2058-linux-arm64.tar.gz"
      sha256 "8b19457dcf76d0b72b276a81cf41a8ff93fd633a2351735b09c9e28ef2a71a33"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2058/krikri-v0.9.2058-linux-x86_64.tar.gz"
      sha256 "e7a5c7ce4516da3e39bb0d8fb4774b24204e63387d1c3e5c97353943bf03b61e"
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
