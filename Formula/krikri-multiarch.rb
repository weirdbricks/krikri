class KrikriMultiarch < Formula
  desc "Ansible-compatible automation tool (macOS controller bundle with Linux plugins)"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.2089"
  license "GPL-3.0-or-later"

  # The bundle is a macOS controller build plus Linux plugin sets; on a
  # Linux controller the default `krikri` formula already ships plugins
  # matching its own platform, so there is nothing extra to install here.
  depends_on :macos

  url "https://github.com/weirdbricks/krikri/releases/download/v0.9.2089/krikri-v0.9.2089-darwin-with-linux-multiarch.tar.gz"
  sha256 "62a0d0ebac382fdad1b85cd5c433738e539e82189abdbac1e5e032c0f0ce501a"

  # Same dynamically-linked macOS binaries as the default `krikri` formula.
  # The declared set must cover every Homebrew library the shipped Mach-O
  # binaries link at their /opt/homebrew (or /usr/local) paths - verified
  # against the release binaries' Mach-O load commands, the main binaries
  # additionally link gmp and libyaml, and the plugin binaries also link
  # xz's liblzma - without them declared, a fresh `brew install` on a
  # machine that has none of them never pulls them in and the binary dies
  # at dyld load time.
  depends_on "openssl@3"
  depends_on "pcre2"
  depends_on "bdw-gc"
  depends_on "gmp"
  depends_on "libyaml"
  depends_on "xz"

  # plugin_manager resolves the plugins directory next to the
  # symlink-resolved executable path (see Formula/krikri.rb), so every
  # plugin set the controller can dispatch must land in the same Cellar
  # bin/ dir as the binaries: its own Mach-O set, the other Mac CPU's set
  # (Mac targets of the other CPU, looked up as plugins-<arch>/), and both
  # Linux sets (Linux targets, looked up as plugins-<os>-<arch>/). All are
  # installed as real directories rather than recreating the bundle's
  # relative symlinks, whose ../ targets point at bundle-root paths that
  # do not exist inside the Cellar.
  def install
    arch = Hardware::CPU.arm? ? "darwin-aarch64" : "darwin-x86_64"
    other = Hardware::CPU.arm? ? "x86_64" : "aarch64"

    bin.install "#{arch}/krikri-playbook"
    bin.install "#{arch}/krikri"
    bin.install "#{arch}/plugins"
    bin.install "darwin-#{other}/plugins" => "plugins-#{other}"
    bin.install "plugins-linux-x86_64"
    bin.install "plugins-linux-aarch64"
  end

  test do
    assert_match "krikri #{version}", shell_output("#{bin}/krikri-playbook --version")
  end
end
