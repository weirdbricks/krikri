class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2931"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2931/krikri-v0.9.2931-darwin-arm64.tar.gz"
      sha256 "80af2859492031020d28ccacd3617a3e29755073fd2ffc227b7068d02ca94f26"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2931/krikri-v0.9.2931-darwin-x86_64.tar.gz"
      sha256 "9d9822be0584c4e7087005b87c0674e7df6ae10c9c1084acedcda2174b95422e"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2931/krikri-v0.9.2931-linux-arm64.tar.gz"
      sha256 "d1ab03cd62791ed4cd65ac1166a9fb70374782f551da0a3c23fccefdc173998c"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2931/krikri-v0.9.2931-linux-x86_64.tar.gz"
      sha256 "3726d1a768ad14483b705badbc4bdaf9ffd7972273035826f4d1fe6bc65e0b22"
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
