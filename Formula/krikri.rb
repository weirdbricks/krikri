class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.3014"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3014/krikri-v0.9.3014-darwin-arm64.tar.gz"
      sha256 "0ba700a50cc207df1a7be6fbffcc2071085b424a57e30b93f99267f30df86e2b"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3014/krikri-v0.9.3014-darwin-x86_64.tar.gz"
      sha256 "166aedbc63c360d98402153bd37b69264e569de33ec67e212a49f1fd8f368d29"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3014/krikri-v0.9.3014-linux-arm64.tar.gz"
      sha256 "fd3df0b2de225e9745cc5820b29f4d8a421ce597c92390b75e49fe446cc4a531"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3014/krikri-v0.9.3014-linux-x86_64.tar.gz"
      sha256 "adf55dee5e6088b859cbdc740cd942f2a81495b8db2b4b3ff5af39ca20da3fb2"
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
