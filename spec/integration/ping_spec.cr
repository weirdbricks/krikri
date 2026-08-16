require "../spec_helper"

describe "ping plugin" do
  it "returns ping: pong by default" do
    result = PluginSpecHelper.run("ping", {} of String => String)

    result["failed"].as_bool.should be_false
    result["changed"].as_bool.should be_false
    result["ping"].as_s.should eq("pong")
  end

  it "echoes a custom data: value" do
    result = PluginSpecHelper.run("ping", {"data" => "hello"})

    result["ping"].as_s.should eq("hello")
  end

  it "fails with data: crash, real Ansible's own deliberate-failure test path" do
    result = PluginSpecHelper.run("ping", {"data" => "crash"})

    result["failed"].as_bool.should be_true
  end
end
