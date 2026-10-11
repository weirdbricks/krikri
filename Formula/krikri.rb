class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1639"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1639/krikri-v0.9.1639-darwin-arm64.tar.gz"
      sha256 "4a2868c8148062d6ac6f6d9310f1d4c2ce48cd726bd3daeb3b6852bdbd0c5938"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1639/krikri-v0.9.1639-darwin-x86_64.tar.gz"
      sha256 "fe54042f9ffc8a542913b685ad6ea04f01a23c6246168120d7d91d8aa5393d73"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1639/krikri-v0.9.1639-linux-arm64.tar.gz"
      sha256 "4925d5101f9eb3160412f2bbbb6860365ad5d829edf84f5a6bd4dac06552e758"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1639/krikri-v0.9.1639-linux-x86_64.tar.gz"
      sha256 "4172713fd616baf7ee834efedba353a2172f6c73526276c88b6b95ffbbce8803"
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
