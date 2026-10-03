class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1456"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1456/krikri-v0.9.1456-darwin-arm64.tar.gz"
      sha256 "0b07f280e13da47f6e61930037e37b84219b7f0cd61eb4f45426bffdd70fc626"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1456/krikri-v0.9.1456-darwin-x86_64.tar.gz"
      sha256 "1272b1b5397f9ab606f81a62cb893006cfb8f07bbd7883dd958d0f8a5831e579"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1456/krikri-v0.9.1456-linux-arm64.tar.gz"
      sha256 "c0c0a87e69d4b943e0c30ee0fe5cc474a384234f5c79cd6765d2197891d6549a"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1456/krikri-v0.9.1456-linux-x86_64.tar.gz"
      sha256 "37394a4c63bf01f91c21674fe0d8cc40a6ec5f6e10a1dca0746c4366b54fcf8e"
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
