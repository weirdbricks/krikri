class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.739"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.739/krikri-v0.9.739-darwin-arm64.tar.gz"
      sha256 "326ea9c7cac2c0fa8b1642296945c15aa80f07982390991db1924139ee52ff3e"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.739/krikri-v0.9.739-darwin-x86_64.tar.gz"
      sha256 "d34f95d14d0ada6919b62cc1e3160a37b76d324670c478ff6d9510de49ca7f3d"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.739/krikri-v0.9.739-linux-arm64.tar.gz"
      sha256 "33c3274febf1c800dc76a359836cf2f4112904205d26877fb007715163c24e3c"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.739/krikri-v0.9.739-linux-x86_64.tar.gz"
      sha256 "4f5e805249e6e7aac28fe617326a39ff81eb987ea5b49d681dc5d82aba302ec0"
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
