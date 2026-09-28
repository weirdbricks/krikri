require "../minitest_helper"

describe "ping plugin" do
  it "returns ping: pong by default" do
    result = PluginSpecHelper.run("ping", {} of String => String)

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["ping"].as_s.must_equal("pong")
  end

  it "echoes a custom data: value" do
    result = PluginSpecHelper.run("ping", {"data" => "hello"})

    result["ping"].as_s.must_equal("hello")
  end

  it "fails with data: crash, real Ansible's own deliberate-failure test path" do
    result = PluginSpecHelper.run("ping", {"data" => "crash"})

    result["failed"].as_bool.must_equal(true)
  end
end
