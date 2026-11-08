class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2488"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2488/krikri-v0.9.2488-darwin-arm64.tar.gz"
      sha256 "6fa109cdf49349eff6e60cb7ec78c4f122089ab2df0ba364e0466aea776f0efd"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2488/krikri-v0.9.2488-darwin-x86_64.tar.gz"
      sha256 "94f754889f6b422bf173b098116711d171c7732d129066427ac8ce14b83896de"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2488/krikri-v0.9.2488-linux-arm64.tar.gz"
      sha256 "b2f5aa2a9bd2786878666c8a07ef9f30dc115866136de7c9711b58bc50f4c3b7"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2488/krikri-v0.9.2488-linux-x86_64.tar.gz"
      sha256 "621a1d4e7d7447dca4c8cfcf9bf7420428fd9f09ccadb5ae51560ce88a61fd72"
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
