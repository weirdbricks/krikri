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
private def run_delegate_sync(task_host_name : String, params : Hash(String, String), vars = Hash(String, JSON::Any).new) : Krikri::ActionResult
  delegate = Krikri::Host.new("localhost")
  delegate.vars["ansible_connection"] = JSON::Any.new("local")
  task_host = Krikri::Host.new(task_host_name)
  plugin = Krikri::SynchronizeActionPlugin.new(params, vars, delegate, nil, task_host)
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
