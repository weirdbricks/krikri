class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1348"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1348/krikri-v0.9.1348-darwin-arm64.tar.gz"
      sha256 "e5bd100521c982da24315c87642023ee9f00e6a434dadc6543a18446ac31d357"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1348/krikri-v0.9.1348-darwin-x86_64.tar.gz"
      sha256 "a471f07cbf05f18efd015d04d4fc7685b1e66bc373cdde8d2c67a654475ee9b8"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1348/krikri-v0.9.1348-linux-arm64.tar.gz"
      sha256 "4d05059f0b0b600f234ef2e0938ecca3181f357fc4957e7ff65fa9c13d09e82f"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1348/krikri-v0.9.1348-linux-x86_64.tar.gz"
      sha256 "e1af3d78b5bf28198a53450dca7dd7ddf0a1f1ac8a40ff6a7a1b31c8a100840f"
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
