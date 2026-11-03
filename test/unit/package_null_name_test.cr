require "../minitest_helper"
require "../../src/krikri/param_sentinels"

# Issue #776 (etam.ipfs, round 29895333): `package: name:
# "{{ ipfs_dep_python3_yaml }}"` whose `{%- if -%}` chain matches no
# os_family natively resolves to Python None, and the backend MODULE's
# own argspec decides what that means: apt's `package` param is neither
# required nor defaulted, so _validate_argument_types skips the None and
# the module runs nameless (ok, changed: false - live-verified vs
# 2.19.11), while dnf/yum's `name` has default=[], so the None reaches
# check_type_list and fails the task with the generic NoneType
# list-conversion message (live-verified vs 2.19.11 with use_backend
# forced on a Debian host). krikri used to run the null as an empty
# string and fail every backend with "No package matching '' is
# available". The sentinel demotes to "" in @params either way, so these
# specs replay the None through the plugin binary's own null bookkeeping.
describe "package: an explicit-None name is backend-specific" do
  it "fails the dnf backend with Ansible's NoneType message" do
    result = PluginSpecHelper.run("package",
      {"name" => Krikri::NONE_SENTINEL, "state" => "present", "use" => "dnf"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("argument 'name' is of type NoneType and we were unable to convert to list: " \
                                  "<class 'NoneType'> cannot be converted to a list")
  end

  it "fails the yum backend with Ansible's NoneType message" do
    result = PluginSpecHelper.run("package",
      {"name" => Krikri::NONE_SENTINEL, "state" => "present", "use" => "yum"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("argument 'name' is of type NoneType and we were unable to convert to list: " \
                                  "<class 'NoneType'> cannot be converted to a list")
  end

  it "reports the canonical name even when the null rode the pkg: alias" do
    result = PluginSpecHelper.run("package",
      {"pkg" => Krikri::NONE_SENTINEL, "state" => "present", "use" => "dnf"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("argument 'name' is of type NoneType and we were unable to convert to list: " \
                                  "<class 'NoneType'> cannot be converted to a list")
  end

  # apt's argspec skips the None entirely - the module runs nameless and
  # reports ok/changed: false, like the no-name invocation this plugin
  # already mirrors (update_cache: true still takes the cache path).
  it "runs the apt backend nameless like real's argspec skip" do
    result = PluginSpecHelper.run("package",
      {"name" => Krikri::NONE_SENTINEL, "state" => "present", "use" => "apt"})
    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_equal("Nothing to do")
  end

  it "still routes an apt None name with deb: into the deb install" do
    # A real deb: dispatch is exercised live only (no dpkg mutation in
    # unit specs); here just pin that the None gate hands a deb: task to
    # the deb path - which, without a deb reachable, fails inside the deb
    # handling rather than reporting the NoneType message or "Nothing to
    # do" above it.
    result = PluginSpecHelper.run("package",
      {"name" => Krikri::NONE_SENTINEL, "deb" => "/tmp/krikri-no-such-776.deb", "use" => "apt"})
    result["msg"].as_s.includes?("NoneType").must_equal(false)
  end

  # The empty STRING name is NOT a None: both backends' argspec coerce it
  # to a one-element list ("") and fail the install with the
  # "No package matching '' is available" shape (live-verified) - the
  # pre-#776 behavior the explicit-null gate must not relax.
  it "keeps failing a genuinely empty-string name on the dnf backend" do
    result = PluginSpecHelper.run("package",
      {"name" => "", "state" => "present", "use" => "dnf"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("No package matching '' is available")
  end

  it "keeps failing a genuinely empty-string name on the apt backend" do
    result = PluginSpecHelper.run("package",
      {"name" => "", "state" => "present", "use" => "apt"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("No package matching '' is available")
  end
end
