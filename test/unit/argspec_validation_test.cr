require "../minitest_helper"
require "../../src/krikri/argspec_validator"
require "../../src/krikri/task_executor/output_routing"
require "../../src/krikri/playbook_parser"
require "../../src/krikri/task_executor/result_display"

# Data-driven module argument validation (ArgspecValidator + the generated
# data/argspecs.json table). Every expected message below was captured from
# a real ansible-playbook 2.19.11 run of the same typo'd task on this
# machine (non-tty, ANSIBLE_NOCOLOR=1) - see scripts/gen_print_names.py for
# the probing harness and the sample differential run in the round notes.
describe Krikri::ArgspecValidator do
  # A "vars context" with the service/pkg facts the fact-delegating
  # modules (service/package) resolve their spec target from.
  private def vars(facts = {} of String => JSON::Any)
    base = {"ansible_connection" => JSON::Any.new("local")} of String => JSON::Any
    facts.each { |k, v| base[k] = v }
    base
  end

  it "rejects an unknown option with real's exact lineinfile wording (bare spelling)" do
    failure = Krikri::ArgspecValidator.validate(
      "lineinfile", "ansible.builtin.lineinfile",
      {"path" => "/tmp/x", "bakcrefs" => "true"}, vars)
    failure.wont_be_nil
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (lineinfile) module: bakcrefs. " \
      "Supported parameters include: attributes, backrefs, backup, create, firstmatch, " \
      "group, insertafter, insertbefore, line, mode, owner, path, regexp, search_string, " \
      "selevel, serole, setype, seuser, state, unsafe_writes, validate " \
      "(attr, dest, destfile, name, regex, value).")
    failure.not_nil!.action_level?.must_equal(false)
  end

  it "echoes the FQCN spelling the task used, not the resolved one" do
    failure = Krikri::ArgspecValidator.validate(
      "ansible.builtin.lineinfile", "ansible.builtin.lineinfile",
      {"path" => "/tmp/x", "bakcrefs" => "true"}, vars)
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (ansible.builtin.lineinfile) module: bakcrefs. " \
      "Supported parameters include: attributes, backrefs, backup, create, firstmatch, " \
      "group, insertafter, insertbefore, line, mode, owner, path, regexp, search_string, " \
      "selevel, serole, setype, seuser, state, unsafe_writes, validate " \
      "(attr, dest, destfile, name, regex, value).")
  end

  it "validates template against copy's spec under real's ansible.legacy.copy name" do
    failure = Krikri::ArgspecValidator.validate(
      "template", "ansible.builtin.template",
      {"src" => "t.j2", "dest" => "/tmp/x", "mdoe" => "0644"}, vars)
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (ansible.legacy.copy) module: mdoe. " \
      "Supported parameters include: _original_basename, attributes, backup, checksum, " \
      "content, dest, directory_mode, follow, force, group, local_follow, mode, owner, " \
      "remote_src, selevel, serole, setype, seuser, src, unsafe_writes, validate (attr).")
  end

  it "does not flag template's Jinja-rendering knobs (the action consumes them)" do
    failure = Krikri::ArgspecValidator.validate(
      "template", "ansible.builtin.template",
      {"src" => "t.j2", "dest" => "/tmp/x", "newline_sequence" => "\\n", "trim_blocks" => "true",
       "output_encoding" => "utf-8"}, vars)
    failure.must_be_nil
  end

  it "names every unsupported key, sorted, for multiple offenders (real wording)" do
    failure = Krikri::ArgspecValidator.validate(
      "copy", "ansible.builtin.copy",
      {"content" => "hi", "dest" => "/tmp/x", "mdoe" => "0644", "vaildate" => "/bin/true %s"}, vars)
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (ansible.legacy.copy) module: mdoe, vaildate. " \
      "Supported parameters include: _original_basename, attributes, backup, checksum, " \
      "content, dest, directory_mode, follow, force, group, local_follow, mode, owner, " \
      "remote_src, selevel, serole, setype, seuser, src, unsafe_writes, validate (attr).")
  end

  it "accepts every documented parameter including aliases" do
    failure = Krikri::ArgspecValidator.validate(
      "file", "ansible.builtin.file",
      {"path" => "/tmp/x", "state" => "touch", "attr" => "i", "name" => "/tmp/x"}, vars)
    failure.must_be_nil
  end

  it "reports missing required arguments ahead of unsupported params (real priority)" do
    failure = Krikri::ArgspecValidator.validate(
      "file", "ansible.builtin.file", {"boguss" => "1"}, vars)
    failure.not_nil!.msg.must_equal("missing required arguments: path")
  end

  it "lists multiple missing required arguments sorted" do
    failure = Krikri::ArgspecValidator.validate(
      "dpkg_selections", "ansible.builtin.dpkg_selections", {"zz" => "1"}, vars)
    failure.not_nil!.msg.must_equal("missing required arguments: name, selection")
  end

  it "emits real's exact bool-conversion failure wording" do
    failure = Krikri::ArgspecValidator.validate(
      "lineinfile", "ansible.builtin.lineinfile",
      {"path" => "/tmp/x", "create" => "notabool"}, vars)
    failure.not_nil!.msg.must_equal(
      "argument 'create' is of type str and we were unable to convert to bool: " \
      "The value 'notabool' is not a valid boolean. Valid booleans include: " \
      "'off', 1, 'true', 'y', 0, 'false', 'on', 'no', '1', 'yes', '0', 'n', 'f', 't'")
  end

  it "emits real's exact int-conversion failure wording" do
    failure = Krikri::ArgspecValidator.validate(
      "apt", "ansible.builtin.apt",
      {"name" => "x", "lock_timeout" => "abc"}, vars)
    failure.not_nil!.msg.must_equal(
      "argument 'lock_timeout' is of type str and we were unable to convert to int: " \
      "\"'abc'\" cannot be converted to an int")
  end

  it "accepts integer-looking strings and fractional zeros for int options" do
    Krikri::ArgspecValidator.validate(
      "apt", "ansible.builtin.apt", {"name" => "x", "lock_timeout" => "60"}, vars
    ).must_be_nil
    Krikri::ArgspecValidator.validate(
      "apt", "ansible.builtin.apt", {"name" => "x", "lock_timeout" => "1.0"}, vars
    ).must_be_nil
  end

  it "emits real's exact invalid-choices wording, in the spec's own order" do
    failure = Krikri::ArgspecValidator.validate(
      "lineinfile", "ansible.builtin.lineinfile",
      {"path" => "/tmp/x", "state" => "bogus"}, vars)
    failure.not_nil!.msg.must_equal("value of state must be one of: absent, present, got: bogus")

    failure = Krikri::ArgspecValidator.validate(
      "async_status", "ansible.builtin.async_status",
      {"jid" => "123", "mode" => "bogus"}, vars)
    failure.not_nil!.msg.must_equal("value of mode must be one of: status, cleanup, got: bogus")
  end

  it "enforces mutually exclusive options with real's pipe-joined wording" do
    failure = Krikri::ArgspecValidator.validate(
      "lineinfile", "ansible.builtin.lineinfile",
      {"path" => "/tmp/x", "insertbefore" => "a", "insertafter" => "b", "line" => "x"}, vars)
    failure.not_nil!.msg.must_equal("parameters are mutually exclusive: insertbefore|insertafter")
  end

  it "enforces required_one_of with real's wording" do
    failure = Krikri::ArgspecValidator.validate(
      "pip", "ansible.builtin.pip", {"zz" => "1"}, vars)
    failure.not_nil!.msg.must_equal("one of the following is required: name, requirements")
  end

  it "enforces required_if against spec defaults with real's wording" do
    failure = Krikri::ArgspecValidator.validate(
      "iptables", "ansible.builtin.iptables", {"zz" => "1"}, vars)
    failure.not_nil!.msg.must_equal(
      "flush is False but all of the following are missing: chain")
  end

  it "treats an explicit null as present-but-skipped for optional options" do
    failure = Krikri::ArgspecValidator.validate(
      "lineinfile", "ansible.builtin.lineinfile",
      {"path" => "/tmp/x", "line" => Krikri::NONE_SENTINEL}, vars)
    failure.must_be_nil
  end

  it "skips engine-internal wire keys entirely" do
    failure = Krikri::ArgspecValidator.validate(
      "lineinfile", "ansible.builtin.lineinfile",
      {"path" => "/tmp/x", "_environment" => "{}", "__original_src_basename" => "x",
       "_ansible_check_mode" => "false"}, vars)
    failure.must_be_nil
  end

  it "validates action-only directives with real's action-level wording" do
    failure = Krikri::ArgspecValidator.validate(
      "debug", "ansible.builtin.debug", {"zz" => "1"}, vars)
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (debug) module: zz. " \
      "Supported parameters include: msg, var, verbosity.")
    failure.not_nil!.action_level?.must_equal(true)
    failure.not_nil!.omit_changed?.must_equal(true)
  end

  it "uses real's Invalid-options wording for fail/group_by/wait_for_connection" do
    failure = Krikri::ArgspecValidator.validate(
      "fail", "ansible.builtin.fail", {"zz" => "1"}, vars)
    failure.not_nil!.msg.must_equal("Invalid options for fail: zz")
    failure.not_nil!.action_level?.must_equal(true)
  end

  it "accepts the options fail/group_by/wait_for_connection really take and lists only the unknown ones" do
    # verified vs real ansible-core 2.19.11: valid names are never in the list
    Krikri::ArgspecValidator.validate(
      "fail", "ansible.builtin.fail", {"msg" => "x"}, vars).must_be_nil
    Krikri::ArgspecValidator.validate(
      "group_by", "ansible.builtin.group_by", {"key" => "x", "parents" => "y"}, vars).must_be_nil
    Krikri::ArgspecValidator.validate(
      "wait_for_connection", "ansible.builtin.wait_for_connection",
      {"connect_timeout" => "1", "delay" => "0", "sleep" => "1", "timeout" => "2"}, vars).must_be_nil

    failure = Krikri::ArgspecValidator.validate(
      "fail", "ansible.builtin.fail", {"msg" => "x", "bogus" => "1", "aaa" => "2"}, vars)
    failure.not_nil!.msg.must_equal("Invalid options for fail: aaa,bogus")
  end

  it "runs script's action-plugin spec including its required_one_of" do
    failure = Krikri::ArgspecValidator.validate(
      "script", "ansible.builtin.script", {"zz" => "1"}, vars)
    failure.not_nil!.msg.must_equal("one of the following is required: _raw_params, cmd")
    failure.not_nil!.action_level?.must_equal(true)
  end

  it "delegates service validation to the service_mgr module's spec" do
    failure = Krikri::ArgspecValidator.validate(
      "service", "ansible.builtin.service",
      {"name" => "ssh", "state" => "reloaded", "zz" => "1"},
      vars({"ansible_service_mgr" => JSON::Any.new("systemd")}))
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (ansible.legacy.systemd) module: zz. " \
      "Supported parameters include: daemon_reexec, daemon_reload, enabled, force, " \
      "masked, name, no_block, scope, state (daemon-reexec, daemon-reload, service, unit).")
  end

  it "validates service against its own spec for a non-systemd manager (real gathers the fact on demand)" do
    failure = Krikri::ArgspecValidator.validate(
      "service", "ansible.builtin.service", {"name" => "ssh", "state" => "started", "zz" => "1"},
      {"ansible_service_mgr" => JSON::Any.new("sysvinit")})
    failure.not_nil!.msg.starts_with?("Unsupported parameters for (ansible.legacy.service) module: zz.").must_equal(true)
  end

  it "never validates the modules real does not validate" do
    {"ansible.builtin.fetch"     => {"src" => "/etc/hostname", "dest" => "/tmp/x", "zz" => "1"},
     "ansible.builtin.set_fact"  => {"zz" => "1"},
     "ansible.builtin.reboot"    => {"zz" => "1"},
     "ansible.builtin.yum"       => {"name" => "x", "zz" => "1"},
     "ansible.builtin.dnf"       => {"name" => "x", "zz" => "1"},
     "ansible.builtin.py_module" => {"zz" => "1"},
    }.each do |module_name, params|
      Krikri::ArgspecValidator.validate(module_name, module_name, params, vars).must_be_nil
    end
  end

  it "returns nil for modules with no spec entry at all" do
    Krikri::ArgspecValidator.validate(
      "some_library_module", "some_library_module", {"zz" => "1"}, vars
    ).must_be_nil
  end

  it "classifies failure chain shapes for ResultDisplay's error blocks" do
    Krikri::ArgspecValidator.failure_kind?(
      "ansible.builtin.lineinfile",
      "Unsupported parameters for (lineinfile) module: x. Supported parameters include: path."
    ).must_equal(:module)
    # template's usual file-not-found handling chain must NOT swallow a
    # validation failure - real prints the collapsed Module-failed chain.
    Krikri::ArgspecValidator.failure_kind?(
      "ansible.builtin.template",
      "Unsupported parameters for (ansible.legacy.copy) module: mdoe. Supported parameters include: dest."
    ).must_equal(:module)
    Krikri::ArgspecValidator.failure_kind?(
      "ansible.builtin.fail", "Invalid options for fail: zz"
    ).must_equal(:action)
    # Not one of our validation messages, or no table entry: no override.
    Krikri::ArgspecValidator.failure_kind?(
      "ansible.builtin.template", "Could not find or access 'x' on the Ansible Controller."
    ).must_be_nil
    Krikri::ArgspecValidator.failure_kind?(
      "some_library_module", "Unsupported parameters for (some_library_module) module: x."
    ).must_be_nil
  end
end

# End-to-end display shape: a validation failure flowing through
# ResultDisplay produces real ansible-playbook's [ERROR] block (chain
# shape included) and the single-line fatal dump. Expectations captured
# from real ansible-playbook 2.19.11 runs of the same tasks.
describe "argspec validation display shapes" do
  private def capture_output(&)
    io = IO::Memory.new
    Krikri::OutputRouting.redirect_current_fiber_to(io)
    begin
      yield
    ensure
      Krikri::OutputRouting.clear_current_fiber_redirect
    end
    io.to_s
  end

  private def playbook_source : String
    path = PluginSpecHelper.tmp_path("argspec_pb.yml")
    unless File.exists?(path)
      File.write(path, "---\n- hosts: localhost\n  gather_facts: false\n  tasks:\n  - lineinfile:\n      bakcrefs: true\n")
    end
    path
  end

  private def source_task(module_name : String) : Krikri::Task
    task = Krikri::Task.new("t", module_name)
    task.source_file = playbook_source
    task.source_line = 6
    task.source_col = 5
    task
  end

  # The [ERROR] block itself goes through ErrorBlock.emit's own stdout
  # channel (not OutputRouting), so these captures assert the fatal-dump
  # half; the chain shape is pinned by the failure_kind? specs above.
  it "renders template's validation failure with the collapsed Module-failed chain" do
    result = JSON.parse(%({"changed": false, "failed": true, "checksum": "04358ba4b61baf28347545d243f04382da4584a8",
                           "msg": "Unsupported parameters for (ansible.legacy.copy) module: mdoe. Supported parameters include: _original_basename, attributes, backup, checksum, content, dest, directory_mode, follow, force, group, local_follow, mode, owner, remote_src, selevel, serole, setype, seuser, src, unsafe_writes, validate (attr)."}))
    out = capture_output do
      Krikri::ResultDisplay.display_result(Krikri::Host.new("localhost"), result, false,
        ignore_errors: true, module_name: "ansible.builtin.template",
        source_task: source_task("ansible.builtin.template"))
    end
    out.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"checksum\": \"04358ba4b61baf28347545d243f04382da4584a8\", \"msg\":")
  end

  it "renders an action-only directive's failure without a Module-failed segment" do
    result = JSON.parse(%({"failed": true, "msg": "Unsupported parameters for (debug) module: zz. Supported parameters include: msg, var, verbosity."}))
    out = capture_output do
      Krikri::ResultDisplay.display_result(Krikri::Host.new("localhost"), result, false,
        ignore_errors: true, module_name: "ansible.builtin.debug",
        source_task: source_task("ansible.builtin.debug"))
    end
    out.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Unsupported parameters for (debug) module: zz.")
    out.must_include("...ignoring")
  end
end
