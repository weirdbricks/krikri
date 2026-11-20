require "../minitest_helper"

# locale_gen's parameter-validation failures, exercised before anything
# shells out or reads /etc/locale.gen. Actually generating or removing
# a locale mutates the host's locale state and belongs to the live
# benchmark rounds.
describe "locale_gen plugin" do
  it "fails when name is missing" do
    result = PluginSpecHelper.run("locale_gen", {"state" => "present"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("name")
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("locale_gen", {"name" => "en_US.UTF-8", "state" => "bogus"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("state")
  end

  # The mechanism probe is the Ansible module's first host-dependent step;
  # when neither /etc/locale.gen nor /var/lib/locales/supported.d
  # exists, that failure must surface before any availability check.
  it "fails cleanly when the locales package is not installed" do
    skip "locales machinery present on this host" if File.exists?("/etc/locale.gen") || File.exists?("/var/lib/locales/supported.d")

    result = PluginSpecHelper.run("locale_gen", {"name" => "en_US.UTF-8", "state" => "present"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Is the package")
  end

  # kpg issue #1654: locale_gen flags no VarDict variable diff=True, so
  # module_helper's --diff merge is always the empty dict. Real
  # ansible-core 2.21.6 + community.general 13.2.0 registers
  # `"diff": {}` at the top level and inside `output` (never inside
  # `vars`) on both the success and the do_raise failure paths, and no
  # diff key at all without --diff.
  it "carries the empty diff dict in output but not vars on an --diff failure" do
    result = PluginSpecHelper.run("locale_gen",
      {"name" => ["krikri_nonexistent_1", "krikri_nonexistent_2"].to_json, "_ansible_diff" => "true"})

    result["failed"].as_bool.must_equal(true)
    result["diff"].as_h.must_be_empty
    result["output"].as_h.has_key?("diff").must_equal(true)
    result["output"]["diff"].as_h.must_be_empty
    result["vars"].as_h.has_key?("diff").must_equal(false)
  end

  it "carries an empty diff dict on an --diff success" do
    skip "host has no locale mechanism installed" unless File.exists?("/etc/locale.gen") || File.exists?("/var/lib/locales/supported.d")

    result = PluginSpecHelper.run("locale_gen", {"name" => "[]", "_ansible_diff" => "true"})

    result["changed"].as_bool.must_equal(false)
    result["diff"].as_h.must_be_empty
  end

  it "emits no diff key at all without --diff" do
    result = PluginSpecHelper.run("locale_gen",
      {"name" => ["krikri_nonexistent_1"].to_json})

    result["failed"].as_bool.must_equal(true)
    result.as_h.has_key?("diff").must_equal(false)
    result["output"].as_h.has_key?("diff").must_equal(false)
  end
end
