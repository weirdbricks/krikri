require "../spec_helper"
require "socket"

describe "wait_for plugin" do
  it "fails clearly when both path and port are given" do
    result = PluginSpecHelper.run("wait_for", {"port" => "80", "path" => "/etc/hostname"})
    result["failed"].as_bool.should be_true
  end

  it "is skipped under check_mode, matching real Ansible's own skip text" do
    result = PluginSpecHelper.run("wait_for", {"timeout" => "1", "check_mode" => "true"})
    result["failed"].as_bool.should be_false
    result["skipped"].as_bool.should be_true
    result["msg"].as_s.should eq("remote module (wait_for) does not support check mode")
  end

  it "times out waiting for a closed port, with host:port in the message" do
    result = PluginSpecHelper.run("wait_for", {"port" => "1", "host" => "127.0.0.1", "timeout" => "1", "connect_timeout" => "1"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Timeout when waiting for 127.0.0.1:1")
  end

  it "honors a custom msg: on timeout" do
    result = PluginSpecHelper.run("wait_for", {"port" => "1", "timeout" => "1", "msg" => "custom timeout message"})
    result["msg"].as_s.should eq("custom timeout message")
  end

  it "succeeds immediately when an open port is already listening" do
    server = TCPServer.new("127.0.0.1", 0)
    result = PluginSpecHelper.run("wait_for", {"port" => server.local_address.port.to_s, "host" => "127.0.0.1", "timeout" => "3"})
    result["failed"].as_bool.should be_false
  ensure
    server.try(&.close)
  end

  it "succeeds immediately when state: stopped and the port is already closed" do
    result = PluginSpecHelper.run("wait_for", {"port" => "1", "state" => "stopped", "timeout" => "3"})
    result["failed"].as_bool.should be_false
  end

  it "succeeds immediately when a path already exists" do
    path = File.tempname("wait-for-spec")
    File.write(path, "x")

    result = PluginSpecHelper.run("wait_for", {"path" => path, "timeout" => "3"})
    result["failed"].as_bool.should be_false
    result["path"].as_s.should eq(path)
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "times out waiting for a missing path, with the file path in the message" do
    result = PluginSpecHelper.run("wait_for", {"path" => "/nonexistent/wait-for-spec-path", "timeout" => "1"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Timeout when waiting for file /nonexistent/wait-for-spec-path")
  end

  it "succeeds immediately when state: absent and the path is already missing" do
    result = PluginSpecHelper.run("wait_for", {"path" => "/nonexistent/wait-for-spec-path", "state" => "absent", "timeout" => "3"})
    result["failed"].as_bool.should be_false
  end

  it "matches search_regex against an existing file's content" do
    path = File.tempname("wait-for-spec")
    File.write(path, "some log line\nneedle here\nmore text\n")

    result = PluginSpecHelper.run("wait_for", {"path" => path, "search_regex" => "needle", "timeout" => "3"})
    result["failed"].as_bool.should be_false
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "times out with a search-string message when search_regex never matches" do
    path = File.tempname("wait-for-spec")
    File.write(path, "no match in here\n")

    result = PluginSpecHelper.run("wait_for", {"path" => path, "search_regex" => "needle", "timeout" => "1"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Timeout when waiting for search string needle in #{path}")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "never reports changed" do
    result = PluginSpecHelper.run("wait_for", {"timeout" => "0"})
    result["changed"].as_bool.should be_false
  end
end
