require "../minitest_helper"
require "../../src/krikri/argspec_validator"

# Unit-level coverage for the non-string YAML literal param marker
# (NON_STRING_PARAM_PREFIX): the wire encoding/decoding helpers, the
# Python-truthiness view ArgspecValidator's copy pre-check now uses, and
# the fetch plugin's action-level type check (BasePlugin demotes the
# marker on @params, but the marker must ALSO be decoded for the raw-wire
# bool validation - see StrictBoolValidation#validate_bool_params_in!).
describe "non-string YAML literal param marker" do
  it "round-trips int/float/bool literals through the prefixed JSON wire form" do
    {"89" => 89_i64, "1.5" => 1.5, "true" => true, "false" => false}.each do |text, native|
      marked = Krikri::NON_STRING_PARAM_PREFIX + native.to_json
      decoded = Krikri.non_string_scalar(marked)
      decoded.try(&.raw).must_equal(native)
      decoded.try { |decoded_value| Krikri.non_string_param_text(decoded_value) }.must_equal(text)
    end
    Krikri.non_string_scalar("89").must_be_nil
    Krikri.non_string_scalar(nil).must_be_nil
    Krikri.non_string_scalar("#{Krikri::NON_STRING_PARAM_PREFIX}not-json").must_be_nil
  end

  it "strips markers back to the exact pre-marker string form" do
    params = {
      "dest"   => Krikri::NON_STRING_PARAM_PREFIX + "89",
      "follow" => Krikri::NON_STRING_PARAM_PREFIX + "true",
      "name"   => "plain",
    }
    stripped = Krikri.strip_non_string_param_markers(params)
    stripped["dest"].must_equal("89")
    stripped["follow"].must_equal("true")
    stripped["name"].must_equal("plain")
    # Untouched input hash is returned verbatim when nothing is marked
    unmarked = {"a" => "b"} of String => String
    Krikri.strip_non_string_param_markers(unmarked).must_equal(unmarked)
  end

  it "applies Python truthiness to marked scalars and empty strings" do
    Krikri.python_param_truthy?(Krikri::NON_STRING_PARAM_PREFIX + "false").must_equal(false)
    Krikri.python_param_truthy?(Krikri::NON_STRING_PARAM_PREFIX + "0").must_equal(false)
    Krikri.python_param_truthy?(Krikri::NON_STRING_PARAM_PREFIX + "0.0").must_equal(false)
    Krikri.python_param_truthy?(Krikri::NON_STRING_PARAM_PREFIX + "true").must_equal(true)
    Krikri.python_param_truthy?(Krikri::NON_STRING_PARAM_PREFIX + "89").must_equal(true)
    Krikri.python_param_truthy?(Krikri::NON_STRING_PARAM_PREFIX + "1.5").must_equal(true)
    Krikri.python_param_truthy?("").must_equal(false)
    Krikri.python_param_truthy?("0").must_equal(true)
    Krikri.python_param_truthy?(nil).must_equal(false)
  end

  it "names the Python types Ansible's crashes report for tagged literals" do
    Krikri.python_scalar_type_name(JSON::Any.new(89_i64)).must_equal("_AnsibleTaggedInt")
    Krikri.python_scalar_type_name(JSON::Any.new(1.5)).must_equal("_AnsibleTaggedFloat")
    Krikri.python_scalar_type_name(JSON::Any.new(true)).must_equal("bool")
  end

  it "renders Python str() spellings for bools (True/False, not YAML true/false)" do
    Krikri.python_str_scalar(JSON::Any.new(true)).must_equal("True")
    Krikri.python_str_scalar(JSON::Any.new(false)).must_equal("False")
    Krikri.python_str_scalar(JSON::Any.new(89_i64)).must_equal("89")
  end

  it "copy's argspec pre-check treats falsy literals as not provided" do
    vars = Hash(String, JSON::Any).new
    prefix = Krikri::NON_STRING_PARAM_PREFIX

    dest_false = Krikri::ArgspecValidator.validate("copy", "ansible.builtin.copy", {"src" => "x", "dest" => prefix + "false"}, vars)
    dest_false.try(&.msg).must_equal("dest is required")
    dest_false.try(&.action_level?).must_equal(true)

    dest_zero = Krikri::ArgspecValidator.validate("copy", "ansible.builtin.copy", {"src" => "x", "dest" => prefix + "0"}, vars)
    dest_zero.try(&.msg).must_equal("dest is required")

    src_zero = Krikri::ArgspecValidator.validate("copy", "ansible.builtin.copy", {"dest" => "/tmp", "src" => prefix + "0"}, vars)
    src_zero.try(&.msg).must_equal("src (or content) is required")

    # A falsy src with content present runs the content path (no failure)
    src_zero_content = Krikri::ArgspecValidator.validate("copy", "ansible.builtin.copy", {"dest" => "/tmp", "src" => prefix + "0", "content" => "hi"}, vars)
    src_zero_content.must_be_nil

    # Marked truthy literals validate like their string form always did
    truthy = Krikri::ArgspecValidator.validate("copy", "ansible.builtin.copy", {"dest" => prefix + "89", "src" => "x"}, vars)
    truthy.must_be_nil
  end

  it "fetch fails a marked dest/src with Ansible's action-level message at the plugin level" do
    prefix = Krikri::NON_STRING_PARAM_PREFIX
    result = PluginSpecHelper.run("fetch", {"dest" => prefix + "89", "src" => "/etc/hostname"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Invalid type supplied for dest option, it must be a string")
    result["_ansible_action_level"].as_bool.must_equal(true)

    src_result = PluginSpecHelper.run("fetch", {"dest" => "/tmp", "src" => prefix + "42"})
    src_result["msg"].as_s.must_equal("Invalid type supplied for source option, it must be a string")

    # dest's message overwrites src's when both are non-string
    both = PluginSpecHelper.run("fetch", {"dest" => prefix + "89", "src" => prefix + "42"})
    both["msg"].as_s.must_equal("Invalid type supplied for dest option, it must be a string")

    # A marked bool rides the RAW wire too - strict bool validation must
    # decode it (flat: false is a real bool, not the marked string)
    bool_ok = PluginSpecHelper.run("fetch", {"dest" => "/tmp", "src" => "/etc/hostname", "flat" => prefix + "false", "_ansible_check_mode" => "true"})
    bool_ok["skipped"].as_bool.must_equal(true)
  end

  it "fetch reports a missing src/dest as Ansible's action-level presence failure (over types)" do
    # Real fetch's action plugin runs the presence check LAST, so it
    # overwrites the isinstance messages - a non-string src with a
    # missing dest reports "src and dest are required", and the old
    # module-level "missing required argument: dest" shape never
    # happens (live-verified vs 2.19.11).
    prefix = Krikri::NON_STRING_PARAM_PREFIX
    result = PluginSpecHelper.run("fetch", {"flat" => "true", "src" => "/etc/hostname", "edst" => "/tmp/x"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("src and dest are required")
    result["_ansible_action_level"].as_bool.must_equal(true)

    both = PluginSpecHelper.run("fetch", {"flat" => "true", "src" => prefix + "60", "edst" => "/tmp/x"})
    both["msg"].as_s.must_equal("src and dest are required")
    both["_ansible_action_level"].as_bool.must_equal(true)

    missing_src = PluginSpecHelper.run("fetch", {"flat" => "true", "dest" => "/tmp"})
    missing_src["msg"].as_s.must_equal("src and dest are required")
    missing_src["_ansible_action_level"].as_bool.must_equal(true)
  end
end
