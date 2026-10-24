class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1913"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1913/krikri-v0.9.1913-darwin-arm64.tar.gz"
      sha256 "7c98d4ced407bb6dec95ad7f173efc5e0d22b08574e0f340910708bf573c180d"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1913/krikri-v0.9.1913-darwin-x86_64.tar.gz"
      sha256 "5f210594da6736e638b6d151410a8736ed164846feb2f5bba1e93cee5dda97b1"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1913/krikri-v0.9.1913-linux-arm64.tar.gz"
      sha256 "22ec61c030d30649558967e5366a11bd097b8d683353b041987567fd397a02b5"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1913/krikri-v0.9.1913-linux-x86_64.tar.gz"
      sha256 "f0f80d485a5b3c2a1b69c1c1f6dcb7e2eabe51962771fe09b52482d537e157b0"
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
