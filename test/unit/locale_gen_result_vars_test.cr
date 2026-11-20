require "../minitest_helper"

# Pins plugins/locale_gen.cr's wire-result shape against real
# community.general.locale_gen 2.19.11, which is a ModuleHelper: every
# variable it holds is echoed back BOTH as a top-level key of the result
# and inside the `output`/`vars` copies of its VarDict, and a do_raise()
# failure carries all of them. Found via the kpg32 generator sweep, where
# every locale_gen failure dropped the name/output/vars keys entirely.
#
# The assertions below hold on either kind of host: one that has a
# locale mechanism installed (the failure comes from the availability
# check, with mechanism/ubuntu_mode already set) and one that has neither
# (the failure is the mechanism-missing raise, which happens before those
# two variables exist).
describe "locale_gen plugin result variables" do
  def mechanism : String?
    return "glibc" if File.exists?("/etc/locale.gen")
    return "ubuntu_legacy" if File.exists?("/var/lib/locales/supported.d")
    nil
  end

  it "carries name, output and vars on the availability failure" do
    names = ["krikri_nonexistent_1", "krikri_nonexistent_2"]

    result = PluginSpecHelper.run("locale_gen", {"name" => names.to_json})

    result["failed"].as_bool.must_equal(true)
    result["name"].as_a.map(&.as_s).must_equal(names)
    result["output"].as_h["name"].as_a.map(&.as_s).must_equal(names)
    result["vars"].as_h["name"].as_a.map(&.as_s).must_equal(names)
    if mech = mechanism
      result["mechanism"].as_s.must_equal(mech)
      result["ubuntu_mode"].as_bool.must_equal(mech != "glibc")
      result["output"].as_h["mechanism"].as_s.must_equal(mech)
      result["output"].as_h["ubuntu_mode"].as_bool.must_equal(mech != "glibc")
    else
      result["msg"].as_s.must_include("are missing. Is the package \"locales\" installed?")
      # The mechanism-missing raise happens before mechanism/ubuntu_mode
      # are ever set, so its VarDict holds `name` alone.
      result["output"].as_h.keys.sort!.must_equal(["name"])
    end
  end

  it "reports an empty name list as an unchanged success, with no msg" do
    mech = mechanism
    skip "host has no locale mechanism installed" unless mech

    result = PluginSpecHelper.run("locale_gen", {"name" => "[]"})

    result["failed"]?.try(&.as_bool).must_be_nil
    result["changed"].as_bool.must_equal(false)
    result["name"].as_a.must_be_empty
    result["mechanism"].as_s.must_equal(mech)
    result["ubuntu_mode"].as_bool.must_equal(mech != "glibc")
    result["msg"]?.try(&.as_s).must_be_nil
  end

  it "fails a missing required name argument with Ansible's wording" do
    result = PluginSpecHelper.run("locale_gen", {"state" => "present"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing required arguments: name")
  end

  # ModuleHelper#output appends an empty `diff` while the module runs under
  # --diff, and fail_json splats that same dict - so the failure carries it
  # both nested in `output` and at the top level, but not in `vars`
  # (live-verified with ansible-playbook 2.21.6, registered `{{ r | to_json }}`).
  it "adds an empty diff to a diff-mode failure, top level and in output only" do
    names = ["krikri_nonexistent_1"]

    result = PluginSpecHelper.run("locale_gen", {"name" => names.to_json, "_ansible_diff" => "true"})

    result["failed"].as_bool.must_equal(true)
    result["diff"].as_h.must_be_empty
    result["output"].as_h["diff"].as_h.must_be_empty
    result["vars"].as_h.has_key?("diff").must_equal(false)

    plain = PluginSpecHelper.run("locale_gen", {"name" => names.to_json})

    plain["diff"]?.must_be_nil
    plain["output"].as_h.has_key?("diff").must_equal(false)
  end

  it "adds an empty diff to a diff-mode unchanged success" do
    mech = mechanism
    skip "host has no locale mechanism installed" unless mech

    result = PluginSpecHelper.run("locale_gen", {"name" => "[]", "_ansible_diff" => "true"})

    result["diff"].as_h.must_be_empty
    # The success path never carries the VarDict output/vars copies.
    result["output"]?.must_be_nil
    result["vars"]?.must_be_nil

    plain = PluginSpecHelper.run("locale_gen", {"name" => "[]"})

    plain["diff"]?.must_be_nil
  end
end
