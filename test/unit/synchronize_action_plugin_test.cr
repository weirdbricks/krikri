require "../minitest_helper"
require "file_utils"
require "../../src/krikri/inventory_parser"
require "../../src/krikri/action_plugin_manager"
# The action plugin calls SSHManager.sshpass_env; in a single-file run
# nothing else in the graph requires it (the whole-suite entrypoint gets
# it transitively from other tests).
require "../../src/krikri/ssh_manager"

# SynchronizeActionPlugin's delegate_to: localhost munging: Ansible
# runs rsync on the controller (the delegate's connection is local) and
# qualifies the mode-dependent other end from the TASK host's own
# inventory address - rsync then dials that host over its own ssh. These
# specs use a task host whose name cannot resolve, so the real rsync run
# fails fast on hostname resolution; what is asserted is the munging
# itself (the qualified dest/src in the returned cmd) plus the
# failed/changed shape Ansible produces for the same unresolvable
# task host (verified live, ansible-core 2.19 + ansible.posix: the task
# host's own ansible_connection=local does NOT suppress the
# qualification).
private def run_delegate_sync(task_host_name : String, params : Hash(String, String), vars = Hash(String, JSON::Any).new, action_name : String? = nil) : Krikri::ActionResult
  delegate = Krikri::Host.new("localhost")
  delegate.vars["ansible_connection"] = JSON::Any.new("local")
  task_host = Krikri::Host.new(task_host_name)
  plugin = Krikri::SynchronizeActionPlugin.new(params, vars, delegate, nil, task_host, nil, action_name)
  plugin.execute
end

private def cleanup_sync_dirs(paths : Array(String?)) : Nil
  paths.each { |path| FileUtils.rm_rf(path) if path }
end

describe "SynchronizeActionPlugin argument validation" do
  # Real's ordering, live-verified against ansible-core 2.19.11 +
  # ansible.posix 2.1.0: the action plugin's src/dest check first, then
  # AnsibleModule's bool conversion, then mode's choices validation. The
  # fixed "Valid booleans include:" tail is this engine's deterministic
  # order (real serializes a Python SET there - same wording, shuffled
  # order between runs; see bool_param_validation_test.cr).
  it "fails a non-boolean dirs before any rsync runs, with the parameters.py message" do
    result = run_delegate_sync("localhost", {
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "/tmp/sync-spec-dest/",
      "dirs" => "ylazyy",
    })

    json = result.final_result || raise "expected a final result"
    json.as_h["failed"].as_bool.must_equal(true)
    json.as_h["changed"].as_bool.must_equal(false)
    json.as_h["msg"].as_s.must_equal(
      "argument 'dirs' is of type str and we were unable to convert to bool: " \
      "The value 'ylazyy' is not a valid boolean. Valid booleans include: " \
      "'1', 'on', 1, '0', 0, 'n', 'f', 'false', 'true', 'y', 't', 'yes', 'no', 'off'")
    json.as_h.has_key?("cmd").must_equal(false)
    json.as_h.keys.first(3).must_equal(["failed", "msg", "changed"])
  end

  it "rejects mode: PUSH (choices validation is case-sensitive and reports the raw value)" do
    result = run_delegate_sync("localhost", {
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "/tmp/sync-spec-dest/",
      "mode" => "PUSH",
    })

    json = result.final_result || raise "expected a final result"
    json.as_h["failed"].as_bool.must_equal(true)
    json.as_h["changed"].as_bool.must_equal(false)
    json.as_h["msg"].as_s.must_equal("value of mode must be one of: pull, push, got: PUSH")
    json.as_h.has_key?("cmd").must_equal(false)
    json.as_h.keys.first(3).must_equal(["failed", "msg", "changed"])
  end

  it "reports the src/dest check ahead of the bool and mode checks, like the real action plugin" do
    result = run_delegate_sync("localhost", {
      "mode" => "PUSH",
      "dirs" => "ylazyy",
    })

    json = result.final_result || raise "expected a final result"
    json.as_h["failed"].as_bool.must_equal(true)
    json.as_h["msg"].as_s.must_equal("synchronize requires both src and dest parameters are set")
    json.as_h.has_key?("cmd").must_equal(false)
  end

  # Live-verified against ansible-core 2.19.11 + ansible.posix 2.1.0
  # (issue #744): the Unsupported-parameters check is module setup's
  # LAST check, so it only fires once the bool/mode conversions above
  # have passed, and the supported list is the spec's own option names
  # sorted with no alias parenthetical (synchronize's spec declares
  # none).
  it "fails bogus option names with the module's Unsupported-parameters message" do
    result = run_delegate_sync("localhost", {
      "src"                          => "/tmp/sync-spec-src/",
      "dest"                         => "/tmp/sync-spec-dest/",
      "_substitute_controller_bogus" => "false",
      "checksum_bogus"               => "true",
      "existin_gonly"                => "false",
      "moed"                         => "0600",
    })

    json = result.final_result || raise "expected a final result"
    json.as_h["failed"].as_bool.must_equal(true)
    json.as_h["changed"].as_bool.must_equal(false)
    json.as_h["msg"].as_s.must_equal(
      "Unsupported parameters for (ansible.posix.synchronize) module: " \
      "_substitute_controller_bogus, checksum_bogus, existin_gonly, moed. " \
      "Supported parameters include: _local_rsync_password, _local_rsync_path, _ssh_args, " \
      "_substitute_controller, archive, checksum, compress, copy_links, delay_updates, delete, " \
      "dest, dest_port, dirs, existing_only, group, link_dest, links, mode, owner, partial, " \
      "perms, private_key, recursive, rsync_opts, rsync_path, rsync_timeout, set_remote_user, " \
      "src, ssh_connection_multiplexing, times, use_ssh_args, verify_host.")
    json.as_h.has_key?("cmd").must_equal(false)
    json.as_h.keys.first(3).must_equal(["failed", "msg", "changed"])
  end

  # The message names the module AS WRITTEN in the task, like real (a
  # bare `synchronize:` does not dress up as the resolved FQCN).
  it "prints the as-written module spelling in the Unsupported-parameters message" do
    result = run_delegate_sync("localhost", {
      "src"            => "/tmp/sync-spec-src/",
      "dest"           => "/tmp/sync-spec-dest/",
      "checksum_bogus" => "true",
    }, action_name: "synchronize")

    json = result.final_result || raise "expected a final result"
    json.as_h["msg"].as_s.must_match(/\AUnsupported parameters for \(synchronize\) module: checksum_bogus\./)
  end

  it "reports the bool and mode failures ahead of the unsupported-parameter check" do
    bool_first = run_delegate_sync("localhost", {
      "src"            => "/tmp/sync-spec-src/",
      "dest"           => "/tmp/sync-spec-dest/",
      "dirs"           => "ylazyy",
      "checksum_bogus" => "true",
    })
    bool_first.final_result.try(&.as_h["msg"].as_s).must_match(/\Aargument 'dirs' is of type str/)

    mode_first = run_delegate_sync("localhost", {
      "src"            => "/tmp/sync-spec-src/",
      "dest"           => "/tmp/sync-spec-dest/",
      "mode"           => "PUSH",
      "checksum_bogus" => "true",
    })
    mode_first.final_result.try(&.as_h["msg"].as_s).must_equal("value of mode must be one of: pull, push, got: PUSH")
  end

  # A literal YAML null mode stringifies to an EMPTY tail in real's
  # choices message ("got: " with nothing after it, live-verified vs
  # 2.19.11) - not the wire's null sentinel text.
  it "reports a null mode with the empty got: tail" do
    result = run_delegate_sync("localhost", {
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "/tmp/sync-spec-dest/",
      "mode" => Krikri::NONE_SENTINEL,
    })

    json = result.final_result || raise "expected a final result"
    json.as_h["msg"].as_s.must_equal("value of mode must be one of: pull, push, got: ")
  end

  # A literal YAML null src rides the wire as NONE_SENTINEL, and real's
  # guard (`src is None or dest is None`) still fires for it - the
  # action-plugin check precedes the module's own missing-required
  # check, so the guard's message (and its Action-failed chain) wins
  # over the unsupported-parameter one.
  it "reports the src/dest guard, not unsupported parameters, for a null src" do
    result = run_delegate_sync("localhost", {
      "src"            => Krikri::NONE_SENTINEL,
      "dest"           => "/tmp/sync-spec-dest/",
      "checksum_bogus" => "true",
    })

    json = result.final_result || raise "expected a final result"
    json.as_h["msg"].as_s.must_equal("synchronize requires both src and dest parameters are set")
  end
end

describe "SynchronizeActionPlugin delegate_to localhost munging" do
  it "qualifies push dest with the task host's inventory address and runs rsync on the controller" do
    result = run_delegate_sync("unresolvable-sync-spec-host", {
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "/tmp/sync-spec-dest/",
    })

    json = result.final_result || raise "expected a final result"
    json.as_h["failed"].as_bool.must_equal(true)
    json.as_h["changed"].as_bool.must_equal(false)
    json.as_h["cmd"].as_s.must_include("unresolvable-sync-spec-host:/tmp/sync-spec-dest/")
    json.as_h["cmd"].as_s.must_include("--rsh=")
  end

  it "qualifies pull src instead of dest" do
    result = run_delegate_sync("unresolvable-sync-spec-host", {
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "/tmp/sync-spec-dest/",
      "mode" => "pull",
    })

    json = result.final_result || raise "expected a final result"
    json.as_h["failed"].as_bool.must_equal(true)
    json.as_h["cmd"].as_s.must_include("unresolvable-sync-spec-host:/tmp/sync-spec-src/")
    json.as_h["cmd"].as_s.wont_include("unresolvable-sync-spec-host:/tmp/sync-spec-dest")
  end

  it "carries the task host's ansible_user as the remote user prefix" do
    vars = {"ansible_user" => JSON::Any.new("syncuser")}
    result = run_delegate_sync("unresolvable-sync-spec-host", {
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "/tmp/sync-spec-dest/",
    }, vars)

    json = result.final_result || raise "expected a final result"
    json.as_h["cmd"].as_s.must_include("syncuser@unresolvable-sync-spec-host:/tmp/sync-spec-dest/")
  end

  # The rsync rsh key resolves through the shared ConnectionSettings
  # ladder (both key spellings, then ANSIBLE_PRIVATE_KEY_FILE - issue
  # #1067), not just the ansible_ssh_private_key_file var.
  it "feeds the rsync rsh key through the shared ladder (canonical spelling included)" do
    vars = {"ansible_private_key_file" => JSON::Any.new("/keys/id_ecdsa")}
    result = run_delegate_sync("unresolvable-sync-spec-host", {
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "/tmp/sync-spec-dest/",
    }, vars)

    json = result.final_result || raise "expected a final result"
    json.as_h["cmd"].as_s.must_include("-i /keys/id_ecdsa")
  end

  it "stays a plain local sync when the task host IS the localhost delegate" do
    delegate = Krikri::Host.new("localhost")
    delegate.vars["ansible_connection"] = JSON::Any.new("local")
    plugin = Krikri::SynchronizeActionPlugin.new({
      "src"  => "/nonexistent/sync-spec-src",
      "dest" => "/nonexistent/sync-spec-dest",
    }, Hash(String, JSON::Any).new, delegate, nil, delegate)
    result = plugin.execute

    json = result.final_result || raise "expected a final result"
    json.as_h["failed"].as_bool.must_equal(true)
    json.as_h["cmd"].as_s.wont_include("@")
    json.as_h["cmd"].as_s.wont_include("--rsh=")
  end

  it "runs a plain remote pull (no delegate_to) from the controller, not on the target" do
    # softasap.sa-vpn-softether round 2300304: the executor used to pass
    # task_host == host even with NO delegate_to:, so synchronize's
    # dest_is_local branch (meant for delegate_to naming the task's own
    # host) fired for every plain remote task and the module binary was
    # dispatched ONTO the target host - where pull mode's controller-side
    # dest path (/home/<user>/...) cannot exist and rsync died with
    # "mkdir ... No such file or directory" while real ansible pulled the
    # files. The task host here is unresolvable on purpose: the point is
    # that rsync RUNS ON THE CONTROLLER and qualifies the remote src.
    task_host = Krikri::Host.new("unresolvable-sync-spec-host")
    plugin = Krikri::SynchronizeActionPlugin.new({
      "src"  => "/opt/vpnserver/generated",
      "dest" => "/tmp/sync-spec-dest/generated",
      "mode" => "pull",
    }, Hash(String, JSON::Any).new, task_host, nil, nil)
    result = plugin.execute

    json = result.final_result || raise "expected a final result"
    json.as_h["cmd"].as_s.must_include("unresolvable-sync-spec-host:/opt/vpnserver/generated")
  end

  it "still dispatches the module on the host for delegate_to naming the task's own host" do
    task_host = Krikri::Host.new("unresolvable-sync-spec-host")
    plugin = Krikri::SynchronizeActionPlugin.new({
      "src"  => "/tmp/sync-spec-src",
      "dest" => "/tmp/sync-spec-dest",
    }, Hash(String, JSON::Any).new, task_host, nil, task_host)
    result = plugin.execute

    result.final_result.must_be_nil
    result.modified_params.must_equal({
      "src"  => "/tmp/sync-spec-src",
      "dest" => "/tmp/sync-spec-dest",
    })
  end

  it "check mode predicts changes with rsync --dry-run and writes nothing" do
    delegate = Krikri::Host.new("localhost")
    delegate.vars["ansible_connection"] = JSON::Any.new("local")
    src = File.tempname("sync-spec-check-src")
    dest = File.tempname("sync-spec-check-dest")
    begin
      Dir.mkdir_p(src)
      Dir.mkdir_p(dest)
      File.write(File.join(src, "a.txt"), "file a\n")

      plugin = Krikri::SynchronizeActionPlugin.new({
        "src"                 => "#{src}/",
        "dest"                => "#{dest}/",
        "_ansible_check_mode" => "true",
      }, Hash(String, JSON::Any).new, delegate)
      result = plugin.execute

      json = result.final_result || raise "expected a final result"
      expect(falsey?(json.as_h["failed"].as_bool)).must_equal(true)
      json.as_h["changed"].as_bool.must_equal(true)
      json.as_h["cmd"].as_s.must_include("--dry-run")
      File.exists?(File.join(dest, "a.txt")).must_equal(false)
    ensure
      cleanup_sync_dirs([src, dest])
    end
  end
end

describe "SynchronizeActionPlugin non-string literal src/dest" do
  # Real's action plugin crashes in its path munging when a non-string
  # YAML literal src/dest reaches it (the parser marks those;
  # NON_STRING_PARAM_PREFIX): _get_absolute_path's `':' in <int>` raises
  # the TypeError, the remote-qualified end's startswith('rsync://') the
  # AttributeError (live-verified vs 2.19.11 across the push/pull x
  # src/dest x local/ssh matrix). The params here carry the marker the
  # way execute_action hands them over - synchronize opts out of the
  # strip for exactly this probe.
  it "crashes with _get_absolute_path's TypeError on a local connection, like real" do
    host = Krikri::Host.new("localhost")
    host.vars["ansible_connection"] = JSON::Any.new("local")
    result = Krikri::SynchronizeActionPlugin.new({
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "#{Krikri::NON_STRING_PARAM_PREFIX}25",
    }, Hash(String, JSON::Any).new, host).execute

    result.success?.must_equal(false)
    result.error_detail?.must_equal("argument of type '_AnsibleTaggedInt' is not iterable")
    result.error_message.must_equal("Task failed: argument of type '_AnsibleTaggedInt' is not iterable")
  end

  it "reports bools as plain 'bool', like Python's own TypeError wording" do
    host = Krikri::Host.new("localhost")
    host.vars["ansible_connection"] = JSON::Any.new("local")
    result = Krikri::SynchronizeActionPlugin.new({
      "src"  => "#{Krikri::NON_STRING_PARAM_PREFIX}true",
      "dest" => "/tmp/sync-spec-dest/",
    }, Hash(String, JSON::Any).new, host).execute

    result.error_detail?.must_equal("argument of type 'bool' is not iterable")
  end

  it "reports floats as _AnsibleTaggedFloat" do
    host = Krikri::Host.new("localhost")
    host.vars["ansible_connection"] = JSON::Any.new("local")
    result = Krikri::SynchronizeActionPlugin.new({
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "#{Krikri::NON_STRING_PARAM_PREFIX}2.5",
    }, Hash(String, JSON::Any).new, host).execute

    result.error_detail?.must_equal("argument of type '_AnsibleTaggedFloat' is not iterable")
  end

  it "crashes with format_rsync_rsh_target's startswith AttributeError on a remote-qualified push dest" do
    result = Krikri::SynchronizeActionPlugin.new({
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "#{Krikri::NON_STRING_PARAM_PREFIX}25",
    }, Hash(String, JSON::Any).new, Krikri::Host.new("unresolvable-sync-spec-host")).execute

    result.error_detail?.must_equal("'_AnsibleTaggedInt' object has no attribute 'startswith'")
  end

  it "remote-qualifies pull's SRC end, so a literal src crashes with the AttributeError there" do
    result = Krikri::SynchronizeActionPlugin.new({
      "src"  => "#{Krikri::NON_STRING_PARAM_PREFIX}25",
      "dest" => "/tmp/sync-spec-dest/",
      "mode" => "pull",
    }, Hash(String, JSON::Any).new, Krikri::Host.new("unresolvable-sync-spec-host")).execute

    result.error_detail?.must_equal("'_AnsibleTaggedInt' object has no attribute 'startswith'")
  end

  it "keeps pull's dest controller-local, so a literal dest crashes with the TypeError there" do
    result = Krikri::SynchronizeActionPlugin.new({
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "#{Krikri::NON_STRING_PARAM_PREFIX}25",
      "mode" => "pull",
    }, Hash(String, JSON::Any).new, Krikri::Host.new("unresolvable-sync-spec-host")).execute

    result.error_detail?.must_equal("argument of type '_AnsibleTaggedInt' is not iterable")
  end

  # Real's ordering: the munging crash happens in the ACTION plugin,
  # before AnsibleModule setup (bool conversion) ever runs - so a bad
  # bool param loses to a non-string dest, both live-verified shapes.
  it "reports the literal crash ahead of a bad bool param, like real's ordering" do
    host = Krikri::Host.new("localhost")
    host.vars["ansible_connection"] = JSON::Any.new("local")
    result = Krikri::SynchronizeActionPlugin.new({
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "#{Krikri::NON_STRING_PARAM_PREFIX}25",
      "dirs" => "ylazyy",
    }, Hash(String, JSON::Any).new, host).execute

    result.error_detail?.must_equal("argument of type '_AnsibleTaggedInt' is not iterable")
  end

  it "fails a literal null dest with the missing-parameter message, like real's None check" do
    host = Krikri::Host.new("localhost")
    host.vars["ansible_connection"] = JSON::Any.new("local")
    result = Krikri::SynchronizeActionPlugin.new({
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "#{Krikri::NON_STRING_PARAM_PREFIX}null",
    }, Hash(String, JSON::Any).new, host).execute

    json = result.final_result || raise "expected a final result"
    json.as_h["msg"].as_s.must_equal("synchronize requires both src and dest parameters are set")
  end
end
