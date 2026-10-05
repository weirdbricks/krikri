require "../minitest_helper"
require "socket"

describe "wait_for plugin" do
  it "fails clearly when both path and port are given" do
    result = PluginSpecHelper.run("wait_for", {"port" => "80", "path" => "/etc/hostname"})
    result["failed"].as_bool.must_equal(true)
  end

  it "is skipped under check_mode, matching real Ansible's own skip text" do
    result = PluginSpecHelper.run("wait_for", {"timeout" => "1", "_ansible_check_mode" => "true"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["skipped"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("remote module (wait_for) does not support check mode")
  end

  it "times out waiting for a closed port, with host:port in the message" do
    result = PluginSpecHelper.run("wait_for", {"port" => "1", "host" => "127.0.0.1", "timeout" => "1", "connect_timeout" => "1"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Timeout when waiting for 127.0.0.1:1")
  end

  it "honors a custom msg: on timeout" do
    result = PluginSpecHelper.run("wait_for", {"port" => "1", "timeout" => "1", "msg" => "custom timeout message"})
    result["msg"].as_s.must_equal("custom timeout message")
  end

  it "succeeds immediately when an open port is already listening" do
    server = TCPServer.new("127.0.0.1", 0)
    result = PluginSpecHelper.run("wait_for", {"port" => server.local_address.port.to_s, "host" => "127.0.0.1", "timeout" => "3"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  ensure
    server.try(&.close)
  end

  it "succeeds immediately when state: stopped and the port is already closed" do
    result = PluginSpecHelper.run("wait_for", {"port" => "1", "state" => "stopped", "timeout" => "3"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  it "succeeds immediately when a path already exists" do
    path = File.tempname("wait-for-spec")
    File.write(path, "x")

    result = PluginSpecHelper.run("wait_for", {"path" => path, "timeout" => "3"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    result["path"].as_s.must_equal(path)
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "times out waiting for a missing path, with the file path in the message" do
    result = PluginSpecHelper.run("wait_for", {"path" => "/nonexistent/wait-for-spec-path", "timeout" => "1"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Timeout when waiting for file /nonexistent/wait-for-spec-path")
  end

  it "succeeds immediately when state: absent and the path is already missing" do
    result = PluginSpecHelper.run("wait_for", {"path" => "/nonexistent/wait-for-spec-path", "state" => "absent", "timeout" => "3"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  it "matches search_regex against an existing file's content" do
    path = File.tempname("wait-for-spec")
    File.write(path, "some log line\nneedle here\nmore text\n")

    result = PluginSpecHelper.run("wait_for", {"path" => path, "search_regex" => "needle", "timeout" => "3"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "times out with a search-string message when search_regex never matches" do
    path = File.tempname("wait-for-spec")
    File.write(path, "no match in here\n")

    result = PluginSpecHelper.run("wait_for", {"path" => path, "search_regex" => "needle", "timeout" => "1"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Timeout when waiting for search string needle in #{path}")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  describe "search_regex against an open socket (not just a file)" do
    # Real bug found via a proactive scope-cut audit: search_regex was
    # only ever matched against a file's content, never against data
    # read from an open port - the real module's own
    # source connects, then reads (accumulating bytes) until the regex
    # matches, the connection closes, or the overall timeout passes.
    it "succeeds once the server sends data matching the regex" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      spawn do
        client = server.accept
        client.puts "starting up..."
        sleep 50.milliseconds
        client.puts "server ready OpenSSH_9.0"
        client.flush
      end

      result = PluginSpecHelper.run("wait_for", {
        "port" => port.to_s, "host" => "127.0.0.1", "search_regex" => "OpenSSH", "timeout" => "5",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    ensure
      server.try(&.close)
    end

    it "times out with real Ansible's own search-string message when the regex never appears" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      spawn do
        client = server.accept
        client.puts "nothing relevant here"
        client.flush
      end

      result = PluginSpecHelper.run("wait_for", {
        "port" => port.to_s, "host" => "127.0.0.1", "search_regex" => "NEVER_APPEARS_XYZ", "timeout" => "1",
      })

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Timeout when waiting for search string NEVER_APPEARS_XYZ in 127.0.0.1:#{port}")
    ensure
      server.try(&.close)
    end
  end

  it "never reports changed" do
    result = PluginSpecHelper.run("wait_for", {"timeout" => "0"})
    # Real's wait_for wire carries no changed at all (exit_json passes
    # none; the task executor backfills failed, changed onto the
    # registered result).
    result["changed"]?.must_equal(nil)
  end

  it "fails clearly when state: drained is given without a port:" do
    result = PluginSpecHelper.run("wait_for", {"state" => "drained", "timeout" => "1"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("state: drained should only be used for checking a port in the wait_for module")
  end

  it "fails clearly when exclude_hosts: is given without state: drained" do
    result = PluginSpecHelper.run("wait_for", {"port" => "80", "exclude_hosts" => "10.0.0.1", "timeout" => "1"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("exclude_hosts should only be with state=drained")
  end

  it "fails clearly for a non-IPv4 host: with state: drained" do
    result = PluginSpecHelper.run("wait_for", {"port" => "80", "state" => "drained", "host" => "::1", "timeout" => "1"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("state: drained only supports a literal IPv4 host:")
  end

  it "succeeds immediately with state: drained on a port nothing is connected to" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close # closed immediately - never actually accepted a connection

    result = PluginSpecHelper.run("wait_for", {"port" => port.to_s, "state" => "drained", "timeout" => "3"})
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  end

  it "times out with state: drained while a real ESTABLISHED connection is still open on that port" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    client = TCPSocket.new("127.0.0.1", port)
    accepted = server.accept

    result = PluginSpecHelper.run("wait_for", {"port" => port.to_s, "state" => "drained", "timeout" => "1", "sleep" => "1"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Timeout when waiting for 127.0.0.1:#{port} to drain")
  ensure
    client.try(&.close)
    accepted.try(&.close)
    server.try(&.close)
  end

  it "reports drained once active_connection_states: is scoped away from the connection's actual state" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    client = TCPSocket.new("127.0.0.1", port)
    accepted = server.accept

    # The real connection is ESTABLISHED, not SYN_SENT - scoping
    # active_connection_states: to a state that can never match proves
    # the parameter is actually threaded through, not just accepted and
    # ignored.
    result = PluginSpecHelper.run("wait_for", {
      "port" => port.to_s, "state" => "drained", "active_connection_states" => "SYN_SENT", "timeout" => "3",
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
  ensure
    client.try(&.close)
    accepted.try(&.close)
    server.try(&.close)
  end
end
