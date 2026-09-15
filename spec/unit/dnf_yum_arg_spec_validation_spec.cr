require "../spec_helper"
require "json"

# Regression for the podman-diff dnf_edge_cases N2/N6 findings: real
# ansible-core's dnf module rejects parameters outside its argument_spec
# (message live-verified against bookworm's ansible-core 2.14) and
# fails bool-typed params on non-boolean strings, before any module
# code runs. This engine silently ignored unknown keys and accepted
# any string as a bool, proceeding to the backend.
private def run_dnf(params : Hash(String, String)) : JSON::Any
  config = {
    "params" => params,
    "vars"   => Hash(String, JSON::Any).new,
    "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
  }.to_json
  stdout = IO::Memory.new
  Process.run("bin/plugins/dnf", input: IO::Memory.new(config), output: stdout, error: stdout)
  JSON.parse(stdout.to_s)
end

describe "dnf: argument-spec validation" do
  it "rejects an out-of-spec parameter with real Ansible's message" do
    result = run_dnf({"name" => "bash", "state" => "present", "krikri_not_a_dnf_param" => "true"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Unsupported parameters for (ansible.builtin.dnf) module: krikri_not_a_dnf_param")
    result["msg"].as_s.should contain("(expire-cache, pkg)")
  end

  it "rejects a non-boolean value for a bool-typed param" do
    result = run_dnf({"name" => "bash", "state" => "present", "disable_gpg_check" => "sometimes"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("argument 'disable_gpg_check' is of type <class 'str'>")
    result["msg"].as_s.should contain("The value 'sometimes' is not a valid boolean")
  end

  it "still accepts all documented params including use_backend choices" do
    result = run_dnf({"name" => "bash", "state" => "present-nowhere", "use_backend" => "auto", "disable_gpg_check" => "yes"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("value of state must be one of: absent, installed, latest, present, removed, got: present-nowhere")
  end
end

describe "yum: argument-spec validation" do
  it "rejects an out-of-spec parameter" do
    config = {
      "params" => {"name" => "bash", "state" => "present", "krikri_not_a_yum_param" => "true"},
      "vars"   => Hash(String, JSON::Any).new,
      "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
    }.to_json
    stdout = IO::Memory.new
    Process.run("bin/plugins/yum", input: IO::Memory.new(config), output: stdout, error: stdout)
    result = JSON.parse(stdout.to_s)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Unsupported parameters for (ansible.builtin.yum) module: krikri_not_a_yum_param")
  end

  it "rejects a non-boolean value for a bool-typed param" do
    config = {
      "params" => {"name" => "bash", "state" => "present", "disable_gpg_check" => "sometimes"},
      "vars"   => Hash(String, JSON::Any).new,
      "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
    }.to_json
    stdout = IO::Memory.new
    Process.run("bin/plugins/yum", input: IO::Memory.new(config), output: stdout, error: stdout)
    result = JSON.parse(stdout.to_s)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("The value 'sometimes' is not a valid boolean")
  end
end
