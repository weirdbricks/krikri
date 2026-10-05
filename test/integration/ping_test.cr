require "../minitest_helper"

describe "ping plugin" do
  it "returns ping: pong by default" do
    result = PluginSpecHelper.run("ping", {} of String => String)

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    # Ansible's ping module wire carries ONLY {ping} - no changed (exit_json
    # passes none; the task executor backfills failed, changed onto the
    # registered result).
    result["changed"]?.must_equal(nil)
    result["ping"].as_s.must_equal("pong")
  end

  it "echoes a custom data: value" do
    result = PluginSpecHelper.run("ping", {"data" => "hello"})

    result["ping"].as_s.must_equal("hello")
  end

  it "fails with data: crash, Ansible's own deliberate-failure test path" do
    result = PluginSpecHelper.run("ping", {"data" => "crash"})

    result["failed"].as_bool.must_equal(true)
  end
end
