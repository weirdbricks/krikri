class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2726"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2726/krikri-v0.9.2726-darwin-arm64.tar.gz"
      sha256 "8cc7790bec0052e38a4bc887c96c7bb7950fdb4753401a4ba01f9253ed764b19"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2726/krikri-v0.9.2726-darwin-x86_64.tar.gz"
      sha256 "553e7afc570d9a5016f270b398a4c55340e182585c0bae43f5a6425216e63bb0"
    end

    # Unlike the Linux binaries (fully static musl builds, zero runtime
    # deps), the macOS binaries are dynamically linked against these at
    # their Homebrew-installed paths (confirmed via the release build's
    # own link command: -lgc/-lpcre2-8 resolve to
    # /opt/homebrew/opt/{bdw-gc,pcre2}, -lssl/-lcrypto to openssl@3) -
    # without them declared here, a fresh `brew install` never pulls
    # them in and krikri-playbook fails at dyld load time (confirmed
    # live: "Library not loaded: .../bdw-gc/lib/libgc.1.dylib").
    # gmp/libyaml are linked by the main binaries and xz's liblzma by
    # the plugin binaries; libz/libbz2/liblzma-the-lib/libiconv/
    # libutil are all system-provided on macOS, no formula needed
    # for those.
    depends_on "openssl@3"
    depends_on "pcre2"
    depends_on "bdw-gc"
    depends_on "gmp"
    depends_on "libyaml"
    depends_on "xz"
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2726/krikri-v0.9.2726-linux-arm64.tar.gz"
      sha256 "23d2a1a7e1fac85f6db73548151b74570ad23c2bf2933571009f44b956159544"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2726/krikri-v0.9.2726-linux-x86_64.tar.gz"
      sha256 "188f0a721cde65cb64ad9332e989e30249b8eb6450f26ef42e1b32291facad06"
    end
  end

  # Each Ansible module is its own small binary, dispatched from
  # src/krikri/plugin_manager.cr#get_local_plugin_path by resolving a
  # "plugins" directory next to krikri-playbook's own (symlink-resolved)
  # executable path - so plugins/ must land in the same Cellar bin/ dir
  # as the three top-level binaries, not the usual libexec/share split.
  def install
    bin.install "krikri-playbook"
    bin.install "krikri"
    bin.install "krikri-lint"
    bin.install "plugins"
  end

  test do
    assert_match "krikri #{version}", shell_output("#{bin}/krikri-playbook --version")
  end
end
