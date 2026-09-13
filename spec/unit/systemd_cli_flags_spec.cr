require "../spec_helper"
require "../../src/krikri/plugin_helpers/systemd_cli_flags"

# Pure decision logic for the systemd plugin's force:/no_block: flags -
# what the plugin actually appends to its systemctl invocations, without a
# real systemctl or the plugin's STDIN entry point.
describe "SystemdCliFlags" do
  describe ".force_flag" do
    it "appends --force for each of real Ansible's truthy spellings" do
      ["true", "yes", "1", "on", "y", "t", "True", "YES"].each do |value|
        Krikri::SystemdCliFlags.force_flag(value).should eq(" --force")
      end
    end

    it "appends nothing when unset, empty, or falsy" do
      [nil, "", "false", "no", "0", "off", "n", "f", "sometimes"].each do |value|
        Krikri::SystemdCliFlags.force_flag(value).should eq("")
      end
    end
  end

  describe ".no_block_flag" do
    it "appends --no-block for each of real Ansible's truthy spellings" do
      ["true", "yes", "1", "on", "y", "t", "True", "YES"].each do |value|
        Krikri::SystemdCliFlags.no_block_flag(value).should eq(" --no-block")
      end
    end

    it "appends nothing when unset, empty, or falsy (real default: false)" do
      [nil, "", "false", "no", "0", "off", "n", "f", "sometimes"].each do |value|
        Krikri::SystemdCliFlags.no_block_flag(value).should eq("")
      end
    end
  end
end
