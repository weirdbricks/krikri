class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2023"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2023/krikri-v0.9.2023-darwin-arm64.tar.gz"
      sha256 "1968eae550362784ce5b01ecc4f0a07a08818e2d0e6653a8cbbf124a9f9fdd3f"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2023/krikri-v0.9.2023-darwin-x86_64.tar.gz"
      sha256 "724f2412f2036bb06f756bb94a57d350c73cb230b969e3464c8f48bc49822e7e"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2023/krikri-v0.9.2023-linux-arm64.tar.gz"
      sha256 "0799662bad9b38b5968a5c5c703f0ec8e70582421fb34883f27f04001a0c371c"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2023/krikri-v0.9.2023-linux-x86_64.tar.gz"
      sha256 "fc194869aa782de9639a362e808359952abbb3a1e086b63c84752ba9b1e74953"
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
