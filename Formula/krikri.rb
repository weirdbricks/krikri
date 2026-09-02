class Krikri < Formula
  desc "Ansible-compatible automation tool, written in Crystal"
  homepage "https://github.com/weirdbricks/krikri"
  version "0.9.689"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.689/krikri-v0.9.689-darwin-arm64.tar.gz"
      sha256 "3727da28b39636948d82ea85e7f6c3917e2c4ab7e1b78455e774321b88d776d9"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.689/krikri-v0.9.689-darwin-x86_64.tar.gz"
      sha256 "a9dc310c943e1a25d5a7aa8b55aca68ecb95eafe5b11b4cf6b2c24305eaa6331"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.689/krikri-v0.9.689-linux-arm64.tar.gz"
      sha256 "a8c805fa474f178ada15c8292b1cf651fc3d5bee8e1c515da64f1b2586d74757"
    else
      url "https://github.com/weirdbricks/krikri/releases/download/v0.9.689/krikri-v0.9.689-linux-x86_64.tar.gz"
      sha256 "7a1743944f9b8bc278ed2b3a128b5d91abb5ab2d6ec18be064ba840db7c8a7fc"
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
