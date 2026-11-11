class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2624"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2624/krikri-v0.9.2624-darwin-arm64.tar.gz"
      sha256 "e2784390ea5d7006c25c767dafbaf39c6e3dc103a0bddd9491210f91f6daeb1a"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2624/krikri-v0.9.2624-darwin-x86_64.tar.gz"
      sha256 "064e8ba7af5c88854c3bd1ae54743a311c3180516a195ce6ca0f1852e876b472"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2624/krikri-v0.9.2624-linux-arm64.tar.gz"
      sha256 "76f06beac2a5e31f599f245bd9c037badb5dc673aeb565dbd2af146b4ca9813e"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2624/krikri-v0.9.2624-linux-x86_64.tar.gz"
      sha256 "55cf5aa0c5c4cf055e463914c7be7a634d2e6f940ae43a5727062eaaee104500"
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
