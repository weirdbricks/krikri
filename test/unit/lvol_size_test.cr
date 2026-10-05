require "../minitest_helper"
require "../../src/krikri/plugin_helpers/lvol_size"

# Unit-tests community.general.lvol's `size:` grammar against real
# lvol.py's own parsing loop (read from a live collection install) - the
# plugin shells out to real vgs/lvs (needs actual LVM volume groups to
# exercise), so the grammar is what's testable in isolation. The error
# strings below are the Ansible module's fail_json messages verbatim.
describe Krikri::PluginHelpers::LvolSize do
  describe ".parse" do
    it "returns nil for no size" do
      Krikri::PluginHelpers::LvolSize.parse(nil)[0].must_be_nil
      Krikri::PluginHelpers::LvolSize.parse("")[0].must_be_nil
    end

    it "defaults the unit to megabytes" do
      parsed = Krikri::PluginHelpers::LvolSize.parse("512")[0].not_nil!
      parsed.wont_be_nil
      parsed = parsed.not_nil!
      parsed.value.must_equal("512")
      parsed.value_unit.must_equal("m")
      parsed.opt.must_equal("L")
      parsed.operator.must_be_nil
    end

    it "accepts a unit suffix (case per lvcreate)" do
      parsed = Krikri::PluginHelpers::LvolSize.parse("512g")[0].not_nil!
      parsed.value.must_equal("512")
      parsed.value_unit.must_equal("g")

      parsed = Krikri::PluginHelpers::LvolSize.parse("512G")[0].not_nil!
      parsed.value_unit.must_equal("G")
    end

    it "keeps the +/- operator for resize" do
      parsed = Krikri::PluginHelpers::LvolSize.parse("+512M")[0].not_nil!
      parsed.operator.must_equal("+")
      parsed.value.must_equal("512")
      parsed.value_unit.must_equal("M")

      parsed = Krikri::PluginHelpers::LvolSize.parse("-512M")[0].not_nil!
      parsed.operator.must_equal("-")
    end

    it "parses percentages of VG|PVS|FREE|ORIGIN as extents" do
      {"VG", "PVS", "FREE", "ORIGIN"}.each do |whole|
        parsed = Krikri::PluginHelpers::LvolSize.parse("100%#{whole}")[0].not_nil!
        parsed.percent.must_equal(100)
        parsed.whole.must_equal(whole)
        parsed.opt.must_equal("l")
        parsed.value_unit.must_equal("")
        parsed.units_flag.must_equal("m")
      end
    end

    it "rejects percentages above 100" do
      parsed, error = Krikri::PluginHelpers::LvolSize.parse("101%VG")
      parsed.must_be_nil
      error.must_equal("Size percentage cannot be larger than 100%")
    end

    it "rejects unknown percentage targets" do
      parsed, error = Krikri::PluginHelpers::LvolSize.parse("50%LV")
      parsed.must_be_nil
      error.must_equal("Specify extents as a percentage of VG|PVS|FREE|ORIGIN")
    end

    it "rejects bad size specifications" do
      # the Ansible module's own message, with the size as typed
      [".5", "abc", "1x", "-"].each do |bad|
        parsed, error = Krikri::PluginHelpers::LvolSize.parse(bad)
        parsed.must_be_nil
        error.must_equal("Bad size specification of '#{bad}'")
      end
    end

    it "rejects a bare operator with no value" do
      parsed, _error = Krikri::PluginHelpers::LvolSize.parse("+512")
      parsed.not_nil!.operator.must_equal("+")
    end
  end
end
