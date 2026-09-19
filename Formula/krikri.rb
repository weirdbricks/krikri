class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1189"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1189/krikri-v0.9.1189-darwin-arm64.tar.gz"
      sha256 "b26e2cba05d9dcb41dcb9a4ce019bdece30d85ddd39f5f03550b9224d7143117"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1189/krikri-v0.9.1189-darwin-x86_64.tar.gz"
      sha256 "b019da5986e804a23622b6666a06cf7dc4d7e9696174a42747eb5c4558d2f0af"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1189/krikri-v0.9.1189-linux-arm64.tar.gz"
      sha256 "9d57c741526fd977c0777632e9c5d4f635f8a56b50fa9a8c04f99016ea245a76"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1189/krikri-v0.9.1189-linux-x86_64.tar.gz"
      sha256 "afa3b257665f38186fffa5e82540720d3ccbb9fe9555aeaefc9b4cebab650b17"
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
