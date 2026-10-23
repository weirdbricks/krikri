class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1880"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1880/krikri-v0.9.1880-darwin-arm64.tar.gz"
      sha256 "bc64171841bc01d92fe8e1b9e775c8bc15d7fe06a97055018ce2edb928aa37d6"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1880/krikri-v0.9.1880-darwin-x86_64.tar.gz"
      sha256 "3a02b15c655afeaac34dfdd5bab0cf1ea0da44ef96e94ec7ea932b579c089195"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1880/krikri-v0.9.1880-linux-arm64.tar.gz"
      sha256 "e28e994c19397d96fc1b57b39039537bfaebe757b0cba8cdcbcfc5eaadf54c19"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1880/krikri-v0.9.1880-linux-x86_64.tar.gz"
      sha256 "bf6d173f15e61697e5e3ef9825dec207d4e1a834ec2d9e9d3c806684d3c2c5f1"
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
