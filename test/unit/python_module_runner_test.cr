require "../minitest_helper"
require "file_utils"
require "http/server"
require "../../src/krikri/python_module_runner"
# Single-file mode needs the runner's own dependencies spelled out
# (PythonFilterRunner, commit 1803a3e9; Krikri.non_string_scalar in
# param_sentinels.cr); the full-suite entrypoint has them all.
require "../../src/krikri/python_filter_runner"
require "../../src/krikri/param_sentinels"

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

  it "counts a collection module_utils import as new-style like ansible's modularizer" do
    # Real ansible-core's NEW_STYLE_PYTHON_MODULE_RE (module_common.py)
    # also matches `from|import
    # ansible_collections.<ns>.<coll>.plugins.module_utils...`, so a
    # library/ module built on amazon.aws' AnsibleAWSModule gets its
    # args as stdin JSON the same way an ansible.module_utils importer
    # does. Classifying it old-style shipped the args as argv instead,
    # which the module's AnsibleModule never reads - the task failed
    # with "missing required arguments: tags" for a dict arg it was
    # given (issue #955).
    Krikri::PythonModuleRunner.new_style?(
      %(from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule))
      .must_equal(true)
    Krikri::PythonModuleRunner.new_style?(
      %(import ansible_collections.community.general.plugins.module_utils.foo))
      .must_equal(true)
    # A namespace mention outside an import statement stays old-style.
    Krikri::PythonModuleRunner.new_style?(
      "#!/usr/bin/python\nNS = 'ansible_collections.ns.coll.plugins.module_utils'\nprint('{}')\n")
      .must_equal(false)
  end

  it "classifies a legacy INCLUDE-marker module as new-style and splices the import in" do
    # Ansible's modularizer (executor/module_common.py _find_module_utils)
    # gives a module carrying `#<<INCLUDE_ANSIBLE_MODULE_COMMON>>` the
    # same treatment as one importing module_utils directly: the marker
    # becomes `from ansible.module_utils.basic import *` and the module
    # is NEW-style. kunik.deploy-metadata's library/deployment_facts
    # relies on this - it calls AnsibleModule(argument_spec = dict())
    # without importing it - and this engine shipped the raw source, so
    # the module died with "name 'AnsibleModule' is not defined" while
    # ansible-playbook ran it fine (issue #543).
    source = "#!/usr/bin/python\n" \
             "#<<INCLUDE_ANSIBLE_MODULE_COMMON>>\n" \
             "module = AnsibleModule(argument_spec = dict())\n"
    Krikri::PythonModuleRunner.new_style?(source).must_equal(true)
    modularized = Krikri::PythonModuleRunner.modularize(source)
    modularized.includes?("from ansible.module_utils.basic import *").must_equal(true)
    modularized.includes?(Krikri::PythonModuleRunner::MODULE_COMMON_MARKER).must_equal(false)
    # A module without the marker passes through untouched.
    Krikri::PythonModuleRunner.modularize("#!/usr/bin/python\nprint('{}')\n")
      .must_equal("#!/usr/bin/python\nprint('{}')\n")
  end

  it "runs a legacy INCLUDE-marker module end-to-end after modularization" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The composed path the kunik.deploy-metadata fix rides on: the
    # marker is swapped for the import BEFORE the plugin sees the
    # source, so the module's AnsibleModule resolves - against real
    # ansible-core's basic.py when it's installed on the target, against
    # this engine's shim bundle when it isn't - and the module's own
    # exit_json reaches the result JSON (issue #543).
    source = "#!/usr/bin/python\n" \
             "#<<INCLUDE_ANSIBLE_MODULE_COMMON>>\n" \
             "module = AnsibleModule(argument_spec = dict())\n" \
             "result = {}\n" \
             "result['ansible_facts'] = {'deployment': {'timestamp': '20260101000000'}}\n" \
             "module.exit_json(**result)\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"         => "deployment_facts",
      "module_source"       => Base64.strict_encode(Krikri::PythonModuleRunner.modularize(source)),
      "new_style"           => "true",
      "module_args"         => "{}",
      "_ansible_check_mode" => "false",
    })
    result["failed"]?.must_be_nil
    result["ansible_facts"]["deployment"]["timestamp"].as_s.must_equal("20260101000000")
  end

  # ---- argument building ----

  it "re-types JSON-encoded params and adds the reserved _ansible keys" do
    args = JSON.parse(Krikri::PythonModuleRunner.build_module_args(
      {"name" => "x", "list" => %q(["a", "b"]), "count" => "3",
       "_ansible_check_mode" => "false", "_ansible_diff" => "false", "_verbosity" => "0"},
      check_mode: false, module_name: "kk_touch",
    ))
    args["name"].as_s.must_equal("x")
    args["list"].as_a.map(&.as_s).must_equal(["a", "b"])
    args["count"].as_i.must_equal(3)
    args["_ansible_check_mode"].as_bool.must_equal(false)
    # Ansible's action base names the invoked module in the args
    # (plugins/action/__init__.py) - the name real basic.py's messages,
    # including the check-mode skip, carry.
    args["_ansible_module_name"].as_s.must_equal("kk_touch")
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

  # Issue #696: a literal YAML list arg whose members include a
  # templated element travels the parser's comma-joined wire with
  # NON_STRING_MEMBER_PREFIX-marked non-string members. Real ansible
  # (2.19.11) hands the module a real list with typed members
  # (`r: ["{{ x }}", 1]` with an int x -> [5, 1]); the comma-joined text
  # used to ship AS the string, sentinel and all.
  it "reconstructs a comma-joined list arg with marked members as a typed array" do
    args = JSON.parse(Krikri::PythonModuleRunner.build_module_args(
      {"r"      => "5,#{Krikri::NON_STRING_MEMBER_PREFIX}1",
       "single" => "#{Krikri::NON_STRING_MEMBER_PREFIX}7"},
      check_mode: false, module_name: "argmod",
    ))
    args["r"].as_a.map(&.as_i?).must_equal([5, 1])
    # A single-element list (`r: [7]`) rides the member prefix as its
    # whole wire value and must still come back a list, not the scalar.
    args["single"].as_a.map(&.as_i?).must_equal([7])
  end

  it "keeps a plain comma-joined string arg a string" do
    args = JSON.parse(Krikri::PythonModuleRunner.build_module_args(
      {"r" => "5,1"}, check_mode: false, module_name: "argmod"))
    # No member marker -> indistinguishable on the strings-only wire
    # from a genuine string containing a comma; ansible-core keeps it a
    # str too (live-verified 2.19.11: `r: "5,1"` arrives "5,1").
    args["r"].as_s.must_equal("5,1")
  end

  it "strips member markers from an old-style module's argv" do
    argv = Krikri::PythonModuleRunner.build_kv_argv(
      {"r" => "5,#{Krikri::NON_STRING_MEMBER_PREFIX}1"})
    argv.must_equal(["r=5,1"])
  end

  # Integers wider than Int64 (issue #695): a container arg holding a
  # wide int must keep it (as a bigint marker the args serialization
  # unquotes into bare digits), not degrade the whole arg to a string -
  # and a string that merely LOOKS like digits is never touched.
  it "keeps a wide integer inside a container arg as a bigint" do
    two_pow_200 = (BigInt.new(2) ** 200).to_s
    wire = Krikri::PythonModuleRunner.build_module_args(
      {"d" => %({"n": #{two_pow_200}, "s": "123456789012345678901234567890"})},
      check_mode: false, module_name: "kk_touch",
    )
    # The serialized args the module receives carry the int as bare
    # digits - and the lookalike string stays QUOTED.
    wire.must_include(%("n":#{two_pow_200}))
    wire.must_include(%("s":"123456789012345678901234567890"))
  end

  it "parses a module result carrying integers wider than Int64 as marked bigints" do
    two_pow_200 = (BigInt.new(2) ** 200).to_s
    parsed = Krikri::PythonModuleRunner.parse_module_output(
      %({"changed": false, "wide": #{two_pow_200}, "neg": #{-(BigInt.new(2) ** 70)}, "s": "123456789012345678901234567890"}))
    parsed.try { |node| Krikri.bigint_digits(node["wide"]) }.must_equal(two_pow_200)
    parsed.try { |node| Krikri.bigint_digits(node["neg"]) }.must_equal((-(BigInt.new(2) ** 70)).to_s)
    parsed.try(&.["s"]?.try(&.as_s?)).must_equal("123456789012345678901234567890")
    parsed.try { |node| Krikri.bigint_digits(node["s"]) }.must_be_nil
  end

  # A BARE whole-span wide-int arg (`n: "{{ big_var }}"`) arrives here as
  # the MARKED string the executor re-marked (bigint_typed_param_text:
  # provenance from the span's structured evaluation - a marked string
  # there IS a wide int) and ships as the marked string; the serialized
  # args (and the action-plugin payload, which types its args the same
  # way) unquote into a bare Python int - issue #695: the module saw a
  # str where ansible passes an int. A LITERAL wide-digit string param -
  # the same bytes on the wire, but no marker - stays a STRING, the way
  # ansible-core keeps a quoted wide-digit YAML scalar a str.
  it "ships a marked wide-int arg bare and keeps a literal wide-digit arg a string" do
    two_pow_200 = (BigInt.new(2) ** 200).to_s
    marked = Krikri::PythonModuleRunner.typed_value(Krikri.bigint_sentinel(two_pow_200))
    Krikri.bigint_digits(marked).must_equal(two_pow_200)
    wire = Krikri::PythonModuleRunner.build_module_args(
      {"n" => Krikri.bigint_sentinel(two_pow_200)}, check_mode: false, module_name: "kk_touch")
    wire.must_include(%("n":#{two_pow_200}))

    # A literal wide-digit string param (and the small-int treatment):
    # the digit text itself never promotes - only the marker does.
    Krikri::PythonModuleRunner.typed_value(two_pow_200).as_s?.must_equal(two_pow_200)
    Krikri::PythonModuleRunner.typed_value("5").as_i?.must_equal(5)
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

  it "reports an uncaught module exception as Ansible's module-failure message" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # Ansible's AnsiballZ loader catches Exception and fails the task
    # with the exception's message; a raw run left only the traceback on
    # stderr and the MODULE FAILURE shape (linux-system-roles.nbde_server
    # raising TangAnsibleError, issue #555).
    source = "#!/usr/bin/python\nraise ValueError('boom')\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"         => "testmod_exc",
      "module_source"       => Base64.strict_encode(source),
      "new_style"           => "false",
      "kv_argv"             => "[]",
      "_ansible_check_mode" => "false",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed: boom")
    result["msg"].as_s.wont_include("MODULE FAILURE")
    # Real ansible renders the uncaught exception's block FLAT - the same
    # collapsed one-segment shape a plain fail_json gets, with no second
    # paragraph and no "<<< caused by >>>" section (live-verified vs 2.19,
    # issue #523) - so no chain-forcing marker is emitted.
    result["_ansible_module_exception"]?.must_be_nil
  end

  it "reports an uncaught exception with no message as Ansible's message-less module failure" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    source = "#!/usr/bin/python\nraise ValueError()\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"         => "testmod_exc_empty",
      "module_source"       => Base64.strict_encode(source),
      "new_style"           => "false",
      "kv_argv"             => "[]",
      "_ansible_check_mode" => "false",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Task failed: Module failed.")
    result["_ansible_module_exception"]?.must_be_nil
  end

  it "reports an uncaught ImportError module flat, without the caused-by marker" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # A top-level `import docker` on a host without the module dies with
    # ModuleNotFoundError before any result JSON: real ansible prints the
    # flat block (issue #523) - no "<<< caused by >>>" marker on the result.
    source = "#!/usr/bin/python\nimport krikri_no_such_module_523\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"         => "testmod_import",
      "module_source"       => Base64.strict_encode(source),
      "new_style"           => "false",
      "kv_argv"             => "[]",
      "_ansible_check_mode" => "false",
    })
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s
      .must_equal("Task failed: Module failed: No module named 'krikri_no_such_module_523'")
    result["_ansible_module_exception"]?.must_be_nil
  end

  # ---- uncaught-exception recovery from stderr ----

  it "extracts the FINAL exception's message from a chained traceback" do
    stderr = <<-STDERR
      Traceback (most recent call last):
        File "m.py", line 2, in <module>
          raise ValueError('inner')
      ValueError: inner

      During handling of the above exception, another exception occurred:

      Traceback (most recent call last):
        File "m.py", line 4, in <module>
          raise TangAnsibleError({'msg': 'Listing keys failed'})
      TangAnsibleError: {'msg': 'Listing keys failed'}
      STDERR
    Krikri::PythonModuleRunner.uncaught_exception_detail(stderr)
      .must_equal("{'msg': 'Listing keys failed'}")
  end

  it "joins an explicit direct-cause chain's messages, outer first" do
    # `raise MyErr('wrapped failure') from ValueError('inner')`: real
    # ansible's msg joins the direct-cause chain with ": " - "wrapped
    # failure: inner" - while the implicit-context chain below keeps only
    # the final message (issue #523).
    stderr = <<-STDERR
      Traceback (most recent call last):
        File "m.py", line 1, in <module>
          int('x')
      ValueError: invalid literal for int() with base 10: 'x'

      The above exception was the direct cause of the following exception:

      Traceback (most recent call last):
        File "m.py", line 3, in <module>
          raise MyErr('wrapped failure')
      MyErr: wrapped failure
      STDERR
    Krikri::PythonModuleRunner.uncaught_exception_detail(stderr)
      .must_equal("wrapped failure: invalid literal for int() with base 10: 'x'")
  end

  it "joins a cause constructed inline, which prints no traceback header" do
    # `raise MyErr('wrapped failure') from ValueError("int('x')")`: the
    # cause is CONSTRUCTED, never raised, so Python prints no
    # "Traceback (most recent call last):" header for its section - just
    # the bare message line before the direct-cause separator. Real
    # ansible still joins it into the msg (issue #523).
    stderr = <<-STDERR
      ValueError: invalid literal for int() with base 10: 'x'

      The above exception was the direct cause of the following exception:

      Traceback (most recent call last):
        File "m.py", line 2, in <module>
          raise MyErr('wrapped failure') from ValueError("int('x')")
      MyErr: wrapped failure
      STDERR
    Krikri::PythonModuleRunner.uncaught_exception_detail(stderr)
      .must_equal("wrapped failure: invalid literal for int() with base 10: 'x'")
  end

  it "joins several direct causes with the outermost first, deepest last" do
    stderr = <<-STDERR
      Traceback (most recent call last):
        File "m.py", line 1, in <module>
          int('x')
      ValueError: inner

      The above exception was the direct cause of the following exception:

      Traceback (most recent call last):
        File "m.py", line 3, in <module>
          raise MidErr('mid')
      MidErr: mid

      The above exception was the direct cause of the following exception:

      Traceback (most recent call last):
        File "m.py", line 5, in <module>
          raise OuterErr('outer')
      OuterErr: outer
      STDERR
    Krikri::PythonModuleRunner.uncaught_exception_detail(stderr)
      .must_equal("outer: mid: inner")
  end

  it "stops the cause chain at an implicit-context link" do
    # implicit context between the two deepest sections, direct cause
    # between mid and outer: only the direct-cause pair joins.
    stderr = <<-STDERR
      Traceback (most recent call last):
        File "m.py", line 1, in <module>
          int('x')
      ValueError: inner

      During handling of the above exception, another exception occurred:

      Traceback (most recent call last):
        File "m.py", line 3, in <module>
          raise MidErr('mid')
      MidErr: mid

      The above exception was the direct cause of the following exception:

      Traceback (most recent call last):
        File "m.py", line 5, in <module>
          raise OuterErr('outer')
      OuterErr: outer
      STDERR
    Krikri::PythonModuleRunner.uncaught_exception_detail(stderr)
      .must_equal("outer: mid")
  end

  it "joins a multi-line exception message's non-indented continuation lines" do
    stderr = <<-'STDERR'
      Traceback (most recent call last):
        File "m.py", line 1, in <module>
          raise ValueError('line1\\nline2')
      ValueError: line1
      line2
      STDERR
    Krikri::PythonModuleRunner.uncaught_exception_detail(stderr).must_equal("line1\nline2")
  end

  it "returns an empty string for an exception with no message" do
    stderr = <<-STDERR
      Traceback (most recent call last):
        File "m.py", line 1, in <module>
          raise ValueError()
      ValueError
      STDERR
    Krikri::PythonModuleRunner.uncaught_exception_detail(stderr).must_equal("")
  end

  it "returns nil for a BaseException that passes through Ansible's wrapper" do
    stderr = <<-STDERR
      Traceback (most recent call last):
        File "m.py", line 1, in <module>
          raise SystemExit('boom')
      SystemExit: boom
      STDERR
    Krikri::PythonModuleRunner.uncaught_exception_detail(stderr).must_be_nil
    Krikri::PythonModuleRunner.uncaught_exception_detail("no traceback here").must_be_nil
  end

  it "extracts the ErrorSummary chain's cause message from a real basic.py fail_json result" do
    result = JSON.parse(<<-JSON)
      {"rc": 2, "stdout": "", "stderr": "", "cmd": "rails db:migrate",
       "failed": true, "msg": "Error executing command.",
       "exception": {"event": {"msg": "Error executing command.",
         "chain": {"msg_reason": "<<< caused by >>>",
           "traceback_reason": "...",
           "event": {"msg": "[Errno 2] No such file or directory: b'rails'",
             "__ansible_type": "Event"},
           "follow": true, "__ansible_type": "EventChain"},
         "__ansible_type": "Event"},
         "__ansible_type": "ErrorSummary"},
       "invocation": {"module_args": {}}}
      JSON
    Krikri::PythonModuleRunner.error_exception_summary(result)
      .must_equal("[Errno 2] No such file or directory: b'rails'")
  end

  it "follows nested ErrorSummary chains to the deepest cause, joined in order" do
    result = JSON.parse(<<-JSON)
      {"failed": true, "msg": "outer",
       "exception": {"event": {"msg": "outer",
         "chain": {"event": {"msg": "middle",
           "chain": {"event": {"msg": "deepest", "__ansible_type": "Event"},
             "__ansible_type": "EventChain"},
           "__ansible_type": "Event"},
           "__ansible_type": "EventChain"},
         "__ansible_type": "Event"},
         "__ansible_type": "ErrorSummary"}}
      JSON
    Krikri::PythonModuleRunner.error_exception_summary(result).must_equal("middle: deepest")
  end

  it "returns nil for a plain-string exception result" do
    result = JSON.parse("{\"failed\": true, \"msg\": \"Module failed\", \"exception\": \"Traceback ...\"}")
    Krikri::PythonModuleRunner.error_exception_summary(result).must_be_nil
    Krikri::PythonModuleRunner.error_exception_summary(JSON.parse("{}")).must_be_nil
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

  it "shims ansible.module_utils.distro for role modules that import it" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The exact shape that hard-failed the whole role (bodsch.php's own
    # library/php_version.py and library/php_modules.py):
    # `from ansible.module_utils import distro` died with
    # "cannot import name 'distro' from 'ansible.module_utils'" on a
    # target without ansible-core, while ansible - which vendors
    # python-distro into every module payload - ran the same module.
    # The shim's linux_distribution tuple drives the role's own
    # package-manager branching, so the distribution id must reflect
    # the host's real /etc/os-release (the same file upstream
    # python-distro reads first), not a hardcoded value.
    work_dir = File.join(Dir.tempdir, "krikri-shim-distro-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "distro_probe_spec.py")
    File.write(module_path, "import json\n" \
                            "from ansible.module_utils import distro\n" \
                            "print(json.dumps({\n" \
                            "  'tuple': list(distro.linux_distribution(full_distribution_name=False)),\n" \
                            "  'named': list(distro.linux_distribution(full_distribution_name=True)),\n" \
                            "  'id': distro.id(),\n" \
                            "}))\n")
    stdout_io = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: Process::Redirect::Close, output: stdout_io, error: Process::Redirect::Close)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    parsed = JSON.parse(stdout_io.to_s)
    os_release_field = ->(key : String, downcase : Bool) {
      value = File.read("/etc/os-release")
        .each_line
        .select(&.includes?("="))
        .map { |line| line.strip.split("=", 2) }
        .find { |pair| pair[0] == key }
        .try { |pair| pair[1].strip.strip('"') }
      downcase ? value.try(&.downcase) : value
    }
    os_release_id = os_release_field.call("ID", true)
    parsed["id"].as_s.must_equal(os_release_id)
    parsed["tuple"][0].as_s.must_equal(os_release_id)
    parsed["tuple"][1].as_s.wont_equal("")
    parsed["tuple"].as_a.size.must_equal(3)
    # Upstream python-distro's linux_distribution(True) returns the
    # os-release NAME ("Ubuntu"), never PRETTY_NAME with the version
    # digits in it ("Ubuntu 22.04.4 LTS") - pin the shim to that.
    parsed["named"].as_a.size.must_equal(3)
    parsed["named"][0].as_s.must_equal(os_release_field.call("NAME", false))
    parsed["named"][0].as_s.wont_match(/\d/)
  end

  it "shims ansible.module_utils.urls for role modules that import open_url" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The exact shape that hard-failed kazoo-ansible.common's first task
    # (issue #826): its own library/publicip.py does
    # `from ansible.module_utils.urls import *` and calls open_url, and
    # died with "No module named 'ansible.module_utils.urls'" on a
    # target without ansible-core, while ansible - whose AnsiballZ
    # payload bundles the real urls.py - ran the same module past the
    # import. The bundle is written into the module's own directory and
    # the script dir is sys.path[0], so the shim shadows any installed
    # ansible-core - the test exercises the shim path deterministically
    # even on a host that has ansible-core. Served over a loopback HTTP
    # server so the test needs no outside network; open_url's .read()
    # must yield the body the way the real response does.
    work_dir = File.join(Dir.tempdir, "krikri-shim-urls-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    server = HTTP::Server.new do |ctx|
      ctx.response.print("1.2.3.4")
    end
    address = server.bind_tcp("127.0.0.1", 0)
    server_done = Channel(Nil).new
    spawn do
      server.listen
      server_done.send(nil)
    end
    begin
      module_path = File.join(work_dir, "publicip_spec.py")
      File.write(module_path, "import json\n" \
                              "from ansible.module_utils.urls import open_url\n" \
                              "response = open_url('http://127.0.0.1:#{address.port}/',\n" \
                              "  headers={'Metadata-Flavor': 'Google'}, timeout=5)\n" \
                              "body = response.read()\n" \
                              "print(json.dumps({'body': body.decode(), 'is_bytes': isinstance(body, bytes)}))\n")
      stdout_io = IO::Memory.new
      status = Process.run("/usr/bin/python3", [module_path],
        input: Process::Redirect::Close, output: stdout_io, error: Process::Redirect::Close)
      status.success?.must_equal(true)
      parsed = JSON.parse(stdout_io.to_s)
      parsed["body"].as_s.must_equal("1.2.3.4")
      parsed["is_bytes"].as_bool.must_equal(true)
    ensure
      server.close
      server_done.receive
    end
    FileUtils.rm_r(work_dir)
  end

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

  it "shim skips a module without supports_check_mode under check mode instead of running it" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # Real basic.py closes AnsibleModule.__init__ with the check-mode
    # gate: a module that never declared supports_check_mode exits with
    # skipped=True and never reaches its own body, so a --check run can
    # never make the module's real change (issue #693: the shim used to
    # run the body and the module made its change during the dry run).
    # The bundle is written into the module's own directory and the
    # script dir is sys.path[0], so the shim shadows any installed
    # ansible-core - the test exercises the shim path deterministically
    # even on a host that has ansible-core.
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    marker = File.join(work_dir, "marker")
    module_path = File.join(work_dir, "kk_touch.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "module = AnsibleModule(argument_spec={})\n" \
                            "open('#{marker}', 'w').write('created\\n')\n" \
                            "module.exit_json(changed=True, msg='touched marker')\n")
    stdout_io = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {"_ansible_check_mode": true}})),
      output: stdout_io, error: Process::Redirect::Close)
    status.success?.must_equal(true)
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed["skipped"].as_bool.must_equal(true)
    parsed["msg"].as_s.must_equal("remote module (kk_touch) does not support check mode")
    parsed["changed"].as_bool.must_equal(false)
    File.exists?(marker).must_equal(false)
    FileUtils.rm_r(work_dir)
  end

  it "shim still runs a module that declares supports_check_mode under check mode" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The gate only fires for modules that never opted in - a
    # check-mode-aware module keeps executing its own body under --check
    # and reports the change itself, the way real basic.py lets it.
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "kk_touch_ok.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "module = AnsibleModule(argument_spec={}, supports_check_mode=True)\n" \
                            "module.exit_json(changed=True, msg='touched marker')\n")
    stdout_io = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {"_ansible_check_mode": true}})),
      output: stdout_io, error: Process::Redirect::Close)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed["changed"].as_bool.must_equal(true)
    parsed["msg"].as_s.must_equal("touched marker")
    parsed.as_h.has_key?("skipped").must_equal(false)
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

  it "shim exposes AnsibleModule._diff for collection wrappers that copy it" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # amazon.aws' AnsibleAWSModule copies `self._module._diff` right
    # after constructing its AnsibleModule (real basic.py always
    # carries the PASS_VARS attribute). Without it a library/ module
    # built on AnsibleAWSModule died with "'AnsibleModule' object has
    # no attribute '_diff'" before it read the params the task passed
    # (issue #955).
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "dict_info_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "class AnsibleAWSModule:\n" \
                            "    def __init__(self, **kwargs):\n" \
                            "        self._module = AnsibleModule(**kwargs)\n" \
                            "        self._diff = self._module._diff\n" \
                            "    @property\n" \
                            "    def params(self):\n" \
                            "        return self._module.params\n" \
                            "    def exit_json(self, **kwargs):\n" \
                            "        self._module.exit_json(**kwargs)\n" \
                            "module = AnsibleAWSModule(argument_spec={'tags': {'type': 'dict', 'required': True}})\n" \
                            "module.exit_json(changed=False, got=module.params['tags'], diff=module._diff)\n")
    stdout_io = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {"tags": {"Name": "demo"}, "_ansible_diff": false}})),
      output: stdout_io, error: Process::Redirect::Close)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed["got"]["Name"].as_s.must_equal("demo")
    parsed["diff"].as_bool.must_equal(false)
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

  it "shim run_command ignores a missing cwd and fails like real basic.py on a missing binary" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The exact shape that died with a raw Python traceback on a target
    # without ansible-core (the manageiq role's run_command(['rails', ...],
    # cwd='/var/www/miq/vmdb') runs before that checkout exists, issue
    # #384): real basic.py runs with ignore_invalid_cwd=True - the
    # non-existent cwd is silently dropped instead of reaching Popen - and
    # its bytes argv make the Popen OSError fail_json with rc=errno,
    # empty stdout/stderr, the shlex-quoted cmd, and the exception str
    # composed into the task error header on the controller side (the
    # _ansible_error_exception transport the Crystal side reads).
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "run_command_cwd_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "module = AnsibleModule(argument_spec={})\n" \
                            "module.run_command(['definitely-not-a-binary-xyz'], cwd='/nonexistent/dir')\n")
    stdout_io = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      output: stdout_io, error: Process::Redirect::Close)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(false)
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed.wont_be_nil
    parsed["failed"].as_bool.must_equal(true)
    parsed["msg"].as_s.must_equal("Error executing command.")
    parsed["rc"].as_i.must_equal(2)
    parsed["cmd"].as_s.must_equal("definitely-not-a-binary-xyz")
    parsed["stdout"].as_s.must_equal("")
    parsed["stderr"].as_s.must_equal("")
    parsed["stdout_lines"].as_a.size.must_equal(0)
    parsed["stderr_lines"].as_a.size.must_equal(0)
    parsed.as_h.has_key?("changed").must_equal(false)
    parsed.as_h.has_key?("exception").must_equal(false)
    parsed["_ansible_error_exception"].as_s.must_equal(
      "[Errno 2] No such file or directory: b'definitely-not-a-binary-xyz'")
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

  it "shim exports env_fallback and applies an argument-spec env fallback" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The exact shape that hard-failed issue #752: a custom module imports
    # env_fallback in the same line as AnsibleModule and declares
    # fallback=(env_fallback, ['MY_REGION']) - real ansible's bundled
    # basic.py re-exports env_fallback and its validator applies the
    # fallback when the param wasn't passed (live-verified: MY_REGION set
    # prints r.region "us-east-1", unset prints null), while the shim
    # bundle had neither the name nor the fallback application, so the
    # import itself raised ImportError before any result JSON. The bundle
    # is written into the module's own directory and the script dir is
    # sys.path[0], so the shim resolves the imports even on a host WITH
    # ansible-core installed - the test exercises the shim path
    # deterministically either way.
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "envfb_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule, env_fallback\n" \
                            "module = AnsibleModule(argument_spec={'region': {'type': 'str',\n" \
                            "  'fallback': (env_fallback, ['MY_REGION'])}}, supports_check_mode=True)\n" \
                            "module.exit_json(changed=False, region=module.params['region'])\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    env = ENV.to_h.to_a.reject { |(key, _)| key == "MY_REGION" }.to_h
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      env: env.merge({"MY_REGION" => "us-east-1"}),
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    err.to_s.wont_include("ImportError")
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed["region"].as_s.must_equal("us-east-1")
  end

  it "shim leaves a not-found env fallback to the default and skips it for a passed param" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # Real runs set_fallbacks (common/parameters.py) BEFORE _set_defaults
    # inside ModuleArgumentSpecValidator: a fallback strategy that raises
    # AnsibleFallbackNotFound leaves the param to the default path
    # (live-verified: env unset prints r.region null), while an
    # explicitly passed value never consults the fallback at all - the
    # same precedence basic.py's own unsafe_writes spec relies on.
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "envfb_default_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule, env_fallback\n" \
                            "module = AnsibleModule(argument_spec={'region': {'type': 'str',\n" \
                            "  'default': 'spec-default', 'fallback': (env_fallback, ['MY_REGION'])}},\n" \
                            "  supports_check_mode=True)\n" \
                            "module.exit_json(changed=False, region=module.params['region'])\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    env = ENV.to_h.to_a.reject { |(key, _)| key == "MY_REGION" }.to_h
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      env: env,
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed["region"].as_s.must_equal("spec-default")
  end

  it "shim provides ansible.module_utils.common.dict_transformations for modules importing camel_dict_to_snake_dict" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # The exact shape that hard-failed issue #779: a custom module imports
    # camel_dict_to_snake_dict from
    # ansible.module_utils.common.dict_transformations at top level and
    # the shim bundle stood in for ansible-core - real ansible bundles
    # the file into the AnsiballZ payload and runs the module fine
    # (live-verified vs ansible-playbook), while the module died with
    # ModuleNotFoundError: No module named
    # 'ansible.module_utils.common.dict_transformations' before any
    # result JSON. The camel/snake round trip and the ARNs
    # pluralization case below are the semantics real's own
    # dict_transformations.py ships.
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "dict_trans_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "from ansible.module_utils.common.dict_transformations import camel_dict_to_snake_dict, snake_dict_to_camel_dict, dict_merge, recursive_diff\n" \
                            "snake = camel_dict_to_snake_dict({'FooBar': 1, 'TargetGroupARNs': [2], 'Sub': {'BazQux': 3}})\n" \
                            "camel = snake_dict_to_camel_dict({'foo_bar': 1}, capitalize_first=True)\n" \
                            "merged = dict_merge({'a': {'x': 1}}, {'a': {'y': 2}, 'b': 3})\n" \
                            "diffed = recursive_diff({'a': 1, 'b': 1}, {'b': 2, 'c': 3})\n" \
                            "module = AnsibleModule(argument_spec={})\n" \
                            "module.exit_json(changed=False, snake=snake, camel=camel, merged=merged, diffed=diffed)\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    err.to_s.wont_include("ModuleNotFoundError")
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed["snake"].as_h["foo_bar"].as_i.must_equal(1)
    parsed["snake"].as_h["sub"].as_h["baz_qux"].as_i.must_equal(3)
    parsed["snake"].as_h["target_group_arns"].as_a.size.must_equal(1)
    parsed["camel"].as_h["FooBar"].as_i.must_equal(1)
    parsed["merged"].as_h["a"].as_h["y"].as_i.must_equal(2)
    parsed["merged"].as_h["b"].as_i.must_equal(3)
    parsed["diffed"].as_a[0].as_h["a"].as_i.must_equal(1)
    parsed["diffed"].as_a[1].as_h["b"].as_i.must_equal(2)
    parsed["diffed"].as_a[1].as_h["c"].as_i.must_equal(3)
  end

  it "shim provides ansible.module_utils.parsing.convert_bool for modules importing boolean" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # Surveyed beside issue #779 (dict_transformations) as the other
    # small pure module_utils file a role-private module imports
    # directly that the shim bundle lacked: real ansible ships
    # BOOLEANS_TRUE/BOOLEANS_FALSE and boolean() in every payload, so a
    # module doing `from ansible.module_utils.parsing.convert_bool
    # import boolean` runs fine there and died with ModuleNotFoundError
    # here. strict=False falls back to False for an unrecognized value
    # the way real's converter does.
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "convert_bool_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "from ansible.module_utils.parsing.convert_bool import BOOLEANS_TRUE, boolean\n" \
                            "module = AnsibleModule(argument_spec={})\n" \
                            "module.exit_json(changed=False, yes=boolean('YES'), one=boolean(1),\n" \
                            "                 lenient=boolean('maybe', strict=False),\n" \
                            "                 truthy='y' in BOOLEANS_TRUE)\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    err.to_s.wont_include("ModuleNotFoundError")
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed["yes"].as_bool.must_equal(true)
    parsed["one"].as_bool.must_equal(true)
    parsed["lenient"].as_bool.must_equal(false)
    parsed["truthy"].as_bool.must_equal(true)
  end

  it "shim provides ansible.module_utils.ansible_release for modules importing __version__" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # Issue #843: amazon.aws' module_utils import ansible_release, so any
    # custom module built on them imports
    # `from ansible.module_utils.ansible_release import __version__`.
    # Real ansible bundles that file into the AnsiballZ payload, so it
    # resolves even where ansible-core is not installed for the module's
    # interpreter; the shim bundle stood in for ansible-core without the
    # file, so the import died with ModuleNotFoundError before any result
    # JSON. The value is the ansible-core release this engine targets -
    # the same one the `ansible_version` magic variable reports - so a
    # module gating on the version sees what it would under real
    # ansible-playbook of that release.
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "ansible_release_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "from ansible.module_utils.ansible_release import __version__, __author__, __codename__\n" \
                            "module = AnsibleModule(argument_spec={})\n" \
                            "module.exit_json(changed=False, version=__version__, author=__author__,\n" \
                            "                 codename=__codename__, has_version=bool(__version__))\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    err.to_s.wont_include("ModuleNotFoundError")
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed["has_version"].as_bool.must_equal(true)
    parsed["version"].as_s.must_equal(Krikri::ANSIBLE_TARGET_VERSION)
    parsed["author"].as_s.must_equal("Ansible, Inc.")
    parsed["codename"].as_s.must_equal("What Is and What Should Never Be")
  end

  it "shim provides ansible.module_utils.six for modules importing it" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # Issue #903's own repro: a custom module doing `from
    # ansible.module_utils.six import string_types`, the same import
    # amazon.aws' module_utils use. Real ansible bundles its vendored six
    # into the AnsiballZ payload, so it resolves even where ansible-core
    # isn't installed for the module's interpreter - and the shim bundle
    # (written for such a target, and unconditionally whenever a role
    # ships its own module_utils tree, where it also SHADOWS an installed
    # ansible-core) lacked it, failing the task with "No module named
    # 'ansible.module_utils.six'" where ansible-playbook reported ok=1.
    # six ships as a package because modules import its `six.moves`
    # submodules too, so both shapes are exercised.
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "six_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "from ansible.module_utils.six import string_types, text_type, binary_type, ensure_text\n" \
                            "from ansible.module_utils.six.moves import reduce\n" \
                            "from ansible.module_utils.six.moves.urllib.parse import urlparse\n" \
                            "import ansible.module_utils.six as six\n" \
                            "module = AnsibleModule(argument_spec={})\n" \
                            "module.exit_json(changed=False,\n" \
                            "                 is_str=isinstance('x', string_types),\n" \
                            "                 text=ensure_text(b'spec'),\n" \
                            "                 types_ok=(isinstance('x', text_type) and isinstance(b'x', binary_type)),\n" \
                            "                 items=sorted(six.iteritems({'a': 1})),\n" \
                            "                 reduced=reduce(lambda a, b: a + b, [1, 2]),\n" \
                            "                 path=urlparse('http://h/p').path,\n" \
                            "                 py3=six.PY3)\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    err.to_s.wont_include("ModuleNotFoundError")
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed["is_str"].as_bool.must_equal(true)
    parsed["text"].as_s.must_equal("spec")
    parsed["types_ok"].as_bool.must_equal(true)
    parsed["items"].as_a.map { |pair| pair.as_a[0].as_s }.must_equal(["a"])
    parsed["reduced"].as_i.must_equal(3)
    parsed["path"].as_s.must_equal("/p")
    parsed["py3"].as_bool.must_equal(true)
  end

  it "shim provides ansible.module_utils.common.warnings for modules importing warn" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    # Issue #908's own repro: a custom module importing warn from
    # ansible.module_utils.common.warnings. Real ansible ships that file in
    # the AnsiballZ payload and merges the recorded warning into the module
    # result, so the task is ok with a [WARNING]: hello line; the shim bundle
    # lacked the file, failing with ModuleNotFoundError. The shim records the
    # warning in a module-global store and basic.py pulls it into
    # result['warnings'] on exit_json, matching real's get_warnings() merge.
    work_dir = File.join(Dir.tempdir, "krikri-shim-spec-#{Random.rand(1_000_000)}")
    Dir.mkdir_p(work_dir)
    Krikri::PythonModuleRunner.write_module_utils_bundle(work_dir)
    module_path = File.join(work_dir, "warnings_spec.py")
    File.write(module_path, "from ansible.module_utils.basic import AnsibleModule\n" \
                            "from ansible.module_utils.common.warnings import warn, deprecate, get_warning_messages\n" \
                            "module = AnsibleModule(argument_spec={})\n" \
                            "warn('hello')\n" \
                            "deprecate('gone', version='2.0')\n" \
                            "recorded = get_warning_messages()\n" \
                            "module.exit_json(changed=False, recorded=list(recorded))\n")
    stdout_io = IO::Memory.new
    err = IO::Memory.new
    status = Process.run("/usr/bin/python3", [module_path],
      input: IO::Memory.new(%({"ANSIBLE_MODULE_ARGS": {}})),
      output: stdout_io, error: err)
    FileUtils.rm_r(work_dir)
    status.success?.must_equal(true)
    err.to_s.wont_include("ModuleNotFoundError")
    parsed = Krikri::PythonModuleRunner.parse_module_output(stdout_io.to_s).not_nil!
    parsed["recorded"].as_a.map { |v| v.as_s }.must_equal(["hello"])
    parsed["warnings"].as_a.map { |v| v.as_s }.must_equal(["hello"])
    parsed["warnings"].as_a[0].as_s.must_equal("hello")
  end

  # ---- collection imports on the module's PYTHONPATH (issue #692) ----

  it "maps collection roots to PYTHONPATH entries that expose ansible_collections" do
    # Real ansible never needs the collections importable where the module
    # runs - its AnsiballZ payload bundles collection module_utils - but
    # this runner executes the raw script, so the collection install
    # locations must land on PYTHONPATH instead. A root may name either a
    # collections ROOT (containing ansible_collections/) or a path pointing
    # directly AT an ansible_collections dir (the shape the
    # ansible-core-package scan produces); Python needs the parent of
    # ansible_collections either way, so both shapes must collapse to the
    # same entry, and roots without an actual tree behind them (the two
    # default locations CollectionIndex keeps even when absent) drop out.
    root = File.join(PluginSpecHelper.tmp_path("coll-import-roots"), "site-packages")
    Dir.mkdir_p(File.join(root, "ansible_collections", "testns", "coll"))
    roots = [
      root,
      File.join(root, "ansible_collections"),
      File.join(PluginSpecHelper.tmp_path("coll-import-roots"), "nowhere"),
    ]
    Krikri::PythonModuleRunner.collection_import_roots(roots).must_equal([root])
    FileUtils.rm_rf(File.join(PluginSpecHelper.tmp_path("coll-import-roots")))
  end

  it "runs a module importing ansible_collections.* module_utils via the collection roots on PYTHONPATH" do
    # The exact shape that hard-failed the issue #692 repro: a custom
    # library module importing a collection's module_utils
    # (`from ansible_collections.amazon.aws.plugins.module_utils.retries
    # import AWSRetry`) - ansible bundles that import into the payload and
    # runs the module ok, while the raw run here died with
    # "No module named 'ansible_collections...'" on a python the
    # collections were never installed into. The plugin gets the fixture
    # collection through ANSIBLE_COLLECTIONS_PATH only (its own env, no
    # process-wide mutation), which no python has on sys.path - the import
    # can only resolve through the PYTHONPATH the plugin now builds.
    skip("python3 not available") unless File.exists?("/usr/bin/python3")
    fixture_root = PluginSpecHelper.tmp_path("pymod-coll-path")
    mu = File.join(fixture_root, "ansible_collections", "testns", "coll", "plugins", "module_utils")
    Dir.mkdir_p(mu)
    File.write(File.join(mu, "marker.py"), "MARKER = 'fixture-value'\n")
    source = "#!/usr/bin/python\n" \
             "from ansible.module_utils.basic import AnsibleModule\n" \
             "from ansible_collections.testns.coll.plugins.module_utils.marker import MARKER\n" \
             "module = AnsibleModule(argument_spec={}, supports_check_mode=True)\n" \
             "module.exit_json(changed=False, msg=MARKER)\n"
    result = PluginSpecHelper.run("py_module", {
      "module_name"         => "kk_coll",
      "module_source"       => Base64.strict_encode(source),
      "new_style"           => "true",
      "module_args"         => %q({"_ansible_check_mode": false}),
      "_ansible_check_mode" => "false",
    }, env: {"ANSIBLE_COLLECTIONS_PATH" => fixture_root})
    expect(falsey?(result["failed"]?)).must_equal(true)
    result["msg"].as_s.must_equal("fixture-value")
  ensure
    FileUtils.rm_rf(fixture_root) if fixture_root
  end
end
