require "../spec_helper"
require "../../src/krikri/plugin_helpers/dpkg_divert_command"

# Unit-tests the dpkg-divert command lines against real
# community.general.dpkg_divert's own MAINCOMMAND construction (read
# from a live collection install) - the plugin's execution paths need a
# real dpkg database, the argv shapes don't.
describe Krikri::PluginHelpers::DpkgDivertCommand do
  describe ".main_command" do
    it "adds a local diversion to <path>.distrib by default" do
      options = Krikri::PluginHelpers::DpkgDivertCommand::Options.new(
        state: "present", holder: nil, divert: nil, rename: false, force: false
      )
      Krikri::PluginHelpers::DpkgDivertCommand.main_command(options, "/etc/foobarrc")
        .should eq("dpkg-divert --no-rename --local --divert /etc/foobarrc.distrib --add /etc/foobarrc")
    end

    it "uses --rename instead of --no-rename when rename is asked for" do
      options = Krikri::PluginHelpers::DpkgDivertCommand::Options.new(
        state: "present", holder: nil, divert: nil, rename: true, force: false
      )
      Krikri::PluginHelpers::DpkgDivertCommand.main_command(options, "/etc/foobarrc")
        .should eq("dpkg-divert --rename --local --divert /etc/foobarrc.distrib --add /etc/foobarrc")
    end

    it "passes the holder package through" do
      options = Krikri::PluginHelpers::DpkgDivertCommand::Options.new(
        state: "present", holder: "branding", divert: "/usr/bin/busybox.dpkg-divert", rename: true, force: false
      )
      Krikri::PluginHelpers::DpkgDivertCommand.main_command(options, "/usr/bin/busybox")
        .should eq("dpkg-divert --rename --package branding --divert /usr/bin/busybox.dpkg-divert --add /usr/bin/busybox")
    end

    it "treats an explicit LOCAL holder as --local" do
      options = Krikri::PluginHelpers::DpkgDivertCommand::Options.new(
        state: "present", holder: "LOCAL", divert: nil, rename: false, force: false
      )
      Krikri::PluginHelpers::DpkgDivertCommand.main_command(options, "/etc/foobarrc")
        .should eq("dpkg-divert --no-rename --local --divert /etc/foobarrc.distrib --add /etc/foobarrc")
    end

    it "builds a remove command for state=absent (holder/divert ignored)" do
      options = Krikri::PluginHelpers::DpkgDivertCommand::Options.new(
        state: "absent", holder: "branding", divert: "/somewhere/else", rename: false, force: false
      )
      Krikri::PluginHelpers::DpkgDivertCommand.main_command(options, "/etc/foobarrc")
        .should eq("dpkg-divert --no-rename --remove /etc/foobarrc")
    end
  end

  describe ".with_test" do
    it "inserts --test right after the binary, before the action flags" do
      Krikri::PluginHelpers::DpkgDivertCommand.with_test(
        "dpkg-divert --no-rename --local --divert /etc/x.distrib --add /etc/x"
      ).should eq("dpkg-divert --test --no-rename --local --divert /etc/x.distrib --add /etc/x")
    end
  end

  describe ".remove_command" do
    it "keeps --no-rename for the in-place remove-then-re-add path" do
      Krikri::PluginHelpers::DpkgDivertCommand.remove_command("/etc/x")
        .should eq("dpkg-divert --no-rename --remove '/etc/x'")
    end
  end

  describe ".listpackage_command / .truename_command" do
    it "quotes the path" do
      Krikri::PluginHelpers::DpkgDivertCommand.listpackage_command("/etc/foobarrc")
        .should eq("dpkg-divert --listpackage '/etc/foobarrc'")
      Krikri::PluginHelpers::DpkgDivertCommand.truename_command("/etc/foobarrc")
        .should eq("dpkg-divert --truename '/etc/foobarrc'")
    end
  end
end
