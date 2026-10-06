require "../minitest_helper"
require "json"

# Regression for the podman-diff dnf_edge_cases N2/N6 findings:
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

# Same harness but taking the raw params JSON, so a spec can send an
# EXPLICIT JSON null for a param - the wire shape BasePlugin's
# null-bookkeeping (NONE_SENTINEL / JSON null) exists to detect.
private def run_dnf_raw(params_json : String) : JSON::Any
  config = {
    "params" => JSON.parse(params_json),
    "vars"   => Hash(String, JSON::Any).new,
    "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
  }.to_json
  stdout = IO::Memory.new
  Process.run("bin/plugins/dnf", input: IO::Memory.new(config), output: stdout, error: stdout)
  JSON.parse(stdout.to_s)
end

private def run_yum_raw(params_json : String) : JSON::Any
  config = {
    "params" => JSON.parse(params_json),
    "vars"   => Hash(String, JSON::Any).new,
    "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
  }.to_json
  stdout = IO::Memory.new
  Process.run("bin/plugins/yum", input: IO::Memory.new(config), output: stdout, error: stdout)
  JSON.parse(stdout.to_s)
end

describe "dnf: argument-spec validation" do
  it "rejects an out-of-spec parameter with Ansible's message" do
    result = run_dnf({"name" => "bash", "state" => "present", "krikri_not_a_dnf_param" => "true"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Unsupported parameters for (ansible.builtin.dnf) module: krikri_not_a_dnf_param")
    result["msg"].as_s.must_include("(expire-cache, pkg)")
  end

  it "rejects a non-boolean value for a bool-typed param" do
    result = run_dnf({"name" => "bash", "state" => "present", "disable_gpg_check" => "sometimes"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("argument 'disable_gpg_check' is of type str")
    result["msg"].as_s.must_include("The value 'sometimes' is not a valid boolean")
  end

  it "still accepts all documented params including use_backend choices" do
    result = run_dnf({"name" => "bash", "state" => "present-nowhere", "use_backend" => "auto", "disable_gpg_check" => "yes"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("value of state must be one of: absent, installed, latest, present, removed, got: present-nowhere")
  end

  # ansible-core 2.19.11, live-verified (use_backend: yum4 forced on
  # a Debian host to reach argspec validation): each of dnf's four
  # `type: list` params given an explicit YAML null fails with the
  # generic NoneType list-conversion message, while an empty string and
  # an omitted param both coerce to an empty list and pass. Round 900905
  # officel.httpd: this engine used to silently drop the null and
  # install the packages where ansible-playbook failed the task.
  {% for param in {"name", "enablerepo", "disablerepo", "exclude"} %}
    it "rejects an explicit null {{param.id}} with Ansible's NoneType message" do
      params = {{param}} == "name" ? {"state" => "present"} : {"name" => "bash", "state" => "present"}
      result = run_dnf_raw(params.to_json.sub("}", ", \"{{param.id}}\":null}"))
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("argument '{{param.id}}' is of type NoneType and we were unable to convert to list: " \
                                   "<class 'NoneType'> cannot be converted to a list")
    end
  {% end %}

  it "does not reject an empty-string list param (real argspec coerces it to an empty list)" do
    result = run_dnf({"name" => "bash", "state" => "present", "enablerepo" => ""})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.wont_include("NoneType")
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
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Unsupported parameters for (ansible.builtin.yum) module: krikri_not_a_yum_param")
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
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("The value 'sometimes' is not a valid boolean")
  end

  # Same live-verified NoneType argspec behavior as dnf's block above -
  # yum.py shares yumdnf's argument_spec for all four `type: list`
  # params (round 900905 officel.httpd's `enablerepo: ~` loop default
  # made ansible-playbook fail where this engine installed on).
  {% for param in {"name", "enablerepo", "disablerepo", "exclude"} %}
    it "rejects an explicit null {{param.id}} with Ansible's NoneType message" do
      params = {{param}} == "name" ? {"state" => "present"} : {"name" => "bash", "state" => "present"}
      result = run_yum_raw(params.to_json.sub("}", ", \"{{param.id}}\":null}"))
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("argument '{{param.id}}' is of type NoneType and we were unable to convert to list: " \
                                   "<class 'NoneType'> cannot be converted to a list")
    end
  {% end %}

  it "does not reject an empty-string list param (real argspec coerces it to an empty list)" do
    config = {
      "params" => {"name" => "bash", "state" => "present", "enablerepo" => ""},
      "vars"   => Hash(String, JSON::Any).new,
      "host"   => {"name" => "localhost", "vars" => Hash(String, JSON::Any).new},
    }.to_json
    stdout = IO::Memory.new
    Process.run("bin/plugins/yum", input: IO::Memory.new(config), output: stdout, error: stdout)
    result = JSON.parse(stdout.to_s)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.wont_include("NoneType")
  end
end

describe "dnf: yumdnf mutual exclusion + autoremove sanity" do
  it "rejects name together with list (presence-based, even for empty-string list)" do
    result = run_dnf({"name" => "gzip", "list" => ""})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: name|list")
  end

  it "counts the pkg alias as name for the name|list collision" do
    result = run_dnf({"pkg" => "gzip", "list" => "installed"})
    result["msg"].as_s.must_equal("parameters are mutually exclusive: name|list")
  end

  it "collides on best:false + nobest:false (presence, not truthiness)" do
    result = run_dnf({"name" => "gzip", "best" => "false", "nobest" => "false"})
    result["msg"].as_s.must_equal("parameters are mutually exclusive: best|nobest")
  end

  it "reports every colliding group in one message" do
    result = run_dnf({"name" => "gzip", "list" => "installed", "best" => "true", "nobest" => "true"})
    result["msg"].as_s.must_equal("parameters are mutually exclusive: name|list, best|nobest")
  end

  it "fires mutual exclusion before bool conversion (live-verified 2.19 order)" do
    result = run_dnf({"name" => "gzip", "list" => "installed", "disable_gpg_check" => "notabool"})
    result["msg"].as_s.must_equal("parameters are mutually exclusive: name|list")
  end

  it "does not collide when only one member of each group is present" do
    result = run_dnf({"name" => "gzip", "state" => "present"})
    # the plugin proceeds past validation into the (failing, dnf-less test
    # host) transaction - the assertion is that argspec never rejected it
    refute(result["msg"]?.try(&.as_s).try(&.includes?("mutually exclusive")))
  end

  it "fails autoremove with an explicit contradicting state" do
    result = run_dnf({"autoremove" => "true", "state" => "present"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Autoremove should be used alone or with state=absent")
  end

  it "fails autoremove with an explicit contradicting state even without name" do
    result = run_dnf({"autoremove" => "true", "state" => "present"})
    result["msg"].as_s.must_equal("Autoremove should be used alone or with state=absent")
  end

  it "runs the autoremove transaction instead of a missing-name error (state absent)" do
    result = run_dnf({"autoremove" => "true", "state" => "absent"})
    msg = result["msg"]?.try(&.as_s) || ""
    refute(msg.includes?("Missing required parameter: name"))
    refute(msg.includes?("Autoremove should be used alone"))
  end

  it "runs the autoremove transaction instead of a missing-name error (state omitted)" do
    result = run_dnf({"autoremove" => "true"})
    msg = result["msg"]?.try(&.as_s) || ""
    refute(msg.includes?("Missing required parameter: name"))
  end

  it "reports a bad explicit state before list queries run" do
    result = run_dnf({"name" => "gzip", "state" => "bogusstate"})
    result["msg"].as_s.must_equal("value of state must be one of: absent, installed, latest, present, removed, got: bogusstate")
  end
end
