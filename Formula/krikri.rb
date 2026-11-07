class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2484"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2484/krikri-v0.9.2484-darwin-arm64.tar.gz"
      sha256 "ca5e7756fa802fa6c8a4f01a0bf97dafa213746e84cd28fda9d4f9ec50c90d3f"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2484/krikri-v0.9.2484-darwin-x86_64.tar.gz"
      sha256 "23b65021e9069a6bc10c06083e51c1b8a854a26f4fef2351643fc3303c20b269"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2484/krikri-v0.9.2484-linux-arm64.tar.gz"
      sha256 "4ef9016f29123c8efe45dcc2fae54423ffc9d2f3f1953278527aa3a128902f96"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2484/krikri-v0.9.2484-linux-x86_64.tar.gz"
      sha256 "36814accd02f3fa9047deee6ed8ed613ac07f03c852e586bae75a7f9623b1767"
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
