class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1770"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1770/krikri-v0.9.1770-darwin-arm64.tar.gz"
      sha256 "f952d1dc4de8929fa44e079ab7b87b75fd09a76212b3a9cbbb8605657fcc9e7b"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1770/krikri-v0.9.1770-darwin-x86_64.tar.gz"
      sha256 "d60c4c48c8a5a6a8cea77a7c3d3fd9bbaeccc3da8db989ca4f3301d61756e365"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1770/krikri-v0.9.1770-linux-arm64.tar.gz"
      sha256 "a20f11cf23ff3f44a05c6dee3fb02b7d19a06b73b71fc296c0f7d0c86bcdbfbd"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1770/krikri-v0.9.1770-linux-x86_64.tar.gz"
      sha256 "adf4fe7fe70cf1420251aa24f9d5d224e34a90e70ec91ab4817e20bc30fdc359"
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
