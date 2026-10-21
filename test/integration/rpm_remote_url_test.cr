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
end
