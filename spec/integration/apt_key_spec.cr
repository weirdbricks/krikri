require "../spec_helper"
require "http/server"

# ansible.builtin.apt_key was entirely unimplemented before - found via
# cloudalchemy.grafana's own "Import Grafana GPG signing key" task,
# which apt-key add's a key fetched from a url:.
#
# Read-only against the real system apt-key keyring in the sense that
# it doesn't assume anything about pre-existing keys - it only checks
# for the presence of a fake, spec-only key ID that can't collide with
# a real one.
FAKE_KEY_ID   = "DEADBEEFCAFEF00D"
FAKE_KEY_BODY = "not a real GPG key, just spec fixture content\n"

apt_key_test_server = HTTP::Server.new do |context|
  case context.request.path
  when "/key.asc"
    context.response.status_code = 200
    context.response.print(FAKE_KEY_BODY)
  else
    context.response.status_code = 404
  end
end
apt_key_test_address = apt_key_test_server.bind_unused_port
spawn { apt_key_test_server.listen }
Fiber.yield

apt_key_base = "http://#{apt_key_test_address}"

describe "apt_key plugin" do
  it "requires url or data when adding a key" do
    result = PluginSpecHelper.run("apt_key", {"state" => "present"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("url or data")
  end

  it "requires id when removing a key" do
    result = PluginSpecHelper.run("apt_key", {"state" => "absent"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("id")
  end

  it "reports already-absent as unchanged for a key id that was never added" do
    result = PluginSpecHelper.run("apt_key", {"state" => "absent", "id" => FAKE_KEY_ID})

    result["changed"].as_bool.should be_false
    result["failed"].as_bool.should be_false
  end
end
