class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2558"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2558/krikri-v0.9.2558-darwin-arm64.tar.gz"
      sha256 "fbfe5eaac83224697b2f62f5f57ab87cfd88e3ebdf2afa93480f809560013e48"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2558/krikri-v0.9.2558-darwin-x86_64.tar.gz"
      sha256 "0be3be761eef1583bd77e6657c9f19544efa826ce416592be9a125717b6b93ed"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2558/krikri-v0.9.2558-linux-arm64.tar.gz"
      sha256 "b1a8c19955595ec648854032024ebbb6104c67a4c21d0a9bfc27749776b3615a"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2558/krikri-v0.9.2558-linux-x86_64.tar.gz"
      sha256 "c812d39bf6e4f64228a5a008a12a946cd6d8d0643779b821de2fc5f5f8acc6a4"
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
