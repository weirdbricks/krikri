class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2599"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2599/krikri-v0.9.2599-darwin-arm64.tar.gz"
      sha256 "9196f235ede905dcf436d8b313c4afe8cab7da8881c189a914f561b30dd6e21a"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2599/krikri-v0.9.2599-darwin-x86_64.tar.gz"
      sha256 "e2ff76193bba1743f72258ded695157c16fbd3b558d1459c369e1a2030109756"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2599/krikri-v0.9.2599-linux-arm64.tar.gz"
      sha256 "199bf748d414a9b9111d0ecfeac8affb34a9cf22740e437b3d931b5bf5fb53a3"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2599/krikri-v0.9.2599-linux-x86_64.tar.gz"
      sha256 "8dd2d62a67aec22962c85173725f6daa40bc59f0d7a5bb418feac93f2f68e531"
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
