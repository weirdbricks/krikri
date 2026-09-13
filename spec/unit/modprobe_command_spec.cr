require "../spec_helper"
require "../../src/krikri/plugin_helpers/modprobe_command"

# Real bug found via a proactive scope-cut audit: params: (extra
# modprobe arguments, e.g. "numdummies=2") was entirely unimplemented.
# Verified against real community.general modprobe.py's own source:
# only ever applied at initial load time (`load_module` is only called
# from `not modprobe.module_loaded()`), never re-checked against an
# already-loaded module.
describe Krikri::PluginHelpers::ModprobeCommand do
  describe ".load_command" do
    it "invokes the resolved binary path, appends params: verbatim after the module name" do
      Krikri::PluginHelpers::ModprobeCommand.load_command("/usr/sbin/modprobe", "dummy", "numdummies=2").should eq("/usr/sbin/modprobe dummy numdummies=2")
    end

    it "omits the trailing space when params: is nil" do
      Krikri::PluginHelpers::ModprobeCommand.load_command("/usr/sbin/modprobe", "dummy", nil).should eq("/usr/sbin/modprobe dummy")
    end

    it "omits the trailing space when params: is an empty string" do
      Krikri::PluginHelpers::ModprobeCommand.load_command("/usr/sbin/modprobe", "dummy", "").should eq("/usr/sbin/modprobe dummy")
    end

    it "supports multiple space-separated params" do
      Krikri::PluginHelpers::ModprobeCommand.load_command("/usr/sbin/modprobe", "dummy", "numdummies=2 foo=bar").should eq("/usr/sbin/modprobe dummy numdummies=2 foo=bar")
    end
  end

  # Regression anchor for the 2026-09-13 ad-hoc CLI comparison sweep:
  # the plugin used to short-circuit on its own /sys/module state check
  # and report "already unloaded" SUCCESS on a host with no modprobe
  # binary at all, where real Ansible resolves - and requires - the
  # binary before any state check. parse_bin_probe is the piece that
  # turns the resolution probe's output into that decision: a missing
  # binary must come back as path: nil (fail), never as a usable path.
  describe ".parse_bin_probe" do
    it "yields the resolved path and the searched-dir list" do
      parsed = Krikri::PluginHelpers::ModprobeCommand.parse_bin_probe(<<-OUT)
      searched=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      found=/sbin/modprobe
      OUT

      parsed[:path].should eq("/sbin/modprobe")
      parsed[:searched_paths].should eq("/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    end

    it "yields a nil path when the binary is missing (must fail, not short-circuit to success)" do
      parsed = Krikri::PluginHelpers::ModprobeCommand.parse_bin_probe(<<-OUT)
      searched=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
      found=
      OUT

      parsed[:path].should be_nil
      parsed[:searched_paths].should eq("/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
    end

    it "yields a nil path for empty probe output (probe itself failed)" do
      parsed = Krikri::PluginHelpers::ModprobeCommand.parse_bin_probe("")

      parsed[:path].should be_nil
    end
  end
end
