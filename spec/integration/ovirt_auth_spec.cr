require "../spec_helper"
require "../../src/krikri/plugin_helpers/ovirt_auth_command"

# ovirt_auth's parameter-validation failures, exercised before any
# network call. Actual SSO token acquisition/revocation needs a live
# oVirt/RHV engine - the example rounds (210319/210777 ovirt_vm-infra)
# cover that on the Atlantic backend.
#
# The module-body paths (url/hostname check, kerberos, token echo) sit
# AFTER the collection's check_sdk() gate in real ovirt_auth too (the
# gate is the first statement after AnsibleModule construction, and the
# url/hostname check is module-body code - there is no required_one_of
# for url/hostname in this module's spec), so on a host without
# ovirt-engine-sdk-python every example below fails with the SDK
# message on BOTH engines; the module-body assertions only run where
# the SDK is installed.
describe "ovirt_auth plugin" do
  it "fails when neither url nor hostname is given" do
    result = PluginSpecHelper.run("ovirt_auth", {"username" => "admin@internal", "password" => "x"})

    result["failed"].as_bool.should be_true
    if Krikri::PluginHelpers::OvirtAuthCommand.sdk_gate
      # check_sdk() precedes the module-body url/hostname check in real
      # too, so an SDK-less host fails with the SDK message here on
      # both engines.
      result["msg"].as_s.should eq("ovirtsdk4 version 4.4.0 or higher is required for this module")
    else
      result["msg"].as_s.should contain("either 'url' or 'hostname'")
    end
  end

  it "fails on an invalid state" do
    result = PluginSpecHelper.run("ovirt_auth", {
      "url"      => "https://engine.example.com/ovirt-engine/api",
      "username" => "admin@internal",
      "password" => "x",
      "state"    => "bogus",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("state")
  end

  it "fails when state=absent has no ovirt_auth dict" do
    result = PluginSpecHelper.run("ovirt_auth", {"state" => "absent"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("ovirt_auth")
  end

  it "fails explicitly on kerberos (deliberate limitation)" do
    result = PluginSpecHelper.run("ovirt_auth", {
      "url"      => "https://engine.example.com/ovirt-engine/api",
      "username" => "admin@internal",
      "password" => "x",
      "kerberos" => "true",
    })

    result["failed"].as_bool.should be_true
    if Krikri::PluginHelpers::OvirtAuthCommand.sdk_gate
      # real never validates kerberos itself (the SDK's Connection does),
      # so on an SDK-less host both engines fail at check_sdk() first.
      result["msg"].as_s.should eq("ovirtsdk4 version 4.4.0 or higher is required for this module")
    else
      result["msg"].as_s.should contain("kerberos")
    end
  end

  it "fails cleanly when the engine is unreachable" do
    result = PluginSpecHelper.run("ovirt_auth", {
      "url"      => "https://krikri-ovirt-nonexistent.invalid/ovirt-engine/api",
      "username" => "admin@internal",
      "password" => "x",
      "timeout"  => "2",
    })

    result["failed"].as_bool.should be_true
  end

  it "echoes a provided token into the ovirt_auth fact without any network call" do
    result = PluginSpecHelper.run("ovirt_auth", {
      "url"   => "https://engine.example.com/ovirt-engine/api",
      "token" => "preexisting-token",
    })

    if Krikri::PluginHelpers::OvirtAuthCommand.sdk_gate
      # The token echo is module-body code, unreachable past check_sdk()
      # on an SDK-less host (real fails identically there).
      result["failed"].as_bool.should be_true
      result["msg"].as_s.should eq("ovirtsdk4 version 4.4.0 or higher is required for this module")
    else
      result["failed"]?.try(&.as_bool).should be_falsey
      facts = result["ansible_facts"]["ovirt_auth"]
      facts["token"].as_s.should eq("preexisting-token")
      facts["url"].as_s.should eq("https://engine.example.com/ovirt-engine/api")
      facts["insecure"].as_bool.should be_true
    end
  end
end
