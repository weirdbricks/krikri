class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.3009"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3009/krikri-v0.9.3009-darwin-arm64.tar.gz"
      sha256 "6750ae044635158253f1eecb0cc6fcef523622bcabd9e12c9dcd343beb269858"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3009/krikri-v0.9.3009-darwin-x86_64.tar.gz"
      sha256 "733a78fb4112afd0f31ceea20823df357480ee0a308946c2db27bd46f9217fef"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3009/krikri-v0.9.3009-linux-arm64.tar.gz"
      sha256 "f8981067fd26c8342e02d477e76d3b70843ca8d14798105428f07d292d61ec01"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.3009/krikri-v0.9.3009-linux-x86_64.tar.gz"
      sha256 "30f23566770da026aaddec3c97f0911903d8d398656b9fa1f375281b41c4373f"
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
