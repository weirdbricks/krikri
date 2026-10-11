class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1640"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1640/krikri-v0.9.1640-darwin-arm64.tar.gz"
      sha256 "40570250c7abcc9cb3bb53097b73f0d60b5dcbaff9404ecbfd31a2dfc8a1e161"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1640/krikri-v0.9.1640-darwin-x86_64.tar.gz"
      sha256 "236f035654cfcca411b7cec2504b64a079eabbd307ebc279f226dfb188e89deb"
    end

    # Unlike the Linux binaries (fully static musl builds, zero runtime
    # deps), the macOS binaries are dynamically linked against these at
    # their Homebrew-installed paths (confirmed via the release build's
    # own link command: -lgc/-lpcre2-8 resolve to
    # /opt/homebrew/opt/{bdw-gc,pcre2}, -lssl/-lcrypto to openssl@3) -
    # without them declared here, a fresh `brew install` never pulls
    # them in and krikri-playbook fails at dyld load time (confirmed
    # live: "Library not loaded: .../bdw-gc/lib/libgc.1.dylib"). libz/
    # libbz2/liblzma/libiconv/libutil are all system-provided on macOS,
    # no formula needed for those.
    depends_on "openssl@3"
    depends_on "pcre2"
    depends_on "bdw-gc"
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1640/krikri-v0.9.1640-linux-arm64.tar.gz"
      sha256 "e271c352d35932fbae7c83d4fa7a93489ee9b02b588f6aaf6f9d04477b8974f0"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1640/krikri-v0.9.1640-linux-x86_64.tar.gz"
      sha256 "3ea6b834235f4cebe5eb21821c827b2678304055f8464db4e1b1ee1a3dde6329"
    end
  end

  # Each Ansible module is its own small binary, dispatched from
  # src/krikri/plugin_manager.cr#get_local_plugin_path by resolving a
  # "plugins" directory next to krikri-playbook's own (symlink-resolved)
  # executable path - so plugins/ must land in the same Cellar bin/ dir
  # as the two top-level binaries, not the usual libexec/share split.
  def install
    bin.install "krikri-playbook"
    bin.install "krikri"
    bin.install "plugins"
  end

  test do
    assert_match "krikri #{version}", shell_output("#{bin}/krikri-playbook --version")
  end
end
