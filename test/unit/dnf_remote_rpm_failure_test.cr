require "../minitest_helper"
require "json"

# Real dnf.py routes names ending .rpm through _install_remote_rpms
# (base.add_remote_rpms) whose except wraps ANY failure as
# "Error occurred attempting remote rpm operation: <e>" with results=[]
# and rc=1 - NOT the failures-list shape (robertdebock.atom round
# 5410000: the role's earlier download task left no rpm at /tmp, both
# engines failed, real's msg was the remote-rpm wrap, krikri's the
# standard "Failed to install packages" failures list; registered real
# shape: {"changed": false, "msg": "Error occurred attempting remote rpm
# operation: Could not open: /tmp/atom.x86_64.rpm", "rc": 1, "results": []}).
describe "dnf local-rpm remote-rpm failure shape" do
  it "fails an unreadable .rpm name with the remote-rpm wrap" do
    result = PluginSpecHelper.run("dnf", {
      "name"  => "/tmp/krikri-definitely-missing-atom.x86_64.rpm",
      "state" => "present",
    })
    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["rc"].as_i.must_equal(1)
    # no failures-list shape
    result.as_h.has_key?("failures").must_equal(false)
    result["msg"].as_s.must_equal(
      "Error occurred attempting remote rpm operation: Could not open: /tmp/krikri-definitely-missing-atom.x86_64.rpm")
  end

  # Ansible hands file:// URLs straight to dnf, which opens the local path;
  # an existing file must not trip the readability pre-check.
  it "does not report an existing file:// rpm as unopenable" do
    path = PluginSpecHelper.tmp_path("present.rpm")
    File.write(path, "not a real rpm")
    result = PluginSpecHelper.run("dnf", {
      "name"  => "file://#{path}",
      "state" => "present",
    })
    (result["msg"]?.try(&.as_s?) || "").includes?("Could not open").must_equal(false)
  end
end
