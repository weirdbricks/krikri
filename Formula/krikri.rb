class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1641"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1641/krikri-v0.9.1641-darwin-arm64.tar.gz"
      sha256 "12baa2b99c54886553f574202f84b6a27dcf36cbfd55ca2a9f90747601cadc72"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1641/krikri-v0.9.1641-darwin-x86_64.tar.gz"
      sha256 "d72f112bdd82fbe4132a367711fc1c3305195910d9990c98cf1ef9668a5e6ae6"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1641/krikri-v0.9.1641-linux-arm64.tar.gz"
      sha256 "80ff989db5d96ef8d6c9ee70c9ab8ae05ae3a3de9424c9a8e4402c18288e4f34"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1641/krikri-v0.9.1641-linux-x86_64.tar.gz"
      sha256 "56947190c59be3d533b6df7997f9d95ea10e9ed79781c7b0a6cdf6ac7d74181d"
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
