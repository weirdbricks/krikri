class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2847"
  license "GPL-3.0-or-later"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2847/krikri-v0.9.2847-darwin-arm64.tar.gz"
      sha256 "a19a1bb0a3ade4dbd58bdb23b3c03bcfe9772fbd44208b7bb2fe515974ad5cfe"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2847/krikri-v0.9.2847-darwin-x86_64.tar.gz"
      sha256 "f2960ddf6bf9e32455d8b60c974acf65eda073bdcc522aba440dbcebcd14b408"
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
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2847/krikri-v0.9.2847-linux-arm64.tar.gz"
      sha256 "500acdaa1a4ca86ad18bc6318a7da7716254961efd85f4f4f2d4655ba4348b25"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2847/krikri-v0.9.2847-linux-x86_64.tar.gz"
      sha256 "580cc2826665c57ec2b899d7b5816b8b3f64995352dbf773ff9dd4003a7239b8"
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
