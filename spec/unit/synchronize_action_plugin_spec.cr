require "../spec_helper"
require "file_utils"
require "../../src/krikri/inventory_parser"
require "../../src/krikri/action_plugin_manager"

# SynchronizeActionPlugin's delegate_to: localhost munging: real Ansible
# runs rsync on the controller (the delegate's connection is local) and
# qualifies the mode-dependent other end from the TASK host's own
# inventory address - rsync then dials that host over its own ssh. These
# specs use a task host whose name cannot resolve, so the real rsync run
# fails fast on hostname resolution; what is asserted is the munging
# itself (the qualified dest/src in the returned cmd) plus the
# failed/changed shape real Ansible produces for the same unresolvable
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

describe "SynchronizeActionPlugin delegate_to localhost munging" do
  it "qualifies push dest with the task host's inventory address and runs rsync on the controller" do
    result = run_delegate_sync("unresolvable-sync-spec-host", {
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "/tmp/sync-spec-dest/",
    })

    final = result.final_result
    final.should_not be_nil
    json = final.not_nil!
    json.as_h["failed"].as_bool.should be_true
    json.as_h["changed"].as_bool.should be_false
    json.as_h["cmd"].as_s.should contain("unresolvable-sync-spec-host:/tmp/sync-spec-dest/")
    json.as_h["cmd"].as_s.should contain("--rsh=")
  end

  it "qualifies pull src instead of dest" do
    result = run_delegate_sync("unresolvable-sync-spec-host", {
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "/tmp/sync-spec-dest/",
      "mode" => "pull",
    })

    json = result.final_result.not_nil!
    json.as_h["failed"].as_bool.should be_true
    json.as_h["cmd"].as_s.should contain("unresolvable-sync-spec-host:/tmp/sync-spec-src/")
    json.as_h["cmd"].as_s.should_not contain("unresolvable-sync-spec-host:/tmp/sync-spec-dest")
  end

  it "carries the task host's ansible_user as the remote user prefix" do
    vars = {"ansible_user" => JSON::Any.new("syncuser")}
    result = run_delegate_sync("unresolvable-sync-spec-host", {
      "src"  => "/tmp/sync-spec-src/",
      "dest" => "/tmp/sync-spec-dest/",
    }, vars)

    json = result.final_result.not_nil!
    json.as_h["cmd"].as_s.should contain("syncuser@unresolvable-sync-spec-host:/tmp/sync-spec-dest/")
  end

  it "stays a plain local sync when the task host IS the localhost delegate" do
    delegate = Krikri::Host.new("localhost")
    delegate.vars["ansible_connection"] = JSON::Any.new("local")
    plugin = Krikri::SynchronizeActionPlugin.new({
      "src"  => "/nonexistent/sync-spec-src",
      "dest" => "/nonexistent/sync-spec-dest",
    }, Hash(String, JSON::Any).new, delegate, nil, delegate)
    result = plugin.execute

    json = result.final_result.not_nil!
    json.as_h["failed"].as_bool.should be_true
    json.as_h["cmd"].as_s.should_not contain("@")
    json.as_h["cmd"].as_s.should_not contain("--rsh=")
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
        "src"        => "#{src}/",
        "dest"       => "#{dest}/",
        "_ansible_check_mode" => "true",
      }, Hash(String, JSON::Any).new, delegate)
      result = plugin.execute

      json = result.final_result.not_nil!
      json.as_h["failed"].as_bool.should be_falsey
      json.as_h["changed"].as_bool.should be_true
      json.as_h["cmd"].as_s.should contain("--dry-run")
      File.exists?(File.join(dest, "a.txt")).should be_false
    ensure
      cleanup_sync_dirs([src, dest])
    end
  end
end
