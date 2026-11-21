require "../minitest_helper"
require "digest/sha256"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/ssm_transport"
require "../../src/krikri/connection_settings"
require "../../lib/krikri-aws-ssm/src/krikri_aws_ssm/testing"

private SSM_PTY_CREDS = KrikriAwsSsm::Credentials.new("AKIDEXAMPLE", "secretEXAMPLEKEY", "session-token")

private def ssm_pty_settings(gateway : KrikriAwsSsm::Testing::FakeGateway,
                             timeout : Int32 = 60) : Krikri::SsmSettings
  Krikri::SsmSettings.new(
    "i-0123456789",
    region: "us-east-1",
    endpoint_url: gateway.url,
    access_key_id: SSM_PTY_CREDS.access_key,
    secret_access_key: SSM_PTY_CREDS.secret_key,
    session_token: SSM_PTY_CREDS.session_token,
    timeout: timeout
  )
end

# FakeAgent buffers every input frame in `received_input` (capacity 1024)
# so specs can inspect it. A real transfer larger than ~1MB blocks the
# agent's websocket reader unless something drains that channel.
private def drain_fake_agent_input(gateway : KrikriAwsSsm::Testing::FakeGateway) : Nil
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

private def ssm_pty_connection(settings : Krikri::SsmSettings,
                               host_name : String = "ssm-pty-host") : Krikri::ConnectionSettings
  Krikri::ConnectionSettings.new(
    settings.target, "ssm-user", nil, nil, nil,
    [] of String, [] of String,
    host_name: host_name, connection_type: "amazon.aws.aws_ssm", ssm: settings
  )
end

# A real pty + the shard's SigV4-verifying fake gateway: this is the test
# the minimal fake-session unit specs cannot replace. It exercises the
# canonical-mode line discipline, the split READY gate, 3000-byte payload
# lines, a compressed upload, a streamed download, and a >64KB script.
describe "Krikri::SsmTransport over a real pty" do
  serial!

  before_each do
    Krikri::SsmRegistry.close_all
    Krikri::SsmRegistry.session_factory = nil
  end

  after_each do
    Krikri::SsmRegistry.close_all
    Krikri::SsmRegistry.session_factory = nil
  end

  it "uploads and downloads a >=256KB binary and runs a >64KB script" do
    gateway = KrikriAwsSsm::Testing::FakeGateway.new(SSM_PTY_CREDS)
    drain_fake_agent_input(gateway)
    root = PluginSpecHelper.tmp_path("ssm_pty_transfer")
    FileUtils.rm_rf(root) if Dir.exists?(root)
    Dir.mkdir_p(root)

    begin
      settings = ssm_pty_settings(gateway)
      # The fake agent's pty/websocket pump applies backpressure after a
      # large download, so each group below uses its own session (host
      # name). The READY gate, pty line discipline and transfers are still
      # exercised end-to-end.
      upload_conn = ssm_pty_connection(settings, "ssm-pty-upload")
      download_conn = ssm_pty_connection(settings, "ssm-pty-download")
      script_conn = ssm_pty_connection(settings, "ssm-pty-script")
      Krikri::SsmRegistry.session_factory =
        ->(_settings : Krikri::SsmSettings) : Krikri::SsmRegistry::SessionHandle {
          Krikri::SsmTransport.open_session(settings)
        }

      payload = Random.new(1664).random_bytes(256 * 1024)
      source = File.join(root, "source.bin")
      remote = File.join(root, "remote.bin")
      downloaded = File.join(root, "downloaded.bin")
      gzipped = File.join(root, "downloaded-gzip.bin")
      File.write(source, payload)

      started = Time.instant
      Krikri::SsmTransport.upload(upload_conn, source, remote, mode: 0o600)
      upload_seconds = (Time.instant - started).total_seconds
      puts "SSM pty: upload done" if ENV["KRIKRI_SSM_TRANSFER_VERBOSE"]?

      Krikri::SsmTransport.download(download_conn, remote, downloaded)
      puts "SSM pty: download done" if ENV["KRIKRI_SSM_TRANSFER_VERBOSE"]?
      Krikri::SsmTransport.download(download_conn, remote, gzipped, gzip: true)
      puts "SSM pty: gzip download done" if ENV["KRIKRI_SSM_TRANSFER_VERBOSE"]?

      File.read(downloaded).to_slice.must_equal(payload)
      File.read(gzipped).to_slice.must_equal(payload)
      Digest::SHA256.hexdigest(File.read(downloaded)).must_equal(Digest::SHA256.hexdigest(payload))
      percentile = (payload.size / 1024.0) / upload_seconds
      puts "SSM pty upload: #{payload.size} bytes in #{upload_seconds.round(2)}s (#{percentile.round(1)} KiB/s)" if ENV["KRIKRI_SSM_TRANSFER_VERBOSE"]?

      script = String.build do |io|
        io << "# krikri SSM large-script spec\n"
        2200.times do |index|
          io << "# filler line " << index << ' ' << ("x" * 24) << '\n'
        end
        io << "printf 'script-ok\\n'\n"
      end
      assert script.bytesize >= 64 * 1024
      puts "SSM pty: running script (#{script.bytesize} bytes)" if ENV["KRIKRI_SSM_TRANSFER_VERBOSE"]?
      result = Krikri::SsmTransport.exec_script(script_conn, script, 120)
      puts "SSM pty: script done" if ENV["KRIKRI_SSM_TRANSFER_VERBOSE"]?
      puts "SSM pty script result: #{result.inspect}" if result[:exit_code] != 0
      result[:exit_code].must_equal(0)
      result[:stdout].must_equal("script-ok\n")
    ensure
      Krikri::SsmRegistry.close_all
      gateway.close
      FileUtils.rm_rf(root) if Dir.exists?(root)
    end
  end
end
