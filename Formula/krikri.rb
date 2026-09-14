class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1066"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1066/krikri-v0.9.1066-darwin-arm64.tar.gz"
      sha256 "77e69a537073847039e25da323753d714c83f54188545c688f9ba8abcc843a5a"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1066/krikri-v0.9.1066-darwin-x86_64.tar.gz"
      sha256 "f1388a9d122d745b9c33021fa0e64370063c1147cbd1c4d530eeabd918a83f39"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1066/krikri-v0.9.1066-linux-arm64.tar.gz"
      sha256 "80ef6c70137972fe2b43a3722aaac0fe45b0419d50d2e91a76039f48af3aa30b"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1066/krikri-v0.9.1066-linux-x86_64.tar.gz"
      sha256 "376aed0b0c63ff2df1f6016abe10d260ebb1cb3ae0e8004e44dea9a037369171"
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
