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
    it "appends params: verbatim after the module name" do
      Krikri::PluginHelpers::ModprobeCommand.load_command("dummy", "numdummies=2").should eq("modprobe dummy numdummies=2")
    end

    it "omits the trailing space when params: is nil" do
      Krikri::PluginHelpers::ModprobeCommand.load_command("dummy", nil).should eq("modprobe dummy")
    end

    it "omits the trailing space when params: is an empty string" do
      Krikri::PluginHelpers::ModprobeCommand.load_command("dummy", "").should eq("modprobe dummy")
    end

    it "supports multiple space-separated params" do
      Krikri::PluginHelpers::ModprobeCommand.load_command("dummy", "numdummies=2 foo=bar").should eq("modprobe dummy numdummies=2 foo=bar")
    end
  end
end
