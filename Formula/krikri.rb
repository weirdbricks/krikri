class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1702"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1702/krikri-v0.9.1702-darwin-arm64.tar.gz"
      sha256 "b04a6bb106e4cf91e79ae0d79ddb4711e24e2fb66437f83fe2d02e8e22cd7206"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1702/krikri-v0.9.1702-darwin-x86_64.tar.gz"
      sha256 "07ec4b932f4bef9de0f8fbcb0219508d6a2d24482f5bf6863524c35ff0a8b4c9"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1702/krikri-v0.9.1702-linux-arm64.tar.gz"
      sha256 "1bd8993271f55428749fc288bb5f5cf1d65f71c696edc551538c970b398e712d"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1702/krikri-v0.9.1702-linux-x86_64.tar.gz"
      sha256 "48be95205eec38b4d09fc8c5915a5f60bd1cf66d8910c1f71724c9cb90d022d4"
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
