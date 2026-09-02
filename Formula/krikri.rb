class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.690"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.690/krikri-v0.9.690-darwin-arm64.tar.gz"
      sha256 "a951fc1e7b1baac933ea79e9294045bbd8949800011b9da68ad68a9d84d46c63"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.690/krikri-v0.9.690-darwin-x86_64.tar.gz"
      sha256 "eda34af357636dd553067cb4910e7ff523e56700c75ffecfa6940f1ee8a03e9f"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.690/krikri-v0.9.690-linux-arm64.tar.gz"
      sha256 "37a0db42d7ae6ef04dcaba25dcc85a196a5e0d8626197f516726371e873bfe01"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.690/krikri-v0.9.690-linux-x86_64.tar.gz"
      sha256 "d11b7b6c04a94420200d0d9cdc3893f278357db330bd64fa06160c27442da8c8"
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
