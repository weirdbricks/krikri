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

  it "reports a refused connect in fetch_url's URLError wording" do
    # Nothing ever listens on this bound-then-closed port; fetch_url covers
    # a connect failure in its URLError branch, whose msg is urllib's
    # "<urlopen error [Errno 111] Connection refused>" (issue #821,
    # alvistack.mitmproxy) - not the text of whatever curl printed, whose
    # wording varies by curl version and never carries the errno. The
    # branch mapped above is exit 22 (HTTP >= 400) only.
    socket = TCPServer.new("127.0.0.1", 0)
    port = socket.local_address.port
    socket.close

    shim = PluginSpecHelper.tmp_path("rpm-key-fetch-shim2-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(shim)
    rpm = File.join(shim, "rpm")
    File.write(rpm, "#!/bin/sh\nexit 0\n")
    File.chmod(rpm, 0o755)

    begin
      url = "http://127.0.0.1:#{port}/closed.key"
      result = PluginSpecHelper.run("rpm_key",
        {"key" => url, "state" => "present"},
        env: {"PATH" => "#{shim}:#{ENV["PATH"]?}"})
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_equal("failed to fetch key at #{url} , error was: Request failed: <urlopen error [Errno 111] Connection refused>")
    ensure
      FileUtils.rm_r(shim)
    end
  end

  it "reports an unresolvable key hostname in fetch_url's gaierror wording" do
    # Same URLError branch, DNS side: getaddrinfo's EAI_* pseudo-errno and
    # gai_strerror text ride inside "<urlopen error ...>" (live-verified vs
    # ansible-core 2.19.11: "[Errno -2] Name or service not known"). The
    # .invalid TLD never resolves, but which EAI code a resolver-less
    # environment reports differs, so only the shape is asserted.
    shim = PluginSpecHelper.tmp_path("rpm-key-fetch-shim3-#{Random::Secure.hex(4)}")
    FileUtils.mkdir_p(shim)
    rpm = File.join(shim, "rpm")
    File.write(rpm, "#!/bin/sh\nexit 0\n")
    File.chmod(rpm, 0o755)

    begin
      url = "http://nonexistent-krikri-issue-821.invalid/no.key"
      result = PluginSpecHelper.run("rpm_key",
        {"key" => url, "state" => "present"},
        env: {"PATH" => "#{shim}:#{ENV["PATH"]?}"})
      result["failed"].as_bool.must_equal(true)
      result["msg"].as_s.must_match(/\Afailed to fetch key at #{Regex.escape(url)} , error was: Request failed: <urlopen error \[Errno -\d+\] .+>\z/)
    ensure
      FileUtils.rm_r(shim)
    end
  end
end

# Issue #1438 (Amazon Linux 2023): state=absent with a `key:` URL failed with
# "Failed to get keyid" while ansible reported ok/unchanged. Real rpm_key's
# RpmKey.__init__ downloads a `://` key to a temp file before it looks at
# state, so the key ID for an absent task comes from the fetched material too.
# The fakes below let the whole path run without an RPM database: `gpg`
# reports a fixed key's colon dump (and records the path it was handed), `rpm`
# answers -q with the "installed" key ID (empty by default) and records --erase.
RPM_KEY_ABSENT_KEYID = "deadbeefcafeb00d"
RPM_KEY_ABSENT_FPR   = "ABCDEF0123456789ABCDEF0123456789ABCDEF01"

RPM_KEY_ABSENT_GPG_SHIM = <<-SH
#!/bin/sh
printf '%s\n' "$*" >> "${KRIKRI_FAKE_GPG_LOG:?}"
echo "pub:u:4096:1:#{RPM_KEY_ABSENT_KEYID}:1700000000:::u:::scESC::::::d:"
echo "fpr:::::::::#{RPM_KEY_ABSENT_FPR}:"
exit 0
SH

RPM_KEY_ABSENT_RPM_SHIM = <<-'SH'
#!/bin/sh
if [ "$1" = "-q" ]; then
  if [ -n "${KRIKRI_FAKE_RPM_INSTALLED:-}" ]; then
    printf '%s\n' "$KRIKRI_FAKE_RPM_INSTALLED"
    exit 0
  fi
  exit 1
fi
if [ "$1" = "--erase" ]; then
  printf '%s\n' "$*" >> "${KRIKRI_FAKE_RPM_LOG:?}"
  exit 0
fi
exit 0
SH

# Runs the block with a key-serving local HTTP server and shims first on the
# plugin's PATH, yielding the key URL plus the two log paths.
def with_absent_url_key_env(&)
  server = HTTP::Server.new do |context|
    context.response.status_code = 200
    context.response.print("-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nfake\n-----END PGP PUBLIC KEY BLOCK-----\n")
  end
  address = server.bind_tcp("127.0.0.1", 0)
  listening = Channel(Nil).new
  spawn do
    server.listen
    listening.send(nil)
  end

  shim = PluginSpecHelper.tmp_path("rpm-key-absent-url-shim-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(shim)
  {"gpg" => RPM_KEY_ABSENT_GPG_SHIM, "rpm" => RPM_KEY_ABSENT_RPM_SHIM}.each do |name, body|
    path = File.join(shim, name)
    File.write(path, body)
    File.chmod(path, 0o755)
  end
  gpg_log = PluginSpecHelper.tmp_path("rpm-key-absent-gpg-#{Random::Secure.hex(4)}.log")
  rpm_log = PluginSpecHelper.tmp_path("rpm-key-absent-rpm-#{Random::Secure.hex(4)}.log")

  begin
    yield "http://127.0.0.1:#{address.port}/linux_signing_key.pub", gpg_log, rpm_log,
      {"PATH" => "#{shim}:#{ENV["PATH"]?}", "KRIKRI_FAKE_GPG_LOG" => gpg_log, "KRIKRI_FAKE_RPM_LOG" => rpm_log}
  ensure
    server.close
    listening.receive
    FileUtils.rm_r(shim)
    File.delete?(gpg_log)
    File.delete?(rpm_log)
  end
end

describe "rpm_key state absent with a URL key (issue #1438)" do
  it "fetches the key and reports ok/unchanged when it is not imported" do
    with_absent_url_key_env do |url, gpg_log, rpm_log, env|
      result = PluginSpecHelper.run("rpm_key", {"key" => url, "state" => "absent"}, env: env)

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(false)
      # Ansible's success exits are bare exit_json(changed=...) - no msg key.
      result["msg"]?.must_be_nil
      # The key ID was derived from the downloaded file, never from the URL.
      File.read(gpg_log).must_include("--import ")
      File.read(gpg_log).wont_include("://")
      File.exists?(rpm_log).must_equal(false)
    end
  end

  it "erases the key when the fetched key is already imported" do
    with_absent_url_key_env do |url, _gpg_log, rpm_log, env|
      result = PluginSpecHelper.run("rpm_key", {"key" => url, "state" => "absent"},
        env: env.merge({"KRIKRI_FAKE_RPM_INSTALLED" => "cafeb00d"}))

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      File.read(rpm_log).must_include("--erase --allmatches gpg-pubkey-cafeb00d")
    end
  end
end
