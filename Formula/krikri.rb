class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2402"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2402/krikri-v0.9.2402-darwin-arm64.tar.gz"
      sha256 "90d98e6202abcea0fbfbf15d9009fe8d5f407e664fd6cd2d5f1227581e2a6e62"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2402/krikri-v0.9.2402-darwin-x86_64.tar.gz"
      sha256 "743c0b0d6b1c24b5a61cf6a6b04733aec604b1fba9283da30c8c58d0cc228a6e"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2402/krikri-v0.9.2402-linux-arm64.tar.gz"
      sha256 "53abddb31696b61ada39c6a4155adc58307bb49a98c73fe2c83b7254dc6fb5b4"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2402/krikri-v0.9.2402-linux-x86_64.tar.gz"
      sha256 "e70062471d3ba7e4995afe67a671d5f35143568a1608bd007ba6527c477bef94"
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
