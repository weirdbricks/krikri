require "../minitest_helper"
require "http/server"

# Issue 217 (ontic.kong, rocky): ansible's dnf module fetches an http(s) RPM
# name itself before any transaction (dnf.py _parse_spec_group_file ->
# module_utils/urls.py fetch_file), so a failed download is reported as
# "Failure downloading <url>, <fetch_url msg>" with a msg-only result. Krikri
# used to hand the URL to dnf, whose libdnf/curl stack failed with its own
# text under "Failed to install packages". The local server stands in for the
# remote host; a 404 is the one failure whose text is fully determined here.
private def with_local_rpm_server(status_code : Int32, &)
  server = HTTP::Server.new do |context|
    context.response.status_code = status_code
  end
  address = server.bind_tcp("127.0.0.1", 0)
  done = Channel(Nil).new
  spawn do
    server.listen
    done.send(nil)
  end
  begin
    yield "http://127.0.0.1:#{address.port}/krikri-spec-217.noarch.rpm"
  ensure
    server.close
    done.receive
  end
end

describe "dnf plugin remote rpm URL fetch (issue 217)" do
  it "reports a failed rpm URL download in fetch_file's wording, not dnf's" do
    with_local_rpm_server(404) do |url|
      result = PluginSpecHelper.run("dnf",
        {"name" => url, "state" => "present"},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Failure downloading #{url}, HTTP Error 404: Not Found")
      result.as_h.has_key?("rc").must_equal(false)
      result.as_h.has_key?("results").must_equal(false)
      result.as_h.has_key?("failures").must_equal(false)
    end
  end

  # Issue 754: real fetch_url downloads through urllib's default
  # ProxyHandler, which reads http_proxy/https_proxy/no_proxy from the
  # module process env - the env Ansible populates from the task's
  # environment: keyword. So a dead proxy listed there is USED: the
  # connect to it is refused and the failure is urllib's URLError text,
  # not the direct download's HTTP status.
  it "routes the rpm URL through the task environment http_proxy" do
    with_local_rpm_server(404) do |url|
      result = PluginSpecHelper.run("dnf",
        {"name" => url, "state" => "present",
         "_environment" => {"http_proxy" => "http://127.0.0.1:1"}.to_json},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal(
        "Failure downloading #{url}, Request failed: <urlopen error [Errno 111] Connection refused>")
    end
  end

  # urllib's proxy_bypass_environment: a no_proxy host-suffix match sends
  # the request direct even with a proxy set, so the origin's own error
  # (the 404) is what surfaces again.
  it "bypasses the proxy for a no_proxy host match" do
    with_local_rpm_server(404) do |url|
      result = PluginSpecHelper.run("dnf",
        {"name" => url, "state" => "present",
         "_environment" => {"http_proxy" => "http://127.0.0.1:1", "no_proxy" => "127.0.0.1"}.to_json},
        vars: {"ansible_pkg_mgr" => "dnf"})

      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("Failure downloading #{url}, HTTP Error 404: Not Found")
    end
  end
end
