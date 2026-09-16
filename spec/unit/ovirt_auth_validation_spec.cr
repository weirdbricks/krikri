require "../spec_helper"

# Pins plugins/ovirt_auth.cr's argument-validation surface against real
# ovirt.ovirt.ovirt_auth's AnsibleModule setup (source-verified; the
# podman-diff harness can't byte-confirm the post-validation paths since
# real fails at its check_sdk() SDK import before the module body ever
# runs unless ovirt-engine-sdk-python is installed):
#
# - state is choices-validated [present, absent]
# - timeout is type-converted int, insecure/compress/kerberos are bool,
#   headers/ovirt_auth are dict (parameters.py wording)
# - required_if fires for state=absent without ovirt_auth
# - the "You must specify either 'url' or 'hostname'." check reads
#   url/hostname from the PREVIOUS ovirt_auth fact dict when state=absent
#   (the real module re-points params at that dict), and a hostname-only
#   login expands to https://<hostname>/ovirt-engine/api instead of
#   failing the url-only check
describe "ovirt_auth plugin argument validation" do
  it "fails an invalid state choice" do
    result = PluginSpecHelper.run("ovirt_auth", {
      "state" => "bogus",
      "url"   => "https://engine.example.com/ovirt-engine/api",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("value of state must be one of: present, absent, got bogus")
  end

  it "fails a non-integer timeout with the type-conversion wording" do
    result = PluginSpecHelper.run("ovirt_auth", {
      "url"     => "https://engine.example.com/ovirt-engine/api",
      "timeout" => "not-a-timeout",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "argument 'timeout' is of type <class 'str'> and we were unable to convert to int: " \
      "<class 'str'> cannot be converted to an int"
    )
  end

  it "fails a non-boolean insecure with the type-conversion wording" do
    result = PluginSpecHelper.run("ovirt_auth", {
      "url"      => "https://engine.example.com/ovirt-engine/api",
      "insecure" => "banana",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain(
      "argument 'insecure' is of type <class 'str'> and we were unable to convert to bool: " \
      "The value 'banana' is not a valid boolean."
    )
  end

  it "fails a non-dict headers with the type-conversion wording" do
    result = PluginSpecHelper.run("ovirt_auth", {
      "url"     => "https://engine.example.com/ovirt-engine/api",
      "headers" => "not-a-dict",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "argument 'headers' is of type <class 'str'> and we were unable to convert to dict: " \
      "dictionary requested, could not parse JSON or key=value"
    )
  end

  it "fails state=absent without ovirt_auth (required_if)" do
    result = PluginSpecHelper.run("ovirt_auth", {"state" => "absent"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("state is absent but all of the following are missing: ovirt_auth")
  end

  it "fails a non-dict ovirt_auth with the type-conversion wording" do
    result = PluginSpecHelper.run("ovirt_auth", {
      "state"      => "absent",
      "ovirt_auth" => "not-a-dict",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq(
      "argument 'ovirt_auth' is of type <class 'str'> and we were unable to convert to dict: " \
      "dictionary requested, could not parse JSON or key=value"
    )
  end

  it "reads url/hostname from the previous fact dict for state=absent" do
    result = PluginSpecHelper.run("ovirt_auth", {
      "state"      => "absent",
      "ovirt_auth" => %({"token": "abc"}),
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("You must specify either 'url' or 'hostname'.")
  end

  it "accepts a hostname-only login (expanded to the engine API URL)" do
    result = PluginSpecHelper.run("ovirt_auth", {"hostname" => "127.0.0.1"})

    # nothing listens on the engine here - the point is that validation
    # PASSES and the plugin proceeds to the (failing) SSO request, where
    # the old url-only check failed outright
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should_not contain("You must specify either")
  end
end
