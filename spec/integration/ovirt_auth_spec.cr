require "../spec_helper"

# ovirt_auth's parameter-validation failures, exercised before any
# network call. Actual SSO token acquisition/revocation needs a live
# oVirt/RHV engine - the example rounds (210319/210777 ovirt_vm-infra)
# cover that on the Atlantic backend.
describe "ovirt_auth plugin" do
  it "fails when neither url nor hostname is given" do
    result = PluginSpecHelper.run("ovirt_auth", {"username" => "admin@internal", "password" => "x"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("either 'url' or 'hostname'")
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
    result["msg"].as_s.should contain("kerberos")
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

    result["failed"]?.try(&.as_bool).should be_falsey
    facts = result["ansible_facts"]["ovirt_auth"]
    facts["token"].as_s.should eq("preexisting-token")
    facts["url"].as_s.should eq("https://engine.example.com/ovirt-engine/api")
    facts["insecure"].as_bool.should be_true
  end
end
