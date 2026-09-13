require "../spec_helper"
require "../../src/krikri/plugin_helpers/get_bin_path"

# Regression anchor for the 2026-09-13 ad-hoc CLI comparison sweep:
# modprobe (and ufw) reported false success on hosts missing their
# underlying binary - krikri's `modprobe: name=x state=absent` returned
# "already unloaded" success in a container with no modprobe binary at
# all, where real Ansible fails at module start with
# get_bin_path(required=True)'s exact message, before any state check.
#
# The message itself is shared by every plugin that resolves a required
# binary (currently modprobe and ufw), so it is pinned here once, in
# real Ansible's own wording.
describe Krikri::PluginHelpers::GetBinPath do
  describe ".missing_executable_error" do
    it "matches real Ansible's get_bin_path(required=True) failure, byte for byte" do
      # Live-captured from `ansible localhost -c local -m
      # community.general.modprobe -a "name=nonexistentmod123
      # state=absent"` in a container with no modprobe binary
      # (ansible-core 2.19.11).
      Krikri::PluginHelpers::GetBinPath.missing_executable_error(
        "modprobe",
        "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      ).should eq(
        "Failed to find required executable \"modprobe\" in paths: " \
        "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
      )
    end

    it "names whichever binary is missing" do
      Krikri::PluginHelpers::GetBinPath.missing_executable_error("grep", "/usr/bin:/bin")
        .should contain("\"grep\"")
    end
  end
end
