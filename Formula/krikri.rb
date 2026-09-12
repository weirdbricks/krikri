class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.977"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.977/krikri-v0.9.977-darwin-arm64.tar.gz"
      sha256 "9c38994ae458b48250350639c215724ffe647dabc69add9f223ee4b5c4f00371"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.977/krikri-v0.9.977-darwin-x86_64.tar.gz"
      sha256 "5563822ad644e32086887029383c5821d9f44b24844beb2778b1edcfa1ee86a9"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.977/krikri-v0.9.977-linux-arm64.tar.gz"
      sha256 "fd6bf351ed550d721bcad7d235b5a5b9252e122b64a1605675a1a6da1e8b2952"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.977/krikri-v0.9.977-linux-x86_64.tar.gz"
      sha256 "3841f7677ab41b4c478972d2a94c7382d1bb400799f8a53307448ea0104889ea"
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
