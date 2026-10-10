class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1610"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1610/krikri-v0.9.1610-darwin-arm64.tar.gz"
      sha256 "f90292ef9a45adad348cf938914434e7f70164ca4edaabca2db085b4a80a3a89"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1610/krikri-v0.9.1610-darwin-x86_64.tar.gz"
      sha256 "1a5b7f9d74ff0bb8b7052c4bc744d521b3be53764b83b9e268f4e2153150e6b1"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1610/krikri-v0.9.1610-linux-arm64.tar.gz"
      sha256 "1a50b84513766009f6bdfa7739fcb935acf1f146f1cdb442328c57382e54a93b"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1610/krikri-v0.9.1610-linux-x86_64.tar.gz"
      sha256 "09e5d4077c1da37159b9ccaabb1343bc40e43a59d40b3114324150f3301b16c2"
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
