class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2590"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2590/krikri-v0.9.2590-darwin-arm64.tar.gz"
      sha256 "293099cbcc6d2190ecdc740dc735429e1b8089fd54dfeb2b1dedea8c8b48a013"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2590/krikri-v0.9.2590-darwin-x86_64.tar.gz"
      sha256 "7daa3db3fd761317252c077ef57365efc298253b55e2c3ade5b8b37524234b9f"
    end

    # Unlike the Linux binaries (fully static musl builds, zero runtime
    # deps), the macOS binaries are dynamically linked against these at
    # their Homebrew-installed paths (confirmed via the release build's
    # own link command: -lgc/-lpcre2-8 resolve to
    # /opt/homebrew/opt/{bdw-gc,pcre2}, -lssl/-lcrypto to openssl@3) -
    # without them declared here, a fresh `brew install` never pulls
    # them in and krikri-playbook fails at dyld load time (confirmed
    # live: "Library not loaded: .../bdw-gc/lib/libgc.1.dylib").
    # gmp/libyaml are linked by the main binaries and xz's liblzma by
    # the plugin binaries; libz/libbz2/liblzma-the-lib/libiconv/
    # libutil are all system-provided on macOS, no formula needed
    # for those.
    depends_on "openssl@3"
    depends_on "pcre2"
    depends_on "bdw-gc"
    depends_on "gmp"
    depends_on "libyaml"
    depends_on "xz"
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2590/krikri-v0.9.2590-linux-arm64.tar.gz"
      sha256 "7e4cab12dda6a90ea59cca9116b756d13b2a8afccf4c8bb30cfbd63bb0b1f310"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2590/krikri-v0.9.2590-linux-x86_64.tar.gz"
      sha256 "499e186fc3d941238030bb1a7e2f9611dda8e64497b03af9ef49da9e987910b3"
    end
  end

  # Each Ansible module is its own small binary, dispatched from
  # src/krikri/plugin_manager.cr#get_local_plugin_path by resolving a
  # "plugins" directory next to krikri-playbook's own (symlink-resolved)
  # executable path - so plugins/ must land in the same Cellar bin/ dir
  # as the three top-level binaries, not the usual libexec/share split.
  def install
    bin.install "krikri-playbook"
    bin.install "krikri"
    bin.install "krikri-lint"
    bin.install "plugins"
  end

  test do
    assert_match "krikri #{version}", shell_output("#{bin}/krikri-playbook --version")
  end
end
