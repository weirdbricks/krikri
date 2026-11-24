require "file_utils"
require "../minitest_helper"

# parted/lvg parameter-validation paths - exercised before any
# state-mutating command, so they need neither parted nor LVM. Anything
# past validation needs real block devices or a volume group and belongs
# to the live benchmark rounds, not this suite.
describe "parted plugin" do
  it "fails when device is missing" do
    result = PluginSpecHelper.run("parted", {"number" => "1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("device")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/sdz99", "state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: absent, info, present, got: bogus")
  end

  it "fails on an invalid unit" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/sdz99", "unit" => "furlongs"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("value of unit must be one of")
  end

  it "fails on a missing device before any mutation" do
    result = PluginSpecHelper.run("parted", {"device" => "/dev/krikri-no-such-disk"})

    result["failed"].as_bool.must_equal(true)
    # Real parted.py has no separate stat check - get_device_info's
    # parted script fails and real surfaces the wrapper message
    # (plus rc/out/err), not the parted stderr itself (kpg34).
    result["msg"].as_s.must_include("Error while getting device information with parted script:")
    result["rc"].as_i64.must_equal(1)
  end

  it "rejects an unparseable part_start before touching the device" do
    # Real parted.py's conditioning block runs check_size_format on both
    # boundaries before get_device_info, so the size-interpretation error
    # wins over the missing device's parted failure (kpg
    # 000000-multi-nsupdate-chaos).
    result = PluginSpecHelper.run("parted", {
      "device"     => "/dev/krikri-no-such-disk",
      "number"     => "38",
      "part_start" => "vqcisp",
      "part_end"   => "100%",
      "state"      => "present",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Error interpreting parted size output: 'vqcisp'")
    result.as_h.has_key?("rc").must_equal(false)
  end

  it "rejects a part_start unit outside parted's own unit set" do
    result = PluginSpecHelper.run("parted", {
      "device"     => "/dev/krikri-no-such-disk",
      "number"     => "38",
      "part_start" => "10XB",
      "part_end"   => "100%",
      "state"      => "present",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("The argument 'part_start' doesn't respect required format.The size unit is case sensitive.")
    parsed = result["err"].as_a
    parsed[0].as_f.must_equal(10.0)
    parsed[1].as_s.must_equal("XB")
  end
end

describe "lvg plugin" do
  it "fails when vg is missing" do
    result = PluginSpecHelper.run("lvg", {"pvs" => "/dev/sdz99"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("missing required arguments: vg")
  end

  it "fails when pvs is missing for a new volume group" do
    result = PluginSpecHelper.run("lvg", {"vg" => "krikri-nosuch-vg"})

    result["failed"].as_bool.must_equal(true)
    # Real lvg.py (7.1.0+): pvs_required = present-state AND vg missing
    # -> "No physical volumes given." - not a required_if error.
    result["msg"].as_s.must_include("No physical volumes given.")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("lvg", {"vg" => "vg0", "pvs" => "/dev/sdz99", "state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("value of state must be one of: absent, present, active, inactive, got: bogus")
  end

  it "rejects unsupported parameters like AnsibleModule" do
    result = PluginSpecHelper.run("lvg", {"vg" => "vg0", "pvs" => "/dev/sdz99", "bogus_param" => "1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Unsupported parameters for (community.general.lvg) module: bogus_param")
  end
end
