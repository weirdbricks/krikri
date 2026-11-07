class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2479"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2479/krikri-v0.9.2479-darwin-arm64.tar.gz"
      sha256 "0b488ccd7e0e5e9ad6247808a3edbd3db76ef252ed822e135693b5d6e69e82e8"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2479/krikri-v0.9.2479-darwin-x86_64.tar.gz"
      sha256 "f0ab62a5dd105692208446daefab52d17b802f6a379606c92c353ba04c681dbd"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2479/krikri-v0.9.2479-linux-arm64.tar.gz"
      sha256 "eba14d6d8a6c2da9bbc71051ded1d96f4d6697d2b88b70f04916b022cb4a4efe"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2479/krikri-v0.9.2479-linux-x86_64.tar.gz"
      sha256 "8a55232b6c066cb0710585ac206c741b3e4593fa3707f45071fef9be99385f82"
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
