class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2292"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2292/krikri-v0.9.2292-darwin-arm64.tar.gz"
      sha256 "70215fc72432caef5fec9daf71e45a832c1695466e5b2d124c5e446845e4f8bc"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2292/krikri-v0.9.2292-darwin-x86_64.tar.gz"
      sha256 "2a981463462dcd061a7f1dc16bcbbe6efbb977b3cdb247ab52d5d01191072cc2"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2292/krikri-v0.9.2292-linux-arm64.tar.gz"
      sha256 "c87d8630b46fc46e947b262c1819f87cfe99827c15eed206574a423e176955c2"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2292/krikri-v0.9.2292-linux-x86_64.tar.gz"
      sha256 "b1b77987cc8c17577c78acdf45587a8215c8ddb0db1c8a6ffc62e7f2f55d8aa4"
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
