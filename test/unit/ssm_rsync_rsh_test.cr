require "../minitest_helper"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/ssm_rsync_rsh"
require "../../lib/krikri-aws-ssm/src/krikri_aws_ssm/testing"

private SSM_RSH_CREDS = KrikriAwsSsm::Credentials.new("AKIDEXAMPLE", "secretEXAMPLEKEY", "session-token")

private def ssm_rsh_settings(gateway : KrikriAwsSsm::Testing::FakeGateway,
                             timeout : Int32 = 60) : Krikri::SsmSettings
  Krikri::SsmSettings.new(
    "i-0123456789",
    region: "us-east-1",
    endpoint_url: gateway.url,
    access_key_id: SSM_RSH_CREDS.access_key,
    secret_access_key: SSM_RSH_CREDS.secret_key,
    session_token: SSM_RSH_CREDS.session_token,
    timeout: timeout
  )
end

# FakeAgent buffers every input frame in `received_input` (capacity 1024); a
# real transfer blocks the agent's websocket reader unless something drains
# that channel.
private def drain_ssm_rsh_agent_input(gateway : KrikriAwsSsm::Testing::FakeGateway) : Nil
  spawn do
    while agent = gateway.agents.receive?
      spawn do
        loop do
          break unless agent.received_input.receive?
        end
      end
    end
  end
end

private def with_ssm_rsh_env(payload : Hash(String, String), &)
  previous = {} of String => String?
  payload.each do |key, value|
    previous[key] = ENV[key]?
    ENV[key] = value
  end
  yield
ensure
  previous.try &.each do |key, value|
    if value
      ENV[key] = value
    else
      ENV.delete(key)
    end
  end
end

describe "Krikri::SsmRsyncRsh" do
  serial!

  before_each do
    Krikri::SsmRegistry.close_all
    Krikri::SsmRegistry.session_factory = nil
  end

  after_each do
    Krikri::SsmRegistry.close_all
    Krikri::SsmRegistry.session_factory = nil
  end

  it "prunes stale runner scripts, status files and stderr files" do
    script = Krikri::SsmRsyncRsh.staging_check_script(
      "/var/tmp/.krikri-staging/plugins", "/var/tmp/.krikri-staging/plugins/krikri-ssm-pipe-abc123")

    # Only a successful run consumes the runner's status/stderr files, so
    # the stale sweep must cover every krikri-ssm-rsync-* shape (the old
    # .sh-only glob leaked krikri-ssm-rsync-status-*.txt forever).
    script.must_include("for F in /var/tmp/.krikri-staging/plugins/krikri-ssm-pipe-* /var/tmp/.krikri-staging/plugins/krikri-ssm-rsync-*; do ")
    script.wont_include("krikri-ssm-rsync-*.sh")
  end

  it "uploads a raw-mode runner that runs the bridge under a status trap" do
    script = Krikri::SsmRsyncRsh.remote_script_body(
      "rsync --server -logDtpre.iLsfxC . /tmp/dest/", "/tmp/krikri-ssm-pipe-abc123")

    script.must_include("rm -f \"$0\"\n")
    # The marker goes out only after raw mode is on (and a failed stty is
    # fatal, so the client never writes binary into a canonical terminal).
    # Its two halves are printed separately: an echoed launch line can then
    # never contain the concatenated marker.
    script.must_include("stty raw -echo 2>/dev/null || exit 125\nprintf '\\n%s%s\\n' \"$KRIKRI_SSM_PIPE_START_A\" \"$KRIKRI_SSM_PIPE_START_B\"\n")
    # A --probe run happens before the marker so exec-format/loader errors
    # reach the client as text.
    script.must_include("BRIDGE=/tmp/krikri-ssm-pipe-abc123\n")
    script.must_include("if ! OUT=$(\"$BRIDGE\" --probe 2>&1); then")
    # The real agent does not deliver an ExitCode payload for every session,
    # so an EXIT trap writes the bridge's status to a file the helper reads
    # over a fresh session.
    script.must_include("trap 'rc=$?; (umask 077; printf \"%d\\n\" \"$rc\" > \"$KRIKRI_SSM_PIPE_STATUS\") 2>/dev/null' EXIT")
    # The bridge gives the command real pipes; it is NOT exec'd, so the
    # shell survives to run the trap.
    script.must_include("\"$BRIDGE\" rsync --server -logDtpre.iLsfxC . /tmp/dest/ 2>/dev/null\n")
  end

  it "moves a binary stream through the pty and returns the command's status" do
    gateway = KrikriAwsSsm::Testing::FakeGateway.new(SSM_RSH_CREDS)
    drain_ssm_rsh_agent_input(gateway)
    begin
      settings = ssm_rsh_settings(gateway)
      Krikri::SsmRegistry.session_factory =
        ->(_settings : Krikri::SsmSettings) : Krikri::SsmRegistry::SessionHandle {
          Krikri::SsmTransport.open_session(settings)
        }

      previous_bridge = Krikri::SsmRsyncRsh.bridge_for_spec
      Krikri::SsmRsyncRsh.bridge_for_spec = File.expand_path("../../bin/krikri-ssm-pipe", __DIR__)
      payload = Bytes.new(64 * 1024) { |index| ((index * 37) & 0xFF).to_u8 }
      input = IO::Memory.new(payload)
      output = IO::Memory.new
      error = IO::Memory.new

      status = with_ssm_rsh_env(Krikri::SsmRsyncRsh.env_for(settings, 20)) do
        Krikri::SsmRsyncRsh.run(["i-0123456789", "head -c #{payload.size}"], input, output, error)
      end

      status.must_equal(0)
      output.to_slice.must_equal(payload)
      error.to_s.must_equal("")
    ensure
      Krikri::SsmRsyncRsh.bridge_for_spec = previous_bridge
      Krikri::SsmRegistry.close_all
      gateway.close
    end
  end

  it "falls back to the pipe's verdict when the status file cannot be read" do
    gateway = KrikriAwsSsm::Testing::FakeGateway.new(SSM_RSH_CREDS)
    drain_ssm_rsh_agent_input(gateway)
    path_file = File.tempname("krikri-spec-status-path")
    previous_bridge = Krikri::SsmRsyncRsh.bridge_for_spec
    begin
      settings = ssm_rsh_settings(gateway)
      Krikri::SsmRegistry.session_factory =
        ->(_settings : Krikri::SsmSettings) : Krikri::SsmRegistry::SessionHandle {
          Krikri::SsmTransport.open_session(settings)
        }
      Krikri::SsmRsyncRsh.bridge_for_spec = File.expand_path("../../bin/krikri-ssm-pipe", __DIR__)
      input = IO::Memory.new
      output = IO::Memory.new
      error = IO::Memory.new

      # The command replaces the status file with a directory, so the EXIT
      # trap's redirect fails however privileged the user is and the helper
      # cannot learn the command's status at all - the pipe's own verdict is
      # all that is left.
      command = %(sh -c 'printf "%s" "$KRIKRI_SSM_PIPE_STATUS" > #{path_file}; rm -f "$KRIKRI_SSM_PIPE_STATUS"; mkdir "$KRIKRI_SSM_PIPE_STATUS"; exit 3')
      status = with_ssm_rsh_env(Krikri::SsmRsyncRsh.env_for(settings, 20)) do
        Krikri::SsmRsyncRsh.run(["i-0123456789", command], input, output, error)
      end

      # The pipe's own verdict is all that is left: the fake agent reports
      # the runner's exit code here, while a real agent delivers none and
      # the fallback becomes 255.
      status.must_equal(3)
      error.to_s.must_include("rsync pipe closed without a readable exit status")
    ensure
      Krikri::SsmRsyncRsh.bridge_for_spec = previous_bridge
      Krikri::SsmRegistry.close_all
      if File.exists?(path_file)
        status_path = File.read(path_file).strip
        Dir.delete(status_path) if Dir.exists?(status_path)
        File.delete(path_file)
      end
      gateway.close
    end
  end

  it "never passes a non-positive timeout into the pipe's idle cap" do
    settings = Krikri::SsmSettings.new("i-0123456789")
    key = Krikri::SsmRsyncRsh::ENV_TIMEOUT

    Krikri::SsmRsyncRsh.env_for(settings, 0).has_key?(key).must_equal(false)
    Krikri::SsmRsyncRsh.env_for(settings, -5).has_key?(key).must_equal(false)
    Krikri::SsmRsyncRsh.env_for(settings, 30)[key].must_equal("30")
  end

  it "surfaces what the target wrote when the bridge never starts" do
    gateway = KrikriAwsSsm::Testing::FakeGateway.new(SSM_RSH_CREDS)
    drain_ssm_rsh_agent_input(gateway)
    junk = File.tempname("krikri-ssm-pipe-junk", ".bin")
    begin
      File.write(junk, "this is not an executable\n")
      File.chmod(junk, 0o755)
      settings = ssm_rsh_settings(gateway)
      Krikri::SsmRegistry.session_factory =
        ->(_settings : Krikri::SsmSettings) : Krikri::SsmRegistry::SessionHandle {
          Krikri::SsmTransport.open_session(settings)
        }
      previous_bridge = Krikri::SsmRsyncRsh.bridge_for_spec
      Krikri::SsmRsyncRsh.bridge_for_spec = junk
      output = IO::Memory.new
      error = IO::Memory.new

      status = with_ssm_rsh_env(Krikri::SsmRsyncRsh.env_for(settings, 10)) do
        Krikri::SsmRsyncRsh.run(["i-0123456789", "cat"], IO::Memory.new, output, error)
      end

      # The runner's exit code rides along with the diagnostic text.
      status.must_equal(126)
      error.to_s.must_include("before the target started the bridge")
      error.to_s.must_include("cannot execute")
    ensure
      Krikri::SsmRsyncRsh.bridge_for_spec = previous_bridge
      Krikri::SsmRegistry.close_all
      gateway.close
      File.delete(junk) if File.exists?(junk)
    end
  end

  it "fails fast when the target bridge binary is missing" do
    previous_bridge = Krikri::SsmRsyncRsh.bridge_for_spec
    begin
      Krikri::SsmRsyncRsh.bridge_for_spec = "/nonexistent/krikri-ssm-pipe"
      settings = Krikri::SsmSettings.new("i-0123456789")
      output = IO::Memory.new
      error = IO::Memory.new
      status = with_ssm_rsh_env(Krikri::SsmRsyncRsh.env_for(settings, 5)) do
        Krikri::SsmRsyncRsh.run(["i-0123456789", "cat"], IO::Memory.new, output, error)
      end

      status.must_equal(255)
      error.to_s.must_include("target bridge not found")
    ensure
      Krikri::SsmRsyncRsh.bridge_for_spec = previous_bridge
    end
  end

  it "gives up after the idle window when the pipe produces no output" do
    gateway = KrikriAwsSsm::Testing::FakeGateway.new(SSM_RSH_CREDS)
    drain_ssm_rsh_agent_input(gateway)
    begin
      settings = ssm_rsh_settings(gateway)
      Krikri::SsmRegistry.session_factory =
        ->(_settings : Krikri::SsmSettings) : Krikri::SsmRegistry::SessionHandle {
          Krikri::SsmTransport.open_session(settings)
        }
      previous_bridge = Krikri::SsmRsyncRsh.bridge_for_spec
      Krikri::SsmRsyncRsh.bridge_for_spec = File.expand_path("../../bin/krikri-ssm-pipe", __DIR__)
      output = IO::Memory.new
      error = IO::Memory.new

      status = with_ssm_rsh_env(Krikri::SsmRsyncRsh.env_for(settings, 2)) do
        Krikri::SsmRsyncRsh.run(["i-0123456789", "sleep 30"], IO::Memory.new, output, error)
      end

      status.must_equal(124)
      error.to_s.must_include("without output")
    ensure
      Krikri::SsmRsyncRsh.bridge_for_spec = previous_bridge
      Krikri::SsmRegistry.close_all
      gateway.close
    end
  end

  it "reports a failing command's status" do
    gateway = KrikriAwsSsm::Testing::FakeGateway.new(SSM_RSH_CREDS)
    drain_ssm_rsh_agent_input(gateway)
    begin
      settings = ssm_rsh_settings(gateway)
      Krikri::SsmRegistry.session_factory =
        ->(_settings : Krikri::SsmSettings) : Krikri::SsmRegistry::SessionHandle {
          Krikri::SsmTransport.open_session(settings)
        }

      previous_bridge = Krikri::SsmRsyncRsh.bridge_for_spec
      Krikri::SsmRsyncRsh.bridge_for_spec = File.expand_path("../../bin/krikri-ssm-pipe", __DIR__)
      output = IO::Memory.new
      error = IO::Memory.new
      status = with_ssm_rsh_env(Krikri::SsmRsyncRsh.env_for(settings, 20)) do
        Krikri::SsmRsyncRsh.run(
          ["i-0123456789", "sh -c 'echo boom >&2; exit 3'"],
          IO::Memory.new, output, error)
      end

      status.must_equal(3)
      output.to_s.must_equal("")
      # The command's stderr now travels in the runner's stderr file and is
      # forwarded to the helper's stderr.
      error.to_s.must_include("boom")
    ensure
      Krikri::SsmRsyncRsh.bridge_for_spec = previous_bridge
      Krikri::SsmRegistry.close_all
      gateway.close
    end
  end
end
