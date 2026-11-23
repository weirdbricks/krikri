class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.3054"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3054/krikri-v0.9.3054-darwin-arm64.tar.gz"
      sha256 "5c50746ae6f749701ebabc1621a6be57e9a7da7ef2edeb92f24bc2b005a648c9"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3054/krikri-v0.9.3054-darwin-x86_64.tar.gz"
      sha256 "6d8cc440f2dc25ea92e856f6e9395e12ad786edcc4aa6fc2c99e1623c06bd866"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3054/krikri-v0.9.3054-linux-arm64.tar.gz"
      sha256 "beddef0379b3e566895da109f0c3f59fb06f4b6f8e32966734783aa05482084d"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3054/krikri-v0.9.3054-linux-x86_64.tar.gz"
      sha256 "9ce82f87fcd34c67bd79703d91cff4277eb00e8a5555721312a3a4148eec2643"
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
