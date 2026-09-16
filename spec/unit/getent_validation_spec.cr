require "../spec_helper"

# Pins plugins/getent.cr's AnsibleModule surface against real
# ansible.builtin.getent (ansible-core 2.14 getent.py; live-diffed via
# the podman-diff getent_edge_cases harness): required-args wording, the
# fail_key bool conversion, unsupported params (no aliases -> no
# parenthetical), the get_bin_path('getent', required=True) gate, and
# the rc-mapped messages of the real binary.
describe "getent plugin argument validation" do
  it "fails a missing database with the sorted plural wording" do
    result = PluginSpecHelper.run("getent", {} of String => String)

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: database")
  end

  it "fails a non-boolean fail_key with parameters.py wording" do
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "fail_key" => "banana"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'fail_key' is of type <class 'str'> and we were unable to convert to bool: " \
                                      "The value 'banana' is not a valid boolean.  Valid booleans include: ")
  end

  it "rejects unsupported parameters (no aliases, no parenthetical)" do
    result = PluginSpecHelper.run("getent", {"database" => "passwd", "krikri_param" => "yes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (ansible.builtin.getent) module: krikri_param. " \
                                 "Supported parameters include: database, fail_key, key, service, split.")
  end

  it "maps an unknown database to real's rc-1 wording" do
    result = PluginSpecHelper.run("getent", {"database" => "krikri_db"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Missing arguments, or database unknown.")
  end

  it "still carries the invocation block on the unknown-database failure" do
    result = PluginSpecHelper.run("getent", {"database" => "krikri_db"})

    result["invocation"]["module_args"]["database"].as_s.should eq("krikri_db")
    result["invocation"]["module_args"]["fail_key"].as_bool.should be_true
  end
end
