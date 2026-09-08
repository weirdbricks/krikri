class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.832"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.832/krikri-v0.9.832-darwin-arm64.tar.gz"
      sha256 "2ed921876d814c88f9b866643f0cd699b7bb7c6c21879b10e9c3c332bfc64c9b"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.832/krikri-v0.9.832-darwin-x86_64.tar.gz"
      sha256 "f22a3c1695bfa587c886d868421a70e3ab812ca2c31a0bd3a9ecdc7139420ba6"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.832/krikri-v0.9.832-linux-arm64.tar.gz"
      sha256 "9a6aa0a0b66f8517f09eb17e2991b46f1f4d39f12ad70739ea0835ad647b4313"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.832/krikri-v0.9.832-linux-x86_64.tar.gz"
      sha256 "54760433831363fd0b9a9ee2db1ce59e7215d68ad1cc6c151c6c075de013ba12"
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
