class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1397"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1397/krikri-v0.9.1397-darwin-arm64.tar.gz"
      sha256 "5249f7ab577b63d6021e8e7b7e6c528d3e8cb95c139d44bff6d16bac6ecc78b6"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1397/krikri-v0.9.1397-darwin-x86_64.tar.gz"
      sha256 "e697451e5f41c9a9e925cdf56571a3a0b33eefe7f6ff90aee58a63f11573d0f9"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1397/krikri-v0.9.1397-linux-arm64.tar.gz"
      sha256 "b4365dce9ffb5abfd3aea59adcb86a2541663eabd562023b1945e17073a17dfe"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1397/krikri-v0.9.1397-linux-x86_64.tar.gz"
      sha256 "9773b29fae51adfb5ef5fbcd823e4b0c3cdcfc4c3cdc2f8784625e76476211f9"
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
