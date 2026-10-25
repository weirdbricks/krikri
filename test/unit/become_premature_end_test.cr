require "../minitest_helper"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/host"

describe "Krikri::PluginManager.become_premature_end_result (become_premature_end_test.cr)" do
  it "words an empty-stdout sudo failure like ansible's become failure" do
    result = Krikri::PluginManager.become_premature_end_result("", "sudo: a password is required\n")
    result.must_be_instance_of(JSON::Any)
    result = result.as(JSON::Any)
    result["msg"].as_s.must_equal("Task failed: Premature end of stream waiting for become success.\n>>> Standard Error\nsudo: a password is required")
    result["_connection_failure"].as_bool.must_equal(true)
    result["failed"].as_bool.must_equal(true)
  end

  it "leaves a silent or output-bearing failure to the generic parse error" do
    Krikri::PluginManager.become_premature_end_result("", "").must_be_nil
    Krikri::PluginManager.become_premature_end_result("garbage", "sudo: boom").must_be_nil
  end
end

# Round-trip 350: whether the config write lands before sudo exits or
# the write hits EPIPE on an already-gone sudo is pure scheduling, so
# both tests below assert the RESULT both hands must share - never the
# broken-pipe shape, always the premature-end one.
#
# "ping" keeps this off the modules other suite runs stage as become
# binaries (their staged copies DO get exec'd; this resolve ends at the
# checkout's own plugins/ping source - which, with sudo refusing before
# exec, never runs at all). Nothing else in the suite stages ping for a
# local become, so this test's staged copy is its own.
private def become_epipe_sudo_spawnable? : Bool
  spawnable = true
  begin
    Process.run("sudo", ["-n", "--", "true"],
      output: Process::Redirect::Close, error: Process::Redirect::Close)
  rescue
    spawnable = false
  end
  spawnable
end

private def become_epipe_local_become(config : String) : JSON::Any
  host = Krikri::Host.new("localhost", "root", 22)
  host.vars["ansible_connection"] = JSON::Any.new("local")
  Krikri::PluginManager.execute_plugin(
    "ping",
    config,
    host,
    {} of String => JSON::Any,
    true,
    "krikri-spec-become-write-race",
  )
end

private def become_epipe_assert_failure(result : JSON::Any) : Nil
  result["failed"].as_bool.must_equal(true)
  result["_connection_failure"].as_bool.must_equal(true)
  msg = result["msg"].as_s
  msg.starts_with?("Task failed: Premature end of stream waiting for become success.\n>>> Standard Error\nsudo: ").must_equal(true)
  msg.includes?("Plugin execution failed").must_equal(false)
  msg.includes?("Broken pipe").must_equal(false)
end

describe "Krikri::PluginManager.execute_plugin local become early-exit (become_premature_end_test.cr)" do
  it "books a refusing sudo as the become failure when the config write lands first" do
    skip "sudo not installed here" unless become_epipe_sudo_spawnable?
    3.times do
      become_epipe_assert_failure(become_epipe_local_become(%({"params": {"data": "pong"}})))
    end
  end

  it "books it there too when sudo leaves before the whole config lands (the reported EPIPE hand)" do
    skip "sudo not installed here" unless become_epipe_sudo_spawnable?
    # A payload wider than the pipe buffer parks the writer mid-config
    # while the refusing sudo (a few ms to print its error and exit) beats
    # it to the exit; the writer then resumes into a closed read end and
    # raises EPIPE - the hand that used to surface as
    # "Plugin execution failed: write ... Broken pipe" instead of ansible's
    # become failure.
    become_epipe_assert_failure(become_epipe_local_become(%({"junk": "#{"x" * 262144}"})))
  end
end
