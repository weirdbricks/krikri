require "../minitest_helper"
require "socket"

# Pins plugins/get_certificate.cr's native connection attempt against
# real community.crypto.get_certificate: the module connects natively
# (socket.create_connection, or an explicit hop to the proxy pair when
# proxy_host is set) and wraps ANY connection exception in the same
# fail_json - its `error: {e}` tail is the raw Python exception text
# (gaierror "[Errno -2] Name or service not known" for a DNS failure,
# OSError "[Errno 111] Connection refused" for a closed port).
describe "get_certificate connection errors" do
  it "reports a DNS failure with Python's gaierror text" do
    result = PluginSpecHelper.run("get_certificate", {
      "host" => "krikri-dns-probe-test.invalid",
      "port" => "443",
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Failed to get cert from krikri-dns-probe-test.invalid:443, error: [Errno -2] Name or service not known")
  end

  it "reports a refused connection with Python's OSError text" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close

    result = PluginSpecHelper.run("get_certificate", {
      "host" => "127.0.0.1",
      "port" => port.to_s,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Failed to get cert from 127.0.0.1:#{port}, error: [Errno 111] Connection refused")
  end

  it "reports a refused proxy hop via the via-proxy message" do
    server = TCPServer.new("127.0.0.1", 0)
    port = server.local_address.port
    server.close

    result = PluginSpecHelper.run("get_certificate", {
      "host"       => "example.com",
      "port"       => "443",
      "proxy_host" => "127.0.0.1",
      "proxy_port" => port.to_s,
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Failed to get cert via proxy 127.0.0.1:#{port} from example.com:443, error: [Errno 111] Connection refused")
  end

  # TEST-NET-1 (192.0.2.0/24) is reserved for documentation, so nothing
  # answers and the connect is still in flight when the deadline expires.
  it "reports a connect the kernel never answers with Python's TimeoutError text" do
    started = Time.instant
    result = PluginSpecHelper.run("get_certificate", {
      "host"    => "192.0.2.1",
      "port"    => "81",
      "timeout" => "1",
    })
    elapsed = Time.instant - started

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("Failed to get cert from 192.0.2.1:81, error: timed out")
    # The module applies `timeout` as setdefaulttimeout(), so the connect has
    # to give up on that deadline - not on the kernel's own SYN retries.
    (elapsed < 8.seconds).must_equal(true)
  end

  it "applies the same timeout to the proxy hop" do
    started = Time.instant
    result = PluginSpecHelper.run("get_certificate", {
      "host"       => "example.com",
      "port"       => "443",
      "proxy_host" => "192.0.2.1",
      "proxy_port" => "81",
      "timeout"    => "1",
    })
    elapsed = Time.instant - started

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal(
      "Failed to get cert via proxy 192.0.2.1:81 from example.com:443, error: timed out")
    (elapsed < 8.seconds).must_equal(true)
  end
end
