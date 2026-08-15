require "../spec_helper"

# These specs only cover the plugin's own pre-flight validation, which
# returns before any real `firewall-offline-cmd` invocation - safe to run
# without firewalld installed (not available on the regular dev machine,
# see plugins/firewalld.cr's own doc comment).
describe "firewalld plugin" do
  it "rejects state: present for a non-target thing (matches real Ansible's own validation)" do
    result = PluginSpecHelper.run("firewalld", {
      "zone" => "public", "state" => "present", "service" => "http",
      "offline" => "true", "permanent" => "true",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("absent and present state can only be used in zone level operations")
  end

  it "rejects state: absent for port_forward (matches real Ansible's own validation)" do
    result = PluginSpecHelper.run("firewalld", {
      "zone" => "public", "state" => "absent",
      "port_forward" => %([{"port": 80, "proto": "tcp", "toport": 8080}]),
      "offline" => "true", "permanent" => "true",
    })

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("absent and present state can only be used in zone level operations")
  end

  it "still allows state: present/absent for target: (the real zone-level exception)" do
    result = PluginSpecHelper.run("firewalld", {
      "zone" => "public", "state" => "present", "target" => "ACCEPT",
      "offline" => "true", "permanent" => "true",
    })

    result["msg"]?.try(&.as_s).should_not eq("absent and present state can only be used in zone level operations")
  end
end
