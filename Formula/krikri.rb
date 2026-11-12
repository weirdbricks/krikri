class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2649"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2649/krikri-v0.9.2649-darwin-arm64.tar.gz"
      sha256 "08042be7ba6df55cee8d840997ba81a6307496741dda92b708527e8631b47f88"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2649/krikri-v0.9.2649-darwin-x86_64.tar.gz"
      sha256 "88f1668bcedfd844136a5ceaab8339841bc6e0d6ec21214b75e686aa848e8e53"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2649/krikri-v0.9.2649-linux-arm64.tar.gz"
      sha256 "9b39227e37d64a6f8c9e93fd4cd04149efaf399dc35ab535621639381e18cb80"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2649/krikri-v0.9.2649-linux-x86_64.tar.gz"
      sha256 "4e03768e7a5021c9c04872e019e39d861f3b8574468b38073eaa83c010de3173"
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
