require "../spec_helper"
require "file_utils"
require "../../src/krikri/python_module_runner"

private def write_module(dir : String, name : String, content : String) : String
  lib_dir = File.join(dir, "library")
  Dir.mkdir_p(lib_dir)
  path = File.join(lib_dir, name)
  File.write(path, content)
  path
end

describe Krikri::PythonModuleRunner do
  # ---- source resolution ----

  it "finds a role-private library module" do
    role = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    path = write_module(role, "sr_fingerprint.py", "# test module")
    Krikri::PythonModuleRunner.find_source("sr_fingerprint", role, nil)
      .should eq(path)
    FileUtils.rm_r(role)
  end

  it "finds a role-private library module even when the role ships no files/ dir at all" do
    # Regression: linux-system-roles.storage/.logging/.timesync (none of
    # which ship a files/ subdirectory) could never resolve their own
    # sr_fingerprint/blivet/timesync_provider - find_source used to
    # derive the role root from `role_files_dir` (only ever set when a
    # files/ dir exists), silently falling back to "unavailable modules"
    # for every role missing one. Fixed to take the role's root
    # directory (task.role_path, always set) directly.
    role = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    path = write_module(role, "blivet.py", "# test module")
    Krikri::PythonModuleRunner.find_source("blivet", role, nil).should eq(path)
    File.exists?(File.join(role, "files")).should be_false
    FileUtils.rm_r(role)
  end

  it "resolves the short name of an FQCN module reference" do
    Krikri::PythonModuleRunner.short_name("linux_system_roles.sr_fingerprint").should eq("sr_fingerprint")
    Krikri::PythonModuleRunner.short_name("sr_fingerprint").should eq("sr_fingerprint")
  end

  it "finds a playbook-adjacent library module" do
    pb = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(pb)
    path = write_module(pb, "my_custom.py", "# test module")
    Krikri::PythonModuleRunner.find_source("my_custom", nil, pb).should eq(path)
    FileUtils.rm_r(pb)
  end

  it "returns nil when no library source exists" do
    pb = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(pb)
    Krikri::PythonModuleRunner.find_source("no_such_module", nil, pb).should be_nil
    FileUtils.rm_r(pb)
  end

  it "prefers the role library over the playbook library" do
    role = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    pb = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    Dir.mkdir_p(pb)
    role_path = write_module(role, "both.py", "# role")
    write_module(pb, "both.py", "# playbook")
    Krikri::PythonModuleRunner.find_source("both", role, pb)
      .should eq(role_path)
    FileUtils.rm_r(role)
    FileUtils.rm_r(pb)
  end

  # ---- invocation-shape detection ----

  it "detects new-style modules by their ansible.module_utils import" do
    Krikri::PythonModuleRunner.new_style?(%(from ansible.module_utils.basic import AnsibleModule))
      .should be_true
    Krikri::PythonModuleRunner.new_style?("#!/usr/bin/python\nimport json\nprint('{}')").should be_false
  end

  # ---- argument building ----

  it "re-types JSON-encoded params and adds the reserved _ansible keys" do
    args = JSON.parse(Krikri::PythonModuleRunner.build_module_args(
      {"name" => "x", "list" => %q(["a", "b"]), "count" => "3",
       "check_mode" => "false", "diff_mode" => "false", "_verbosity" => "0"},
      check_mode: false,
    ))
    args["name"].as_s.should eq("x")
    args["list"].as_a.map(&.as_s).should eq(["a", "b"])
    args["count"].as_i.should eq(3)
    args["_ansible_check_mode"].as_bool.should be_false
    # the plugin-config bookkeeping keys stay out of the module's args
    args["check_mode"]?.should be_nil
    args["diff_mode"]?.should be_nil
  end

  it "builds the old-style key=value argv" do
    argv = Krikri::PythonModuleRunner.build_kv_argv({"path" => "/tmp/x", "mode" => "0640", "check_mode" => "false"})
    argv.should eq(["path=/tmp/x", "mode=0640"])
  end

  # ---- result-JSON extraction ----

  it "parses a single-line result JSON" do
    Krikri::PythonModuleRunner.parse_module_output(%({"changed": true, "msg": "ok"}))
      .try(&.["changed"]?.try(&.as_bool?)).should eq(true)
  end

  it "parses a pretty-printed result JSON preceded by other output" do
    out_text = "some warning on stderr-ish stdout\n" \
               "{\n  \"changed\": false,\n  \"msg\": \"done\"\n}\n"
    parsed = Krikri::PythonModuleRunner.parse_module_output(out_text)
    parsed.try(&.["msg"]?.try(&.as_s?)).should eq("done")
  end

  it "returns nil when no result JSON is present" do
    Krikri::PythonModuleRunner.parse_module_output("total garbage\nno json here").should be_nil
  end

  # ---- end-to-end through the plugin binary (local connection) ----

  it "runs an old-style module and parses its result" do
    pending("python3 not available") unless File.exists?("/usr/bin/python3")
    source = "#!/usr/bin/python\n" \
             "print('{\"changed\": true, \"msg\": \"ran\", \"custom_field\": 7}')\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"   => "testmod",
      "module_source" => Base64.strict_encode(source),
      "new_style"     => "false",
      "kv_argv"       => %q(["path=/tmp/x"]),
      "check_mode"    => "false",
    })
    result["changed"].as_bool.should be_true
    result["msg"].as_s.should eq("ran")
    result["custom_field"].as_i.should eq(7)
  end

  it "passes ANSIBLE_MODULE_ARGS to a new-style module via stdin, wrapped as real AnsibleModule expects" do
    pending("python3 not available") unless File.exists?("/usr/bin/python3")
    # Real ansible-core 2.19's basic.py (_debugging.load_params, the
    # path any module run outside the real AnsiballZ wrapper falls back
    # to) reads a JSON blob from STDIN shaped {"ANSIBLE_MODULE_ARGS":
    # {...}} - NOT an ANSIBLE_MODULE_ARGS environment variable, which
    # it doesn't read at all. The textual marker makes the runner treat
    # this as new-style.
    source = "# from ansible.module_utils.basic import AnsibleModule\n" \
             "import json, sys\n" \
             "args = json.loads(sys.stdin.read())['ANSIBLE_MODULE_ARGS']\n" \
             "print(json.dumps({'changed': False, 'msg': args.get('name', '')}))\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"   => "testmod_new",
      "module_source" => Base64.strict_encode(source),
      "new_style"     => "true",
      "module_args"   => %q({"name": "hello", "_ansible_check_mode": false}),
      "check_mode"    => "false",
    })
    result["msg"].as_s.should eq("hello")
    result["changed"].as_bool.should be_false
  end

  it "fails with the MODULE FAILURE shape when no result JSON is printed" do
    pending("python3 not available") unless File.exists?("/usr/bin/python3")
    source = "#!/usr/bin/python\nraise SystemExit('boom')\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"   => "testmod_fail",
      "module_source" => Base64.strict_encode(source),
      "new_style"     => "false",
      "kv_argv"       => "[]",
      "check_mode"    => "false",
    })
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("MODULE FAILURE")
    result["stderr"].as_s.should contain("boom")
  end
end
