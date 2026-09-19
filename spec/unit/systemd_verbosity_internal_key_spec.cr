require "../spec_helper"
require "json"

# Regression: the executor injects `_verbosity` into every module's
# params (see executor_task_exec.cr's final_params - debug's verbosity:
# gate reads it back out), but systemd's real-Ansible-style
# argument-spec validation treated it as an unsupported user parameter
# and failed EVERY systemd task with "Unsupported parameters ...:
# _verbosity" before the module ever ran. Real Ansible never passes
# _verbosity into module args, so it must be tolerated the same way
# check_mode/diff_mode/_environment already are. Found via
# testing/podman-diff/cases/systemd_edge_cases.yml (M4/M5).
describe "systemd: _verbosity is an accepted engine-internal param" do
  it "rejects a genuinely unsupported param but never names _verbosity" do
    config = {
      "params" => {"name" => "ssh", "status" => "bogus", "_verbosity" => "0"},
      "vars"   => Hash(String, JSON::Any).new,
      "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
    }.to_json

    stdout = IO::Memory.new
    status = Process.run("bin/plugins/systemd", input: IO::Memory.new(config), output: stdout, error: stdout)
    status.success?.should be_true

    output = JSON.parse(stdout.to_s)
    output["failed"].as_bool.should be_true
    output["msg"].as_s.should contain("status")
    output["msg"].as_s.should_not contain("_verbosity")
  end

  it "does not reject a valid task that carries only internal keys" do
    # With only supported params + internal keys present, validation must
    # pass through to the (environment-dependent) systemctl backend - we
    # assert the failure message is NOT the argument-spec rejection.
    # Deliberately no state: - a name-only task falls through to a
    # read-only `systemctl show` for status, never a mutating start/stop/
    # restart/enable call. state: started previously invoked a real
    # `systemctl start` here, which prompts a real interactive PolicyKit
    # "Authentication Required" dialog on a desktop session with a polkit
    # agent registered - the assertion below only cares that _verbosity
    # isn't rejected as an unsupported param, which the read-only path
    # exercises identically without the side effect.
    config = {
      "params" => {"name" => "krikri-no-such-unit-zzz.service", "_verbosity" => "0"},
      "vars"   => Hash(String, JSON::Any).new,
      "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
    }.to_json

    stdout = IO::Memory.new
    Process.run("bin/plugins/systemd", input: IO::Memory.new(config), output: stdout, error: stdout)
    output = JSON.parse(stdout.to_s)

    if output["failed"].as_bool
      output["msg"].as_s.should_not contain("Unsupported parameters")
    end
  end
end
