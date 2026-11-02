require "../minitest_helper"
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
      Krikri::PluginHelpers::DpkgDivertCommand.main_command(options, "/usr/bin/dpkg-divert", "/etc/foobarrc")
        .must_equal("/usr/bin/dpkg-divert --no-rename --local --add /etc/foobarrc")
    end

    it "uses --rename instead of --no-rename when rename is asked for" do
      options = Krikri::PluginHelpers::DpkgDivertCommand::Options.new(
        state: "present", holder: nil, divert: nil, rename: true, force: false
      )
      Krikri::PluginHelpers::DpkgDivertCommand.main_command(options, "/usr/bin/dpkg-divert", "/etc/foobarrc")
        .must_equal("/usr/bin/dpkg-divert --rename --local --add /etc/foobarrc")
    end

    it "passes the holder package through" do
      options = Krikri::PluginHelpers::DpkgDivertCommand::Options.new(
        state: "present", holder: "branding", divert: "/usr/bin/busybox.dpkg-divert", rename: true, force: false
      )
      Krikri::PluginHelpers::DpkgDivertCommand.main_command(options, "/usr/bin/dpkg-divert", "/usr/bin/busybox")
        .must_equal("/usr/bin/dpkg-divert --rename --package branding --divert /usr/bin/busybox.dpkg-divert --add /usr/bin/busybox")
    end

    it "treats an explicit LOCAL holder as --local" do
      options = Krikri::PluginHelpers::DpkgDivertCommand::Options.new(
        state: "present", holder: "LOCAL", divert: nil, rename: false, force: false
      )
      Krikri::PluginHelpers::DpkgDivertCommand.main_command(options, "/usr/bin/dpkg-divert", "/etc/foobarrc")
        .must_equal("/usr/bin/dpkg-divert --no-rename --local --add /etc/foobarrc")
    end

    it "builds a remove command for state=absent (holder/divert ignored)" do
      options = Krikri::PluginHelpers::DpkgDivertCommand::Options.new(
        state: "absent", holder: "branding", divert: "/somewhere/else", rename: false, force: false
      )
      Krikri::PluginHelpers::DpkgDivertCommand.main_command(options, "/usr/bin/dpkg-divert", "/etc/foobarrc")
        .must_equal("/usr/bin/dpkg-divert --no-rename --remove /etc/foobarrc")
    end
  end

  describe ".with_test" do
    it "inserts --test right after the binary, before the action flags" do
      Krikri::PluginHelpers::DpkgDivertCommand.with_test(
        "/usr/bin/dpkg-divert --no-rename --local --divert /etc/x.distrib --add /etc/x"
      ).must_equal("/usr/bin/dpkg-divert --test --no-rename --local --divert /etc/x.distrib --add /etc/x")
    end
  end

  describe ".remove_command" do
    it "keeps --no-rename for the in-place remove-then-re-add path" do
      Krikri::PluginHelpers::DpkgDivertCommand.remove_command("/usr/bin/dpkg-divert", "/etc/x")
        .must_equal("/usr/bin/dpkg-divert --no-rename --remove '/etc/x'")
    end
  end

  describe ".listpackage_command / .truename_command" do
    # The real module's run_command(check_rc=True) failure reports cmd
    # through _clean_args: resolved binary, args shlex.quote-joined -
    # safe tokens (including a relative path like `80`) stay bare.
    it "quotes only the tokens shlex.quote would" do
      Krikri::PluginHelpers::DpkgDivertCommand.listpackage_command("/usr/bin/dpkg-divert", "/etc/foobarrc")
        .must_equal("/usr/bin/dpkg-divert --listpackage /etc/foobarrc")
      Krikri::PluginHelpers::DpkgDivertCommand.listpackage_command("/usr/bin/dpkg-divert", "80")
        .must_equal("/usr/bin/dpkg-divert --listpackage 80")
      Krikri::PluginHelpers::DpkgDivertCommand.truename_command("/usr/bin/dpkg-divert", "/tmp/a b")
        .must_equal("/usr/bin/dpkg-divert --truename '/tmp/a b'")
    end
  end
end
