require "../spec_helper"
require "json"

# ansible.builtin.dnf5 shares ansible-core's `yumdnf_argument_spec` with
# dnf but differs in exactly two ways the argument-spec validation must
# reflect: it ADDS `auto_install_module_deps` and it does NOT accept dnf's
# `use_backend` (there is no backend to select) or the retired
# `install_repoquery`. These specs pin that difference (the general dnf
# bool/NoneType coercion behavior is already covered by
# dnf_yum_arg_spec_validation_spec.cr against the shared helper).
private def run_dnf5(params_json : String) : JSON::Any
  config = {
    "params" => JSON.parse(params_json),
    "vars"   => Hash(String, JSON::Any).new,
    "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
  }.to_json
  stdout = IO::Memory.new
  Process.run("bin/plugins/dnf5", input: IO::Memory.new(config), output: stdout, error: stdout)
  JSON.parse(stdout.to_s)
end

describe "dnf5: argument-spec validation" do
  it "rejects an out-of-spec parameter with the dnf5 module name" do
    result = run_dnf5(%({"name": "bash", "state": "present", "krikri_not_a_dnf5_param": true}))
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Unsupported parameters for (ansible.builtin.dnf5) module: krikri_not_a_dnf5_param")
    result["msg"].as_s.should contain("auto_install_module_deps")
  end

  it "rejects use_backend, which dnf (but not dnf5) accepts" do
    result = run_dnf5(%({"name": "bash", "state": "present", "use_backend": "dnf5"}))
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Unsupported parameters for (ansible.builtin.dnf5) module: use_backend")
  end

  it "accepts best and auto_install_module_deps (dnf5-only bools)" do
    result = run_dnf5(%({"name": "bash", "state": "present-nowhere", "best": true, "auto_install_module_deps": false}))
    # Reaches the state-choices check (past arg-spec validation), proving
    # both extra params were accepted.
    result["msg"].as_s.should contain("value of state must be one of: absent, installed, latest, present, removed, got: present-nowhere")
  end

  it "rejects a non-boolean value for best" do
    result = run_dnf5(%({"name": "bash", "state": "present", "best": "sometimes"}))
    result["failed"].as_bool.should be_true
    # Wording verified against ansible-core 2.21.4 (dnf5 only exists in
    # 2.19+, so this - not the older dnf "<class 'str'>" wording - is the
    # target). The valid-boolean list is a Python set with arbitrary
    # iteration order, so only assert the stable prefix.
    result["msg"].as_s.should contain("argument 'best' is of type str and we were unable to convert to bool")
    result["msg"].as_s.should contain("is not a valid boolean")
  end

  it "rejects an explicit null name with real Ansible's NoneType message" do
    result = run_dnf5(%({"state": "present", "name": null}))
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("argument 'name' is of type NoneType and we were unable to convert to list: " \
                                 "<class 'NoneType'> cannot be converted to a list")
  end
end
