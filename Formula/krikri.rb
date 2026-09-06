class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.774"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.774/krikri-v0.9.774-darwin-arm64.tar.gz"
      sha256 "4614a24403234694e54e1a3c435c3c1b380290659f192eee72adfefd8818d43b"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.774/krikri-v0.9.774-darwin-x86_64.tar.gz"
      sha256 "f6d913ff146040db9d284612d777241666cbb9d12209c86afb3c8e7a92f5dd63"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.774/krikri-v0.9.774-linux-arm64.tar.gz"
      sha256 "e27234acd0a007c335df6f6a0f0d2f36997e1d5c860f872aa92ac00e6d90ff63"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.774/krikri-v0.9.774-linux-x86_64.tar.gz"
      sha256 "4300da75213a0f883d5fcc63d70ab97a9f16cd1e0ffcd7a61f00df3c5ad3f0fe"
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
