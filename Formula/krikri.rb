class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2089"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2089/krikri-v0.9.2089-darwin-arm64.tar.gz"
      sha256 "b71466d7798d4a550ab358402241de0c9adb82168bd7d4c075ea43daafd938ad"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2089/krikri-v0.9.2089-darwin-x86_64.tar.gz"
      sha256 "9f25486a176a12592028b650c00476b5b3bc0585807d214f8047577bc6a5bc22"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2089/krikri-v0.9.2089-linux-arm64.tar.gz"
      sha256 "6f7e37f18fb6375adc2d917231c6e33743ff62b2dbfe5cbf70f6bba930d55e22"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2089/krikri-v0.9.2089-linux-x86_64.tar.gz"
      sha256 "f297cb54b1d6dbb315f89dc15d8ddecd52cf0c9fcf70cd800a7d632d238703f2"
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
