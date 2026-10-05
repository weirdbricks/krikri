require "../minitest_helper"
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
      .must_equal(path)
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
    Krikri::PythonModuleRunner.find_source("blivet", role, nil).must_equal(path)
    File.exists?(File.join(role, "files")).must_equal(false)
    FileUtils.rm_r(role)
  end

  it "resolves the short name of an FQCN module reference" do
    Krikri::PythonModuleRunner.short_name("linux_system_roles.sr_fingerprint").must_equal("sr_fingerprint")
    Krikri::PythonModuleRunner.short_name("sr_fingerprint").must_equal("sr_fingerprint")
  end

  it "finds a playbook-adjacent library module" do
    pb = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(pb)
    path = write_module(pb, "my_custom.py", "# test module")
    Krikri::PythonModuleRunner.find_source("my_custom", nil, pb).must_equal(path)
    FileUtils.rm_r(pb)
  end

  it "returns nil when no library source exists" do
    pb = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(pb)
    Krikri::PythonModuleRunner.find_source("no_such_module", nil, pb).must_be_nil
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
      .must_equal(role_path)
    FileUtils.rm_r(role)
    FileUtils.rm_r(pb)
  end

  it "finds a library module with a non-.py extension and never its .yml doc stub" do
    # Ansible's legacy module finder indexes every file in the
    # search dir by basename-minus-extension, excluding only its
    # MODULE_IGNORE_EXTS (.pyc/.pyo/... plus .yaml/.yml/.ini) - so
    # linux-system-roles.timesync's library/timesync_provider.sh IS its
    # timesync_provider module, with the timesync_provider.yml
    # DOCUMENTATION stub sitting beside it never shadowing the script.
    # Round 970350: ansible-playbook ran the .sh fine while this
    # engine - matching only .py or extensionless - found no source and
    # SKIPPED the "Determine current NTP provider" task.
    role = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    script = write_module(role, "timesync_provider.sh", "#!/bin/bash\n# WANT_JSON\n")
    write_module(role, "timesync_provider.yml", "DOCUMENTATION: stub\n")
    found = Krikri::PythonModuleRunner.find_source("timesync_provider", role, nil)
    found.must_equal(script)
    FileUtils.rm_r(role)
  end

  # ---- invocation-shape detection ----

  it "detects new-style modules by their ansible.module_utils import" do
    Krikri::PythonModuleRunner.new_style?(%(from ansible.module_utils.basic import AnsibleModule))
      .must_equal(true)
    Krikri::PythonModuleRunner.new_style?("#!/usr/bin/python\nimport json\nprint('{}')").must_equal(false)
  end

  # ---- argument building ----

  it "re-types JSON-encoded params and adds the reserved _ansible keys" do
    args = JSON.parse(Krikri::PythonModuleRunner.build_module_args(
      {"name" => "x", "list" => %q(["a", "b"]), "count" => "3",
       "_ansible_check_mode" => "false", "_ansible_diff" => "false", "_verbosity" => "0"},
      check_mode: false,
    ))
    args["name"].as_s.must_equal("x")
    args["list"].as_a.map(&.as_s).must_equal(["a", "b"])
    args["count"].as_i.must_equal(3)
    args["_ansible_check_mode"].as_bool.must_equal(false)
    # the plugin-config bookkeeping keys stay out of the module's args
    args["check_mode"]?.must_be_nil
    args["diff_mode"]?.must_be_nil
  end

  it "builds the old-style key=value argv" do
    # Ansible's old-style (non-AnsibleModule) protocol passes
    # _ansible_* special vars as ordinary key=value pairs in the argv
    # string - they are NOT stripped, unlike the plugin-config
    # bookkeeping keys (check_mode/diff_mode) checked above.
    argv = Krikri::PythonModuleRunner.build_kv_argv({"path" => "/tmp/x", "mode" => "0640", "_ansible_check_mode" => "false"})
    argv.must_equal(["path=/tmp/x", "mode=0640", "_ansible_check_mode=false"])
  end

  # ---- result-JSON extraction ----

  it "parses a single-line result JSON" do
    Krikri::PythonModuleRunner.parse_module_output(%({"changed": true, "msg": "ok"}))
      .try(&.["changed"]?.try(&.as_bool?)).must_equal(true)
  end

  it "parses a pretty-printed result JSON preceded by other output" do
    out_text = "some warning on stderr-ish stdout\n" \
               "{\n  \"changed\": false,\n  \"msg\": \"done\"\n}\n"
    parsed = Krikri::PythonModuleRunner.parse_module_output(out_text)
    parsed.try(&.["msg"]?.try(&.as_s?)).must_equal("done")
  end

  it "returns nil when no result JSON is present" do
    Krikri::PythonModuleRunner.parse_module_output("total garbage\nno json here").must_be_nil
  end

  # ---- end-to-end through the plugin binary (local connection) ----

  it "runs an old-style module and parses its result" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    source = "#!/usr/bin/python\n" \
             "print('{\"changed\": true, \"msg\": \"ran\", \"custom_field\": 7}')\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"         => "testmod",
      "module_source"       => Base64.strict_encode(source),
      "new_style"           => "false",
      "kv_argv"             => %q(["path=/tmp/x"]),
      "_ansible_check_mode" => "false",
    })
    result["changed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("ran")
    result["custom_field"].as_i.must_equal(7)
  end

  it "passes ANSIBLE_MODULE_ARGS to a new-style module via stdin, wrapped as AnsibleModule expects" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # ansible-core 2.19's basic.py (_debugging.load_params, the
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
      "module_name"         => "testmod_new",
      "module_source"       => Base64.strict_encode(source),
      "new_style"           => "true",
      "module_args"         => %q({"name": "hello", "_ansible_check_mode": false}),
      "_ansible_check_mode" => "false",
    })
    result["msg"].as_s.must_equal("hello")
    result["changed"].as_bool.must_equal(false)
  end

  it "runs a non-python (shell) module through its own shebang, with WANT_JSON args as one JSON argv" do
    skip("bash not available") unless File.exists?("/bin/bash")
    # linux-system-roles.timesync's library/timesync_provider.sh shape:
    # a #!/bin/bash WANT_JSON module used to be executed as
    # `python3 <module>.py` (dying on bash syntax) because the runner
    # hardcoded python3. Ansible runs the module through its own
    # shebang and hands a WANT_JSON module its whole argument dict as a
    # single serialized-JSON argv element.
    source = "#!/bin/bash\n" \
             "# WANT_JSON\n" \
             "name=$(echo \"$1\" | sed -n 's/.*\"name\": *\"\\([^\"]*\\)\".*/\\1/p')\n" \
             "printf '{\"changed\": false, \"msg\": \"%s\"}' \"$name\"\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"         => "testmod_sh",
      "module_source"       => Base64.strict_encode(source),
      "new_style"           => "false",
      "module_args"         => %q({"name": "hello"}),
      "kv_argv"             => "[]",
      "_ansible_check_mode" => "false",
    })
    expect(falsey?(result["failed"]?)).must_equal(true)
    result["msg"].as_s.must_equal("hello")
  end

  it "fails with the MODULE FAILURE shape when no result JSON is printed" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    source = "#!/usr/bin/python\nraise SystemExit('boom')\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"         => "testmod_fail",
      "module_source"       => Base64.strict_encode(source),
      "new_style"           => "false",
      "kv_argv"             => "[]",
      "_ansible_check_mode" => "false",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("MODULE FAILURE")
    result["stderr"].as_s.must_include("boom")
  end

  # ---- role's own module_utils package collection ----

  it "collects a role's own module_utils package tree, relative paths first" do
    role = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(role, "module_utils", "my_custom_pkg"))
    init = File.join(role, "module_utils", "my_custom_pkg", "__init__.py")
    helper = File.join(role, "module_utils", "my_custom_pkg", "helper.py")
    File.write(init, "")
    File.write(helper, "def my_function():\n    return 'bundled'\n")
    collected = Krikri::PythonModuleRunner.collect_module_utils_files(role, nil)
    collected.keys.must_equal(["my_custom_pkg/__init__.py", "my_custom_pkg/helper.py"])
    collected["my_custom_pkg/helper.py"].must_equal(helper)
    FileUtils.rm_r(role)
  end

  it "collects nothing (empty hash) for a role with no module_utils directory" do
    role = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(role)
    write_module(role, "plain.py", "# test module")
    Krikri::PythonModuleRunner.collect_module_utils_files(role, nil).must_be_empty
    FileUtils.rm_r(role)
  end

  it "collects playbook-adjacent module_utils and lets the role tree shadow it" do
    role = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    pb = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(role, "module_utils", "pkg"))
    Dir.mkdir_p(File.join(pb, "module_utils", "pkg"))
    File.write(File.join(role, "module_utils", "pkg", "a.py"), "# role\n")
    File.write(File.join(pb, "module_utils", "pkg", "b.py"), "# playbook\n")
    File.write(File.join(pb, "module_utils", "pkg", "a.py"), "# playbook a\n")
    collected = Krikri::PythonModuleRunner.collect_module_utils_files(role, pb)
    collected.has_key?("pkg/b.py").must_equal(true)
    # nearest-first: the role's own pkg/a.py shadows the playbook's
    collected["pkg/a.py"].must_equal(File.join(role, "module_utils", "pkg", "a.py"))
    FileUtils.rm_r(role)
    FileUtils.rm_r(pb)
  end

  it "skips compiled .pyc/.pyo caches when collecting module_utils files" do
    role = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(role, "module_utils", "pkg"))
    File.write(File.join(role, "module_utils", "pkg", "a.py"), "# src\n")
    File.write(File.join(role, "module_utils", "pkg", "a.cpython-311.pyc"), "junk")
    collected = Krikri::PythonModuleRunner.collect_module_utils_files(role, nil)
    collected.keys.must_equal(["pkg/a.py"])
    FileUtils.rm_r(role)
  end

  # ---- end-to-end through the plugin binary (local connection): the
  # ---- role's own module_utils package staged under ansible/module_utils ----

  it "stages a role's own module_utils package so its import resolves end to end" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    role = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(role, "module_utils", "my_custom_pkg"))
    File.write(File.join(role, "module_utils", "my_custom_pkg", "__init__.py"), "")
    File.write(File.join(role, "module_utils", "my_custom_pkg", "helper.py"),
      "def my_function():\n    return 'bundled-value'\n")
    collected = Krikri::PythonModuleRunner.collect_module_utils_files(role, nil)
    files_json = collected.to_a.map { |rel, path| {rel, Base64.strict_encode(File.read(path))} }.to_h.to_json
    # The exact shape the task names: a role-private module importing its
    # OWN custom ansible.module_utils package
    # (linux-system-roles.storage's blivet.py ->
    # ansible.module_utils.storage_lsr.argument_validator shape).
    source = "from ansible.module_utils.basic import AnsibleModule\n" \
             "from ansible.module_utils.my_custom_pkg.helper import my_function\n" \
             "module = AnsibleModule(argument_spec={})\n" \
             "module.exit_json(changed=False, value=my_function())\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"         => "mymod_utils",
      "module_source"       => Base64.strict_encode(source),
      "new_style"           => "true",
      "module_args"         => %q({"_ansible_check_mode": false}),
      "module_utils_files"  => files_json,
      "_ansible_check_mode" => "false",
    })
    expect(falsey?(result["failed"]?)).must_equal(true)
    result["value"].as_s.must_equal("bundled-value")
  ensure
    FileUtils.rm_rf(role) if role
  end

  it "stages the module_utils bundle skeleton alongside role packages so basic.py still imports" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # With role module_utils staged, the work-dir-local `ansible` package
    # shadows any installed ansible-core (a regular package in the
    # script's sys.path[0] dir wins) - so the standard basic.py shim must
    # be written too, or every role-module_utils invocation would trade
    # one ModuleNotFoundError for another.
    role = File.join(Dir.tempdir, "krikri-pymod-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(File.join(role, "module_utils", "pkg"))
    File.write(File.join(role, "module_utils", "pkg", "x.py"), "X = 1\n")
    files_json = Krikri::PythonModuleRunner.collect_module_utils_files(role, nil)
      .to_a.map { |rel, path| {rel, Base64.strict_encode(File.read(path))} }.to_h.to_json
    source = "from ansible.module_utils.basic import AnsibleModule\n" \
             "from ansible.module_utils.pkg.x import X\n" \
             "module = AnsibleModule(argument_spec={'v': {'type': 'int', 'required': True}})\n" \
             "module.exit_json(changed=False, total=module.params['v'] + X)\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"         => "mymod_mixed",
      "module_source"       => Base64.strict_encode(source),
      "new_style"           => "true",
      "module_args"         => %q({"v": 41, "_ansible_check_mode": false}),
      "module_utils_files"  => files_json,
      "_ansible_check_mode" => "false",
    })
    expect(falsey?(result["failed"]?)).must_equal(true)
    result["total"].as_i.must_equal(42)
  ensure
    FileUtils.rm_rf(role) if role
  end

  # ---- the basic.py shim (targets without ansible-core) ----

  it "shims ansible.module_utils.basic for a new-style module on a target without ansible-core" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The exact shape that hard-failed on every fresh target
    # (newrelic.newrelic-infra's own library/merge_yaml.py): a new-style
    # module whose `from ansible.module_utils.basic import
    # AnsibleModule` import dies with ModuleNotFoundError when
    # ansible-core isn't installed. The bundle is written into the
    # module's own directory, and the script dir is sys.path[0], so the
    # shim resolves the import even on a controller WITH ansible-core
    # installed - the same shadowing the plugin relies on.
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "merge_yaml_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "module = AnsibleModule(argument_spec={'value': {'type': 'dict', 'required': True},\n" \
                            "  'create': {'type': 'bool', 'default': True}}, supports_check_mode=True)\n" \
                            "module.exit_json(changed=True, merged=module.params['value'], create=module.params['create'])\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {"value": {"a": 1}, "create": false}})),
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed.wont_be_nil
    parsed["changed"].as_bool.must_equal(true)
    parsed["merged"].as_h["a"].as_i.must_equal(1)
    parsed["create"].as_bool.must_equal(false)
  end

  it "shim fails a missing required argument through fail_json like real basic.py" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "merge_yaml_spec_req.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "module = AnsibleModule(argument_spec={'value': {'type': 'dict', 'required': True}})\n" \
                            "module.exit_json(changed=False)\n")
    stdout_io = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      output: stdout_io, error: Process::Redirect::Close)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(false)
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed.wont_be_nil
    parsed["failed"].as_bool.must_equal(true)
    parsed["msg"].as_s.must_include("missing required arguments")
  end

  it "shim supports AnsibleModule.log() for role-private modules that call it" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The exact shape that AttributeError'd on every fresh target
    # (linux-system-roles.firewall/.kdump's own library/sr_fingerprint.py,
    # whose main() calls module.log(log_message)): real basic.py logs to
    # syslog/journal with the ident 'ansible-<module_name>' and never
    # fails the module over it.
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "sr_fingerprint.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "module = AnsibleModule(argument_spec={'value': {'type': 'str', 'required': True}})\n" \
                            "module.log('fingerprinting value %s' % module.params['value'])\n" \
                            "module.log(b'bytes message too')\n" \
                            "module.exit_json(changed=False, logged=True)\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {"value": "abc"}})),
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    err.to_s.wont_include("AttributeError")
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed.wont_be_nil
    parsed.as_h.has_key?("failed").must_equal(false)
    parsed["logged"].as_bool.must_equal(true)
  end

  it "shim supports AnsibleModule.get_bin_path for role-private modules that call it" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The exact shape that AttributeError'd on a real host
    # (linux-system-roles.systemd's own library/systemd_units.py, whose
    # units() calls self.module.get_bin_path("systemctl",
    # opt_dirs=[...]) before anything can exit_json - so the module
    # printed no result JSON and the task hard-FAILED while
    # ansible-playbook succeeded).
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "systemd_units.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "module = AnsibleModule(argument_spec={'user': {'type': 'str', 'default': 'root'}})\n" \
                            "bin = module.get_bin_path('python3', opt_dirs=['/nowhere'])\n" \
                            "found = bool(bin)\n" \
                            "opt = module.get_bin_path('definitely-missing-bin-xyz', opt_dirs=['/nowhere']) if False else None\n" \
                            "try:\n" \
                            "    module.get_bin_path('definitely-missing-bin-xyz', opt_dirs=['/nowhere'])\n" \
                            "    raised = False\n" \
                            "except ValueError:\n" \
                            "    raised = True\n" \
                            "module.exit_json(changed=False, found=found, missing_raises_valueerror=raised)\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    err.to_s.wont_include("AttributeError")
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed.wont_be_nil
    parsed["found"].as_bool.must_equal(true)
    parsed["missing_raises_valueerror"].as_bool.must_equal(true)
  end

  it "shim provides ansible.module_utils._text for modules importing to_native" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The exact shape that ModuleNotFoundError'd at import time on a
    # fresh Atlantic host (linux-system-roles.nbde_server's own
    # library/nbde_server_tang.py, which does `from
    # ansible.module_utils._text import to_native` at module top level
    # - before AnsibleModule is ever constructed, so nothing could
    # exit_json and the module printed no result JSON while
    # ansible-playbook succeeded).
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "nbde_server_tang_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "from ansible.module_utils._text import to_native, to_bytes\n" \
                            "native = to_native(Exception('boom'))\n" \
                            "back = to_native(to_bytes('caf\\u00e9'))\n" \
                            "module = AnsibleModule(argument_spec={})\n" \
                            "module.exit_json(changed=False, native=native, roundtrip=back)\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    err.to_s.wont_include("ModuleNotFoundError")
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed.wont_be_nil
    parsed["native"].as_s.must_include("boom")
    parsed["roundtrip"].as_s.must_equal("café")
  end

  it "shim provides ansible.module_utils.common.text.converters for modules importing to_native" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The exact shape that ModuleNotFoundError'd at import time on a
    # fresh Atlantic host (bodsch.users' own library/multi_users.py,
    # round 813275, which does `from
    # ansible.module_utils.common.text.converters import to_native` at
    # module top level - the modern ansible-core path that real _text.py
    # is itself just a deprecated re-export of). Without a
    # common/text/converters.py in the shim bundle the import dies with
    # ModuleNotFoundError: No module named 'ansible.module_utils.common',
    # before AnsibleModule is ever constructed, so the module printed no
    # result JSON while ansible-playbook succeeded (ok=8/failed=0
    # there vs ok=6/failed=1 here).
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "multi_users_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "from ansible.module_utils.common.text.converters import to_native, to_bytes\n" \
                            "native = to_native(Exception('boom'))\n" \
                            "back = to_native(to_bytes('caf\\u00e9'))\n" \
                            "module = AnsibleModule(argument_spec={})\n" \
                            "module.exit_json(changed=False, native=native, roundtrip=back)\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    err.to_s.wont_include("ModuleNotFoundError")
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed.wont_be_nil
    parsed["native"].as_s.must_include("boom")
    parsed["roundtrip"].as_s.must_equal("café")
  end
end
