require "../spec_helper"
require "../../src/krikri/cli_options"

# KNOWN_MISSING.md used to record --scp-extra-args as "accepted and
# stored, but nothing to attach to - this engine moves files over ssh
# plus a piped stream rather than shelling out to scp". That was wrong on
# its own facts: SSHManager#upload_file/#download_file ARE `scp`
# invocations, and PluginManager falls back to scp for the plugin-binary
# push whenever rsync is missing on the target.
#
# Verified live on a fresh Ubuntu 22.04 host with rsync moved aside to
# force that fallback: `--scp-extra-args="-o BogusOptionXYZ=1"` now fails
# the transfer with scp's own "command-line: line 0: Bad configuration
# option: bogusoptionxyz", where the previous build ignored it and
# completed ok=3; a valid `-l 8192` completes normally.
describe Krikri::CliOptions do
  after_each do
    Krikri::CliOptions.ssh_common_args = nil
    Krikri::CliOptions.ssh_extra_args = nil
    Krikri::CliOptions.scp_extra_args = nil
  end

  describe ".extra_scp_args" do
    it "is empty when no flag was given" do
      Krikri::CliOptions.extra_scp_args.should eq([] of String)
    end

    it "splits --scp-extra-args the way a shell would" do
      Krikri::CliOptions.scp_extra_args = "-o BogusOptionXYZ=1"
      Krikri::CliOptions.extra_scp_args.should eq(["-o", "BogusOptionXYZ=1"])
    end

    it "includes --ssh-common-args, which real Ansible applies to scp too" do
      Krikri::CliOptions.ssh_common_args = "-o StrictHostKeyChecking=no"
      Krikri::CliOptions.scp_extra_args = "-l 8192"
      Krikri::CliOptions.extra_scp_args.should eq(
        ["-o", "StrictHostKeyChecking=no", "-l", "8192"])
    end

    it "excludes --ssh-extra-args, which is ssh-only" do
      Krikri::CliOptions.ssh_extra_args = "-o ServerAliveInterval=5"
      Krikri::CliOptions.extra_scp_args.should eq([] of String)
    end
  end

  describe ".extra_ssh_args" do
    it "still carries both ssh flags, unchanged" do
      Krikri::CliOptions.ssh_common_args = "-o StrictHostKeyChecking=no"
      Krikri::CliOptions.ssh_extra_args = "-o ServerAliveInterval=5"
      Krikri::CliOptions.extra_ssh_args.should eq(
        ["-o", "StrictHostKeyChecking=no", "-o", "ServerAliveInterval=5"])
    end

    it "does not pick up --scp-extra-args" do
      Krikri::CliOptions.scp_extra_args = "-l 8192"
      Krikri::CliOptions.extra_ssh_args.should eq([] of String)
    end
  end
end
