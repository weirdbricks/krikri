class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.734"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.734/krikri-v0.9.734-darwin-arm64.tar.gz"
      sha256 "0ba70a3cb950aba48fd53f55069ad84474295cf37e6eb225546e7cb2dd9af896"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.734/krikri-v0.9.734-darwin-x86_64.tar.gz"
      sha256 "9bebcc4947bee61ab284fbdffaa5cc4357c126bb33ebe20838f18dccf7bee163"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.734/krikri-v0.9.734-linux-arm64.tar.gz"
      sha256 "aec57777bdaa5168df01df5d3e6e4e3bbcfd5f46d4aa8ec98f3aca8531f2db56"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.734/krikri-v0.9.734-linux-x86_64.tar.gz"
      sha256 "44e86c2dc5276d18f48d1334cf8298afefa4b7a8ce63328017c6ea65757a5ea2"
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
