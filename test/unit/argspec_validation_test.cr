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

  # Real's ArgumentSpecValidator runs its no_log value walk
  # (_list_no_log_values) BEFORE every other check: a string element of
  # a dict-shaped option WITH suboptions that can't be parsed as a dict
  # raises check_type_dict's bare TypeError, and its text is the module
  # failure msg verbatim (no "argument 'x' is of type" wrapping).
  # Captured live from real ansible-playbook 2.19.11 with
  # community.general.ini_file's section_has_values: ["fwtaiy"].
  it "fails a non-dict string element of a dict-elements option with check_type_dict's bare message" do
    failure = Krikri::ArgspecValidator.validate(
      "community.general.ini_file", "community.general.ini_file",
      {"path" => "/tmp/x", "section_has_values" => %(["fwtaiy"])}, vars)
    failure.wont_be_nil
    failure.not_nil!.msg.must_equal("dictionary requested, could not parse JSON or key=value")
    failure.not_nil!.action_level?.must_equal(false)
  end

  it "lets dict-shaped string elements of a dict-elements option through" do
    Krikri::ArgspecValidator.validate(
      "community.general.ini_file", "community.general.ini_file",
      {"path" => "/tmp/x", "section_has_values" => %([{"option": "AllowedIps", "value": "10.4.0.11/32"}])}, vars
    ).must_be_nil
    Krikri::ArgspecValidator.validate(
      "community.general.ini_file", "community.general.ini_file",
      {"path" => "/tmp/x", "section_has_values" => %(["option=AllowedIps"])}, vars
    ).must_be_nil
  end

  it "reports a non-string non-dict element with real's own (format-swapped) wording" do
    failure = Krikri::ArgspecValidator.validate(
      "community.general.ini_file", "community.general.ini_file",
      {"path" => "/tmp/x", "section_has_values" => %([5])}, vars)
    failure.not_nil!.msg.must_equal(
      "Value '5' in the sub parameter field 'section_has_values' must be a list, not 'int'")
  end

  it "runs the no_log walk before every other check (bare dict error beats mutual exclusion)" do
    failure = Krikri::ArgspecValidator.validate(
      "community.general.ini_file", "community.general.ini_file",
      {"path" => "/tmp/x", "section_has_values" => %(["fwtaiy"]), "value" => "a", "values" => %(["b"])}, vars)
    failure.not_nil!.msg.must_equal("dictionary requested, could not parse JSON or key=value")
  end

  it "fails assemble's missing src/dest at the action level, not the module spec" do
    # Real's assemble action plugin checks src/dest presence before the
    # remote_src staging and before the module validates anything
    # (live-verified vs 2.19.11: a typo'd src with remote_src: true
    # reports the action-level "src and dest are required", never the
    # module's "missing required arguments: src").
    failure = Krikri::ArgspecValidator.validate(
      "assemble", "ansible.builtin.assemble",
      {"dest" => "/tmp/x", "rsc" => "/tmp/src", "remote_src" => "true"}, vars)
    failure.not_nil!.msg.must_equal("src and dest are required")
    failure.not_nil!.action_level?.must_equal(true)

    failure = Krikri::ArgspecValidator.validate(
      "assemble", "ansible.builtin.assemble",
      {"src" => "/tmp/src", "edst" => "/tmp/x"}, vars)
    failure.not_nil!.msg.must_equal("src and dest are required")
    Krikri::ArgspecValidator.failure_kind?("ansible.builtin.assemble", "src and dest are required").must_equal(:action)
  end

  it "keeps template's post-action params out of the src/dest presence check" do
    # Once the template action has run, src is consumed into the rendered
    # content - the post-action spec pass must fall through to the
    # unsupported-params check (real's copy module rejects the leftover
    # template-only params there, live-verified vs 2.19.11), while the
    # pre-action pass with the ORIGINAL params still enforces presence.
    failure = Krikri::ArgspecValidator.validate(
      "template", "ansible.builtin.template",
      {"dest" => "/tmp/x", "content" => "rendered\n", "outupt_encoding" => "utf-8"}, vars)
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (ansible.legacy.copy) module: outupt_encoding. " \
      "Supported parameters include: _original_basename, attributes, backup, checksum, " \
      "content, dest, directory_mode, follow, force, group, local_follow, mode, owner, " \
      "remote_src, selevel, serole, setype, seuser, src, unsafe_writes, validate (attr).")
    failure.not_nil!.action_level?.must_equal(false)

    failure = Krikri::ArgspecValidator.validate(
      "template", "ansible.builtin.template",
      {"dest" => "/tmp/x", "ownre" => "root", "src_bogus" => "t.j2", "trim_blocks_bogus" => "true"}, vars)
    failure.not_nil!.msg.must_equal("src and dest are required")
    failure.not_nil!.action_level?.must_equal(true)
  end

  it "rejects assert's natively-typed fail_msg before the unsupported-params error" do
    # Real's assert action validates types (its own str_or_list_of_str
    # callable) BEFORE the unsupported-params error is appended, so a
    # wrong-type fail_msg wins over a typo'd key (live-verified vs
    # 2.19.11 with fail_msg: 75 + that_bogus:). The wire carries the
    # parser's non-string-literal marker; the demoted "75" text would
    # wrongly pass as a str.
    marked = Krikri::NON_STRING_PARAM_PREFIX + "75"
    failure = Krikri::ArgspecValidator.validate(
      "ansible.builtin.assert", "ansible.builtin.assert",
      {"fail_msg" => marked, "quiet" => "true", "that" => "true", "that_bogus" => "true"}, vars)
    failure.not_nil!.msg.must_equal(
      "argument 'fail_msg' is of type int and we were unable to convert to " \
      "str_or_list_of_str: a string or list of strings is required")
    failure.not_nil!.action_level?.must_equal(true)

    # Only the wrong type: same message shape, native bool this time.
    failure = Krikri::ArgspecValidator.validate(
      "ansible.builtin.assert", "ansible.builtin.assert",
      {"fail_msg" => Krikri::NON_STRING_PARAM_PREFIX + "true", "that" => "true"}, vars)
    failure.not_nil!.msg.must_equal(
      "argument 'fail_msg' is of type bool and we were unable to convert to " \
      "str_or_list_of_str: a string or list of strings is required")

    # Only the unsupported param: the unsupported error still fires.
    failure = Krikri::ArgspecValidator.validate(
      "ansible.builtin.assert", "ansible.builtin.assert",
      {"fail_msg" => "boom", "that" => "true", "that_bogus" => "true"}, vars)
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (ansible_collections.ansible.builtin.plugins.action.assert) " \
      "module: that_bogus. Supported parameters include: fail_msg, quiet, success_msg, that (msg).")

    # A JSON-encoded list of strings passes real's callable.
    Krikri::ArgspecValidator.validate(
      "assert", "ansible.builtin.assert",
      {"fail_msg" => %(["a", "b"]), "that" => "true"}, vars
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

  it "reports type errors in the module's own argument_spec order, not alphabetically" do
    # Real's _validate_argument_types walks argument_spec.items() in
    # DECLARATION order and the module fails on errors[0] - live-verified
    # vs 2.19.11 with apt (which declares update_cache_retry_max_delay
    # 4th, force 11th, allow_downgrade 22nd, lock_timeout 24th): a
    # wrong-typed int/bool pair reports whichever fails FIRST in that
    # order, so an alphabetical walk picks the wrong argument.
    failure = Krikri::ArgspecValidator.validate(
      "apt", "ansible.builtin.apt",
      {"name" => "x", "force" => "teoqdi", "update_cache_retry_max_delay" => "phxszz"}, vars)
    failure.not_nil!.msg.must_equal(
      "argument 'update_cache_retry_max_delay' is of type str and we were unable to convert to int: " \
      "\"'phxszz'\" cannot be converted to an int")

    # Two wrong bools: spec order (force 11th) beats alphabetical order
    # (allow_downgrade sorts 2nd).
    failure = Krikri::ArgspecValidator.validate(
      "apt", "ansible.builtin.apt",
      {"name" => "x", "allow_downgrade" => "zz", "force" => "yy"}, vars)
    failure.not_nil!.msg.must_equal(
      "argument 'force' is of type str and we were unable to convert to bool: " \
      "The value 'yy' is not a valid boolean. Valid booleans include: " \
      "'off', 1, 'true', 'y', 0, 'false', 'on', 'no', '1', 'yes', '0', 'n', 'f', 't'")
  end

  it "validates pause's int-callable seconds/minutes before unsupported params" do
    # Real's pause action validates its own spec (validate_argument_spec):
    # mutually exclusive, then types in declaration order, unsupported
    # params LAST - so a wrong-typed seconds beats a typo'd param
    # (live-verified vs 2.19.11 with seconds: lraeca + miuntes: mngkxw).
    failure = Krikri::ArgspecValidator.validate(
      "pause", "ansible.builtin.pause",
      {"seconds" => "lraeca", "miuntes" => "mngkxw"}, vars)
    failure.not_nil!.msg.must_equal(
      "argument 'seconds' is of type str and we were unable to convert to int: " \
      "invalid literal for int() with base 10: 'lraeca'")
    failure.not_nil!.action_level?.must_equal(true)

    # minutes/seconds are the int CALLABLE, not the 'int' string type: a
    # quoted float string goes through int(str) directly and fails with
    # int()'s raw ValueError (live-verified: seconds: '1.5'), while a
    # native float truncates (int(1.5) == 1) and a native bool passes.
    failure = Krikri::ArgspecValidator.validate(
      "pause", "ansible.builtin.pause", {"seconds" => "1.5"}, vars)
    failure.not_nil!.msg.must_equal(
      "argument 'seconds' is of type str and we were unable to convert to int: " \
      "invalid literal for int() with base 10: '1.5'")
    Krikri::ArgspecValidator.validate(
      "pause", "ansible.builtin.pause",
      {"seconds" => Krikri::NON_STRING_PARAM_PREFIX + "1.5"}, vars).must_be_nil
    Krikri::ArgspecValidator.validate(
      "pause", "ansible.builtin.pause",
      {"seconds" => Krikri::NON_STRING_PARAM_PREFIX + "true"}, vars).must_be_nil

    # mutually exclusive still beats the type errors (real appends it
    # first), in real's own "a|b" join.
    failure = Krikri::ArgspecValidator.validate(
      "pause", "ansible.builtin.pause",
      {"minutes" => "aa", "seconds" => "bb"}, vars)
    failure.not_nil!.msg.must_equal("parameters are mutually exclusive: minutes|seconds")

    # and the unsupported-params shape is unchanged
    failure = Krikri::ArgspecValidator.validate(
      "pause", "ansible.builtin.pause",
      {"prompt" => "uxpvfh", "prompt_bogus" => "uxpvfh"}, vars)
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (ansible_collections.ansible.builtin.plugins.action.pause) " \
      "module: prompt_bogus. Supported parameters include: echo, minutes, prompt, seconds.")
  end

  # debug's own spec lives in its ACTION plugin (plugins/action/
  # debug.py:40), which runs the same shared ArgumentSpecValidator before
  # the task does anything else - so real reports errors[0] out of
  # mutually_exclusive -> types in declaration order (msg, var,
  # verbosity) -> unsupported LAST. All live-verified vs 2.19.11.
  it "validates debug's own spec before its unsupported-parameter error" do
    # A wrong-typed verbosity beats a typo'd key (msg_bogus) ...
    failure = Krikri::ArgspecValidator.validate(
      "debug", "ansible.builtin.debug",
      {"msg" => "gddznp", "verbosity" => "epdfma", "msg_bogus" => "gddznp"}, vars)
    failure.not_nil!.msg.must_equal(
      "argument 'verbosity' is of type str and we were unable to convert to int: " \
      "\"'epdfma'\" cannot be converted to an int")
    failure.not_nil!.action_level?.must_equal(true)
    # ... and debug's callback result dump carries only msg, no changed.
    failure.not_nil!.omit_changed?.must_equal(true)

    # ... while a msg+var pair beats both the type error and the typo.
    failure = Krikri::ArgspecValidator.validate(
      "debug", "ansible.builtin.debug",
      {"msg" => "hi", "var" => "ansible_hostname", "verbosity" => "zzz", "msg_bogus" => "x"}, vars)
    failure.not_nil!.msg.must_equal("parameters are mutually exclusive: msg|var")

    # A present-but-null msg is still "present" for that check.
    failure = Krikri::ArgspecValidator.validate(
      "debug", "ansible.builtin.debug",
      {"msg" => Krikri::NONE_SENTINEL, "var" => "ansible_hostname"}, vars)
    failure.not_nil!.msg.must_equal("parameters are mutually exclusive: msg|var")

    # The unsupported-params error is real's LAST, unchanged in wording
    # (and real echoes the FQCN the task was spelled with - the resolved
    # action-plugin path only for the ansible.builtin.debug spelling).
    failure = Krikri::ArgspecValidator.validate(
      "ansible.builtin.debug", "ansible.builtin.debug",
      {"var" => "nosuchvar_zz", "zz_bogus" => "1"}, vars)
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (ansible_collections.ansible.builtin.plugins.action.debug) " \
      "module: zz_bogus. Supported parameters include: msg, var, verbosity.")
    failure.not_nil!.omit_changed?.must_equal(true)
    Krikri::ArgspecValidator.validate(
      "debug", "ansible.builtin.debug",
      {"var" => "nosuchvar_zz", "zz_bogus" => "1"}, vars).not_nil!.msg.must_equal(
      "Unsupported parameters for (debug) module: zz_bogus. " \
      "Supported parameters include: msg, var, verbosity.")
  end

  it "reports debug's verbosity/var type errors in real's per-type wording" do
    # verbosity is an int: every natively-typed value fails with its own
    # Python repr, a numeric string converts fine, a bool IS an int.
    {
      Krikri::NON_STRING_PARAM_PREFIX + "1.5"  => "argument 'verbosity' is of type float and we were unable to convert to int: \"1.5\" cannot be converted to an int",
      Krikri::NON_STRING_PARAM_PREFIX + "true" => nil,
      "3"                                      => nil,
      "-1"                                     => nil,
      "[1, 2]"                                 => "argument 'verbosity' is of type list and we were unable to convert to int: \"[1, 2]\" cannot be converted to an int",
      # a comma-joined list wire whose members are non-string scalars
      # (what the parser produces for `verbosity: [1, 2]`) is re-encoded
      # as the JSON array it is, so real's list error - and repr - come out
      "1," + Krikri::NON_STRING_MEMBER_PREFIX + "2" => "argument 'verbosity' is of type list and we were unable to convert to int: \"[1, 2]\" cannot be converted to an int",
      "{\"a\": 1}"                                  => "argument 'verbosity' is of type dict and we were unable to convert to int: \"{'a': 1}\" cannot be converted to an int",
      Krikri::NONE_SENTINEL                         => "argument 'verbosity' is of type NoneType and we were unable to convert to int: \"None\" cannot be converted to an int",
    }.each do |value, expected|
      failure = Krikri::ArgspecValidator.validate(
        "debug", "ansible.builtin.debug", {"msg" => "hi", "verbosity" => value}, vars)
      if expected
        failure.not_nil!.msg.must_equal(expected)
      else
        failure.must_be_nil
      end
    end

    # var rides the _check_type_str_no_conversion CALLABLE: no coercion at
    # all, the checker's own repr in the "unable to convert to" slot.
    {
      Krikri::NON_STRING_PARAM_PREFIX + "5" => "argument 'var' is of type int and we were unable to convert to _check_type_str_no_conversion: " \
                                               "'5' is not a string and conversion is not allowed",
      Krikri::NON_STRING_PARAM_PREFIX + "true" => "argument 'var' is of type bool and we were unable to convert to _check_type_str_no_conversion: " \
                                                  "'True' is not a string and conversion is not allowed",
      "{\"a\": 1}" => "argument 'var' is of type dict and we were unable to convert to _check_type_str_no_conversion: " \
                      "'{'a': 1}' is not a string and conversion is not allowed",
      # a None value is skipped by the validator itself (neither required
      # nor defaulted) and real then prints "Hello world!".
      Krikri::NONE_SENTINEL => nil,
      "playbook_dir"        => nil,
    }.each do |value, expected|
      failure = Krikri::ArgspecValidator.validate(
        "debug", "ansible.builtin.debug", {"var" => value}, vars)
      if expected
        failure.not_nil!.msg.must_equal(expected)
      else
        failure.must_be_nil
      end
    end

    # var is declared before verbosity, so its error wins when both fail.
    failure = Krikri::ArgspecValidator.validate(
      "debug", "ansible.builtin.debug",
      {"var" => Krikri::NON_STRING_PARAM_PREFIX + "5", "verbosity" => "qqq"}, vars)
    failure.not_nil!.msg.must_include("argument 'var' is of type int")
  end

  # copy's and template's ACTION plugins read `follow` through
  # boolean(strict=False) and hand the copy MODULE the coerced boolean, so
  # a spelling real would reject never reaches that module's spec - except
  # on copy's remote_src branch, which passes the raw args (live-verified
  # vs 2.19.11).
  it "never type-checks copy/template's follow the way their action plugin reads it" do
    template = {"src" => "/tmp/s.j2", "dest" => "/tmp/d", "follow" => "hcsjhk"}
    # template: the bad follow is coerced to False by the action plugin, so
    # a typo'd key is the only thing left to fail on.
    failure = Krikri::ArgspecValidator.validate(
      "template", "ansible.builtin.template", template.merge({"gropu" => "root"}), vars)
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (ansible.legacy.copy) module: gropu. " \
      "Supported parameters include: _original_basename, attributes, backup, checksum, content, " \
      "dest, directory_mode, follow, force, group, local_follow, mode, owner, remote_src, " \
      "selevel, serole, setype, seuser, src, unsafe_writes, validate (attr).")
    # ... and a wrong-typed option alongside it is reported instead.
    failure = Krikri::ArgspecValidator.validate(
      "template", "ansible.builtin.template", template.merge({"backup" => "notabool"}), vars)
    failure.not_nil!.msg.must_equal(
      "argument 'backup' is of type str and we were unable to convert to bool: " \
      "The value 'notabool' is not a valid boolean. Valid booleans include: " \
      "#{Krikri::ArgspecValidator::BOOLEANS_REPR.join(", ")}")
    # copy: same on its controller-side path - which copy.py:422 picks with
    # the SAME boolean(strict=False), so 'no' and the string "false" are
    # falsy there too (live-verified vs 2.19.11).
    {"no", "false", Krikri::NON_STRING_PARAM_PREFIX + "false"}.each do |remote_src|
      failure = Krikri::ArgspecValidator.validate(
        "copy", "ansible.builtin.copy",
        template.merge({"gorup" => "root", "remote_src" => remote_src}), vars)
      failure.not_nil!.msg.must_include("module: gorup.")
      failure.not_nil!.msg.wont_include("argument 'follow'")
    end
    # ... but with a truthy remote_src the raw args go to the module, where
    # the strict spec does reject it - ahead of the typo'd key.
    {"true", "yes"}.each do |remote_src|
      failure = Krikri::ArgspecValidator.validate(
        "copy", "ansible.builtin.copy",
        template.merge({"gorup" => "root", "remote_src" => remote_src}), vars)
      failure.not_nil!.msg.must_include("argument 'follow' is of type str")
    end
  end

  it "keeps template's own action-level checks ahead of the copy spec" do
    # `state` is a None check in real's action plugin, so a `state:` with no
    # value passes it and only the typo'd key is reported.
    failure = Krikri::ArgspecValidator.validate(
      "template", "ansible.builtin.template",
      {"src" => "/tmp/s.j2", "dest" => "/tmp/d", "state" => "present", "gropu" => "root"}, vars)
    failure.not_nil!.msg.must_equal("'state' cannot be specified on a template")
    failure.not_nil!.action_level?.must_equal(true)
    failure = Krikri::ArgspecValidator.validate(
      "template", "ansible.builtin.template",
      {"src" => "/tmp/s.j2", "dest" => "/tmp/d", "state" => Krikri::NONE_SENTINEL, "gropu" => "root"}, vars)
    failure.not_nil!.msg.must_include("Unsupported parameters for (ansible.legacy.copy) module: gropu")

    # `decrypt` is action-only: copy's action plugin drops it (and content)
    # from the module args, so it is never an unsupported parameter.
    failure = Krikri::ArgspecValidator.validate(
      "template", "ansible.builtin.template",
      {"src" => "/tmp/s.j2", "dest" => "/tmp/d", "decrypt" => "notabool", "gropu" => "root"}, vars)
    failure.not_nil!.msg.must_equal(
      "Unsupported parameters for (ansible.legacy.copy) module: gropu. " \
      "Supported parameters include: _original_basename, attributes, backup, checksum, content, " \
      "dest, directory_mode, follow, force, group, local_follow, mode, owner, remote_src, " \
      "selevel, serole, setype, seuser, src, unsafe_writes, validate (attr).")
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
