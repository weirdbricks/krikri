require "../minitest_helper"
require "http/server"

# Issue #339 (derjd.podman, Rocky): rpm_key's `failed to fetch key at <url>
# , error was: <err>` message. Real rpm_key fetches through fetch_url, so an
# HTTP error status reports urllib's "HTTP Error <code>: <reason phrase>"
# (no trailing newline), not the text of whatever curl printed - which is
# what the old bare-curl plumbing surfaced ("curl: (22) The requested URL
# returned error: 404"). The local server stands in for the unreachable key
# URL; 404 is the one failure whose whole message is fully determined here.
# A fake `rpm` sits first on the plugin's own PATH so the module's `command
# -v rpm` precondition passes without any RPM database on this host - the
# fetch failure fires before rpm/gpg are ever asked for key material.
describe "rpm_key URL fetch failure message (issue #339)" do
  it "reports an HTTP error status in fetch_url's urllib wording" do
    server = HTTP::Server.new do |context|
      context.response.status_code = 404
    end
    address = server.bind_tcp("127.0.0.1", 0)
    done = Channel(Nil).new
    spawn do
      server.listen
      done.send(nil)
    end
    url = "http://127.0.0.1:#{address.port}/krikri-issue-339.noarch.rpm.key"

    shim = PluginSpecHelper.tmp_path("rpm-key-fetch-shim-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(shim)
    rpm = File.join(shim, "rpm")
    File.write(rpm, "#!/bin/sh\nexit 0\n")
    File.chmod(rpm, 0o755)

    begin
      result = PluginSpecHelper.run("rpm_key", {"key" => url, "state" => "present"},
        env: {"PATH" => "#{shim}:#{ENV["PATH"]?}"})
      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("failed to fetch key at #{url} , error was: HTTP Error 404: Not Found")
    ensure
      server.close
      done.receive
      FileUtils.rm_r(shim)
    end
  end

  it "keeps curl's own stderr wording for a non-HTTP-status failure" do
    # Nothing ever listens on this bound-then-closed port; curl fails with
    # its own "Connection refused" (exit 7), which fetch_url covers
    # separately from the HTTPError branch and which curl's stderr still
    # describes - the branch mapped above is exit 22 (HTTP >= 400) only.
    socket = TCPServer.new("127.0.0.1", 0)
    port = socket.local_address.port
    socket.close

    shim = PluginSpecHelper.tmp_path("rpm-key-fetch-shim2-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(shim)
    rpm = File.join(shim, "rpm")
    File.write(rpm, "#!/bin/sh\nexit 0\n")
    File.chmod(rpm, 0o755)

    begin
      result = PluginSpecHelper.run("rpm_key",
        {"key" => "http://127.0.0.1:#{port}/closed.key", "state" => "present"},
        env: {"PATH" => "#{shim}:#{ENV["PATH"]?}"})
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_match(/\Afailed to fetch key at .+ , error was: curl: \(\d+\) /)
    ensure
      FileUtils.rm_r(shim)
    end
  end
end
