require "../spec_helper"

# The systemd plugin drives the real `systemctl` on the target, so — like the
# `user`/`group` plugins — these tests exercise only the paths that can't
# mutate a real system: pure validation (missing params, invalid state) and
# check-mode predictions. Never run a non-check-mode state/mask/enable call
# here; that would actually start/stop/mask a unit on the dev machine.
describe "systemd plugin" do
  it "fails when no action parameter is given" do
    result = PluginSpecHelper.run("systemd", {} of String => String)
    result["failed"].as_bool.should be_true
  end

  it "fails when state is given without a name" do
    result = PluginSpecHelper.run("systemd", {"state" => "started"})
    result["failed"].as_bool.should be_true
    result["msg"].to_s.should contain("name")
  end

  it "rejects an invalid state" do
    result = PluginSpecHelper.run("systemd", {"name" => "foo.service", "state" => "frobnitz"})
    result["failed"].as_bool.should be_true
    result["msg"].to_s.should contain("Invalid state")
  end

  it "predicts a daemon-reload in check mode without touching the system, reporting unchanged" do
    # Verified against a real ansible-playbook --check run of a bare
    # `systemd: {daemon_reload: true}` task: real Ansible's own module
    # has no notion of daemon-reload "changedness" and always reports
    # `ok:`, in check mode and for real.
    result = PluginSpecHelper.run("systemd", {"daemon_reload" => "true", "check_mode" => "true"})
    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false
  end

  it "predicts a start for a stopped unit in check mode" do
    result = PluginSpecHelper.run("systemd", {
      "name"       => "nonexistent-crystal-play-unit.service",
      "state"      => "started",
      "check_mode" => "true",
    })
    # This is a unit that almost certainly does not exist (is-active fails),
    # so check mode predicts a change — and never actually runs systemctl.
    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_true
  end
end
