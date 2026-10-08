class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.1548"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1548/krikri-v0.9.1548-darwin-arm64.tar.gz"
      sha256 "9c3e3adc890edf418852b64d750739336d014425d3ee0dc40744640b543b166a"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1548/krikri-v0.9.1548-darwin-x86_64.tar.gz"
      sha256 "7137ab361f1eed57057ee00da61c0a9fed86774eb2fb2cd3bb02775b501e8748"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1548/krikri-v0.9.1548-linux-arm64.tar.gz"
      sha256 "7004a9f8ab95c1c236aa0d8b15f5bc06ad76d5bd8943030462a5e1334888e4d7"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.1548/krikri-v0.9.1548-linux-x86_64.tar.gz"
      sha256 "d4e7a37a3c04ba62bf3db7845be8a2819a00e40c06d1954b2beb3f1d165cbbe4"
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
