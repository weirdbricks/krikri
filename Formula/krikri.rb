class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.3074"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3074/krikri-v0.9.3074-darwin-arm64.tar.gz"
      sha256 "66f3ea332d36ec893d1cde29be6e9250f679a17f7ff556f853fbbcc2f63a28b4"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3074/krikri-v0.9.3074-darwin-x86_64.tar.gz"
      sha256 "efbcc8edd5ad561d76fa0b9d42e85fdf6dbc6ade378c89db12d1bb4801d3a594"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3074/krikri-v0.9.3074-linux-arm64.tar.gz"
      sha256 "86142c590655429ec62293045f34d62cd2d56b9d01710570e412ff8b106e4f88"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3074/krikri-v0.9.3074-linux-x86_64.tar.gz"
      sha256 "f4cd56c567aac7dba90aa2b1a303cc78c45bb2b24066bc9038b8490e9f684977"
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
