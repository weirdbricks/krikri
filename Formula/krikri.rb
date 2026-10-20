class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1786"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1786/krikri-v0.9.1786-darwin-arm64.tar.gz"
      sha256 "a96e47bc9b49c5660f01d51903524d6ce63dfce857f37554e4cddd9b714525fb"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1786/krikri-v0.9.1786-darwin-x86_64.tar.gz"
      sha256 "2257b320199aed7549f5c3372f8f5418fa82261d54dece3cb7ae98f39ff615bc"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1786/krikri-v0.9.1786-linux-arm64.tar.gz"
      sha256 "06ae57d1dd16c9c5443967d2bc8fa42a04d9bbd922b5cd1af75bcf0e2c8773f5"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1786/krikri-v0.9.1786-linux-x86_64.tar.gz"
      sha256 "19094bd24bf349b70e5ec2f4e90ac74f6b857a0366fe7286ce2605ed5f8771fc"
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
