class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2485"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2485/krikri-v0.9.2485-darwin-arm64.tar.gz"
      sha256 "c420bbde704c35e20c1858d48663d83de55395949fd1c2ada57e28563b6d5409"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2485/krikri-v0.9.2485-darwin-x86_64.tar.gz"
      sha256 "07a563363962658dbc6e5afde1eb3542cc0300d1488d9aed0b3028d9061389c2"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2485/krikri-v0.9.2485-linux-arm64.tar.gz"
      sha256 "97e4cafaea722a3e6782fff9ffc0e7e60dbef92170c46b9196af40625a2a85dc"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2485/krikri-v0.9.2485-linux-x86_64.tar.gz"
      sha256 "90f2819ebb612b4a8e3c4e29d6881514cffc00f08986ff206c88c02ad0762287"
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
