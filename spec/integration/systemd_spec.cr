require "../spec_helper"

# The systemd plugin drives the real `systemctl` on the target, so — like the
# `user`/`group` plugins — these tests exercise only the paths that can't
# mutate a real system: pure validation (missing params, invalid state) and
# check-mode predictions. Never run a non-check-mode state/mask/enable call
# here; that would actually start/stop/mask a unit on the dev machine.
describe "systemd plugin" do
  it "fails when no action parameter is given, with real Ansible's required_one_of message" do
    # Real AnsibleModule validation (ansible/modules/systemd.py):
    # required_one_of=[['state', 'enabled', 'masked', 'daemon_reload',
    # 'daemon_reexec']]. Replaces the previous ad-hoc guard's own
    # "Must specify at least one of ..." wording.
    result = PluginSpecHelper.run("systemd", {} of String => String)
    result["failed"].as_bool.should be_true
    result["msg"].to_s.should eq(
      "one of the following is required: state, enabled, masked, daemon_reload, daemon_reexec")
  end

  it "fails a name-only task with real Ansible's required_one_of message (name is not one of the required options)" do
    result = PluginSpecHelper.run("systemd", {"name" => "foo.service"})
    result["failed"].as_bool.should be_true
    result["msg"].to_s.should eq(
      "one of the following is required: state, enabled, masked, daemon_reload, daemon_reexec")
  end

  it "fails when state is given without a name, with real Ansible's required_by message" do
    # required_by={state: name, enabled: name, masked: name} - real
    # Ansible's check_required_by wording, per-parameter. Replaces the
    # previous "Must specify 'name' when using ..." wording.
    result = PluginSpecHelper.run("systemd", {"state" => "started"})
    result["failed"].as_bool.should be_true
    result["msg"].to_s.should eq("missing parameter(s) required by 'state': name")
  end

  {"enabled" => "true", "masked" => "true"}.each do |key, value|
    it "fails when #{key} is given without a name, with real Ansible's required_by message" do
      result = PluginSpecHelper.run("systemd", {key => value})
      result["failed"].as_bool.should be_true
      result["msg"].to_s.should eq("missing parameter(s) required by '#{key}': name")
    end
  end

  it "accepts force: with enabled: in check mode (flags only affect the real invocations)" do
    result = PluginSpecHelper.run("systemd", {
      "name"                => "nonexistent-krikri-playbook-unit.service",
      "enabled"             => "true",
      "force"               => "true",
      "_ansible_check_mode" => "true",
    })
    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    result["msg"].to_s.should contain("enable")
  end

  it "accepts no_block: with state: started in check mode (flags only affect the real invocations)" do
    result = PluginSpecHelper.run("systemd", {
      "name"                => "nonexistent-krikri-playbook-unit.service",
      "state"               => "started",
      "no_block"            => "yes",
      "_ansible_check_mode" => "true",
    })
    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    result["msg"].to_s.should contain("start")
  end

  # Real bug found via round 813233 (role libre_ops.multi_redis): the
  # role passes `systemd: {name: ..., status: ...}` - `status` is not a
  # parameter of real Ansible's systemd module at all
  # (ansible/modules/systemd_service.py's argument_spec), so real
  # ansible-playbook rejects the task outright at argument-spec
  # validation time, before the module runs. This plugin previously
  # silently accepted and ignored the unknown key and ran anyway.
  it "rejects an unsupported parameter with real Ansible's argument-spec message" do
    result = PluginSpecHelper.run("systemd", {
      "name"   => "foo.service",
      "state"  => "started",
      "status" => "yes",
    })
    result["failed"].as_bool.should be_true
    result["msg"].to_s.should eq(
      "Unsupported parameters for (systemd) module: status. " \
      "Supported parameters include: daemon_reexec, daemon_reload, enabled, force, masked, name, no_block, scope, state " \
      "(daemon-reexec, daemon-reload, service, unit).")
  end

  it "sorts multiple unsupported parameters alphabetically in real Ansible's argument-spec message" do
    result = PluginSpecHelper.run("systemd", {
      "name"    => "foo.service",
      "state"   => "started",
      "status"  => "yes",
      "pattern" => "foo*",
    })
    result["failed"].as_bool.should be_true
    result["msg"].to_s.should eq(
      "Unsupported parameters for (systemd) module: pattern, status. " \
      "Supported parameters include: daemon_reexec, daemon_reload, enabled, force, masked, name, no_block, scope, state " \
      "(daemon-reexec, daemon-reload, service, unit).")
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
    result = PluginSpecHelper.run("systemd", {"daemon_reload" => "true", "_ansible_check_mode" => "true"})
    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_false
  end

  it "predicts a daemon-reexec in check mode without touching the system, reporting unchanged" do
    # Real bug found benchmarking robertdebock.mysql's own "Systemctl
    # daemon-reexec" handler: `ansible.builtin.systemd: {daemon_reexec:
    # true}`, no other params at all (round 18). `daemon_reexec` was
    # entirely unrecognized before - fell into the "no action" guard
    # and failed outright instead of running the reexec real
    # ansible-playbook performs (same "no changed signal" semantics as
    # daemon_reload above).
    result = PluginSpecHelper.run("systemd", {"daemon_reexec" => "true", "_ansible_check_mode" => "true"})
    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_false
  end

  it "predicts a start for a stopped unit in check mode" do
    result = PluginSpecHelper.run("systemd", {
      "name"                => "nonexistent-krikri-playbook-unit.service",
      "state"               => "started",
      "_ansible_check_mode" => "true",
    })
    # This is a unit that almost certainly does not exist (is-active fails),
    # so check mode predicts a change — and never actually runs systemctl.
    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
  end

  # Real bug found benchmarking konstruktoid.docker_rootless (0.9.619):
  # `scope: user` (real Ansible's `systemd_service`/`systemd` parameter
  # for targeting the invoking user's OWN systemd session manager - the
  # idiomatic way a rootless-Docker/Podman role enables its own user
  # unit) was completely unhandled: every `systemctl` call always hit
  # the SYSTEM manager regardless, so `konstruktoid.docker_rootless`'s
  # own "Enable and start Docker" (`scope: user`) failed outright
  # ("Unit file docker.service does not exist" - looking at the system
  # namespace instead of `~/.config/systemd/user/docker.service`).
  # Live-verified end-to-end against a real per-user systemd unit
  # (enable+start actually took effect under `systemctl --user`) - this
  # spec only checks `scope: user` is accepted and handled like any
  # other query, staying inside this file's own no-real-mutation
  # convention.
  it "accepts scope: user without rejecting the parameter" do
    result = PluginSpecHelper.run("systemd", {
      "name"                => "nonexistent-krikri-playbook-user-unit.service",
      "state"               => "started",
      "scope"               => "user",
      "_ansible_check_mode" => "true",
    })
    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
  end

  # Real bug found benchmarking mdsketch.teleport: its own
  # "Reload_Teleport" handler (`ansible.builtin.systemd: {name: teleport,
  # state: reloaded, daemon_reload: yes, enabled: yes}`) fired on a fresh
  # install where the unit file was created in the same play and the
  # service had never started. Real Ansible's systemd module STARTS an
  # inactive unit for `state: reloaded` (plain `systemctl reload` of an
  # inactive unit fails "is not active, cannot reload" - exactly the
  # error krikri's handler died with); krikri ran the reload
  # unconditionally and failed. Same semantics plugins/service.cr already
  # implements for the `service` module's `state: reloaded`. Check mode
  # on a nonexistent (hence inactive) unit must therefore predict a
  # START, not a reload.
  it "predicts a start (not a reload) for an inactive unit with state: reloaded in check mode" do
    result = PluginSpecHelper.run("systemd", {
      "name"                => "nonexistent-krikri-playbook-unit.service",
      "state"               => "reloaded",
      "_ansible_check_mode" => "true",
    })
    result["failed"]?.try(&.as_bool).should be_falsey
    result["changed"].as_bool.should be_true
    result["msg"].to_s.should contain("start")
    result["msg"].to_s.should_not contain("reload")
  end
end
