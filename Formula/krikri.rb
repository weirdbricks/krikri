class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2568"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2568/krikri-v0.9.2568-darwin-arm64.tar.gz"
      sha256 "5224e65e97b0c114d9ca3af9a0e1a075ed08fe1fc8d4ec921320e67642065a11"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2568/krikri-v0.9.2568-darwin-x86_64.tar.gz"
      sha256 "0eff7ac9feeea1708c35fd2dc06ebb95b0f0f0726081887bf3954ec4c6d46121"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2568/krikri-v0.9.2568-linux-arm64.tar.gz"
      sha256 "efd0e47191991963a2cd99fc9d0eb7cce5e86318dd84768c7bf0eb5d9d4ca41b"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2568/krikri-v0.9.2568-linux-x86_64.tar.gz"
      sha256 "9873c65309d0c56dbacbaad2144a317fb03d0a2e1302f8afe9c60db0f50e99a0"
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
