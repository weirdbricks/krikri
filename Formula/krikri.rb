class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2946"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2946/krikri-v0.9.2946-darwin-arm64.tar.gz"
      sha256 "d7744a665b763467baa4b67e8058f0985ee87512387f8f6ee96fe305c0449a1b"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2946/krikri-v0.9.2946-darwin-x86_64.tar.gz"
      sha256 "906b9ec95f6875d9d43c2e062c93c1e8cdf40210963223edf0e7879d7543bd8c"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2946/krikri-v0.9.2946-linux-arm64.tar.gz"
      sha256 "9d3e8de38cd7f36f9d1113366752029bf9d928447493ebab942c3a250fac2dbf"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2946/krikri-v0.9.2946-linux-x86_64.tar.gz"
      sha256 "b93735d975a1b28a430466504ff28354b1ebbeba17963f065de96e53169e5909"
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
