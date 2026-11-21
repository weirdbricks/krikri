require "../minitest_helper"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/ssm_transport"
require "../../src/krikri/connection_settings"

# A shell that answers the transport's markers without a network or pty:
# the prep line gets its sentinel, and a command line gets one fixed
# stdout/exit-code/end-marker sequence.
class FakeSsmShellSession
  include Krikri::SsmRegistry::SessionHandle

  getter writes = [] of String
  getter command_seen = Channel(String).new(8)
  property gate : Channel(Nil)?

  @outputs = Channel(KrikriAwsSsm::Output?).new(32)
  @closed = false
  @pending_markers : Array(String)? = nil

  def write(bytes : Bytes) : Nil
    write(String.new(bytes))
  end

  def write(text : String) : Nil
    @writes << text
    text.each_line do |raw_line|
      handle(raw_line.chomp)
    end
  end

  def read? : KrikriAwsSsm::Output?
    @outputs.receive?
  end

  def closed? : Bool
    @closed
  end

  def close_reason : KrikriAwsSsm::CloseReason?
    nil
  end

  def error : Exception?
    nil
  end

  def exit_code : Int32?
    nil
  end

  def terminate : Nil
    @closed = true
    @outputs.close
  end

  def resume : Nil
  end

  private def emit(text : String) : Nil
    @outputs.send(KrikriAwsSsm::Output.new(KrikriAwsSsm::Stream::Stdout, text.to_slice)) unless @closed
  end

  private def handle(line : String) : Nil
    if line.includes?("stty -echo")
      if first = line.scan(/KRIKRI-SSM-[0-9a-f]+-/).first?
        emit(first[0] + "KRIKRI\n")
      end
      return
    end

    if ready = line.scan(/KRIKRI-SSM-READY-[0-9a-f]+-/).first?
      markers = line.scan(/KRIKRI-SSM-(?:BEGIN|END)-[0-9a-f]+/).map(&.[0])
      @pending_markers = markers.size >= 2 ? markers : nil
      emit(ready[0] + "READY\n")
      return
    end

    # The base64 payload follows the bootstrap command line; emit the
    # fixed result on its first line, then go back to ignoring input.
    if pending = @pending_markers
      @pending_markers = nil
      emit("\n#{pending[0]}\n")
      emit("hello\n")
      emit("\n0\n")
      emit("#{pending[1]}\n")
      return
    end

    markers = line.scan(/KRIKRI-SSM-(?:BEGIN|END)-[0-9a-f]+/).map(&.[0])
    return unless markers.size >= 2
    start = markers[0]
    finish = markers[1]
    @command_seen.send(line)
    if gate = @gate
      gate.receive
    end
    emit("\n#{start}\n")
    emit("hello\n")
    emit("\n0\n")
    emit("#{finish}\n")
  end
end

private def ssm_test_connection(settings : Krikri::SsmSettings) : Krikri::ConnectionSettings
  Krikri::ConnectionSettings.new(
    settings.target, "ssm-user", nil, nil, nil,
    [] of String, [] of String,
    host_name: "web1", connection_type: "aws_ssm", ssm: settings
  )
end

private def install_fake_ssm_session : FakeSsmShellSession
  fake = FakeSsmShellSession.new
  Krikri::SsmRegistry.session_factory =
    ->(_settings : Krikri::SsmSettings) : Krikri::SsmRegistry::SessionHandle { fake }
  fake
end

describe Krikri::SsmTransport do
  serial!

  before_each do
    Krikri::SsmRegistry.close_all
    Krikri::SsmRegistry.session_factory = nil
  end

  after_each do
    Krikri::SsmRegistry.close_all
    Krikri::SsmRegistry.session_factory = nil
  end

  describe ".wrapped_base64_size" do
    it "matches the exact newline-wrapped size the streaming writer emits" do
      Krikri::SsmTransport.wrapped_base64_size(0_i64).must_equal(0_i64)
      Krikri::SsmTransport.wrapped_base64_size(1_i64).must_equal(5_i64) # 4 chars + newline
      Krikri::SsmTransport.wrapped_base64_size(2250_i64).must_equal(3001_i64)
      Krikri::SsmTransport.wrapped_base64_size(2251_i64).must_equal(3001_i64 + 5_i64)
      # A 40MB source: 4/3 base64 expansion plus one newline per 3000 chars.
      size = 40_i64 * 1024 * 1024
      encoded = 4_i64 * ((size + 2) // 3)
      expected = encoded + (encoded + 2999) // 3000
      Krikri::SsmTransport.wrapped_base64_size(size).must_equal(expected)
    end
  end

  describe ".parse_exec_output" do
    it "discards the banner, strips CRs and splits stdout from the exit code" do
      raw = "welcome banner\r\n" \
            "\nBEGIN-MARK\r\n" \
            "hello\r\n" \
            "\r\n" \
            "0\r\n" \
            "END-MARK\r\n"
      parsed = Krikri::SsmTransport.parse_exec_output(raw, "warn\r\n", "BEGIN-MARK", "END-MARK") ||
               raise "expected the markers to parse"
      parsed[:exit_code].must_equal(0)
      parsed[:stdout].must_equal("hello\n")
      parsed[:stderr].must_equal("warn\n")
    end

    it "keeps a nonzero exit code and output without a trailing newline" do
      raw = "BEGIN-MARK\nboom\n42\nEND-MARK\n"
      parsed = Krikri::SsmTransport.parse_exec_output(raw, "", "BEGIN-MARK", "END-MARK") ||
               raise "expected the markers to parse"
      parsed[:exit_code].must_equal(42)
      parsed[:stdout].must_equal("boom")
    end

    it "returns nil when either marker is missing" do
      Krikri::SsmTransport.parse_exec_output("BEGIN-MARK\nhi\n\n0\n", "", "BEGIN-MARK", "END-MARK").must_be_nil
      Krikri::SsmTransport.parse_exec_output("hi\n\n0\n", "", "BEGIN-MARK", "END-MARK").must_be_nil
    end
  end

  it "runs a command through the registry's session" do
    fake = install_fake_ssm_session
    conn = ssm_test_connection(Krikri::SsmSettings.new("i-0123456789"))

    result = Krikri::SsmTransport.exec(conn, "echo hi", 10)

    result[:exit_code].must_equal(0)
    result[:stdout].must_equal("hello\n")
    result[:stderr].must_equal("")
    fake.closed?.must_equal(false)
  end

  it "waits for the bootstrap ready marker before streaming a base64 payload" do
    fake = install_fake_ssm_session
    conn = ssm_test_connection(Krikri::SsmSettings.new("i-0123456789"))
    script = "echo hi\n" + ("x" * 50_000)

    result = Krikri::SsmTransport.exec_script(conn, script, 10)

    result[:exit_code].must_equal(0)
    command_index = fake.writes.index(&.includes?("head -c")) || raise "missing bootstrap command"
    command_line = fake.writes[command_index]
    command_line.must_include("KRIKRI-SSM-READY-")
    assert fake.writes.size > command_index + 1
    fake.writes[(command_index + 1)..].each do |payload|
      payload.each_line do |line|
        assert line.bytesize <= Krikri::SsmTransport::BASE64_LINE_BYTES + 1
      end
    end
  end

  it "routes a quote-heavy command through the bootstrap instead of the pty line" do
    fake = install_fake_ssm_session
    conn = ssm_test_connection(Krikri::SsmSettings.new("i-0123456789"))
    command = "echo " + ("'" * 1_200)

    result = Krikri::SsmTransport.exec(conn, command, 10)

    result[:exit_code].must_equal(0)
    command_line = fake.writes.find(&.includes?("head -c")) || raise "missing bootstrap command"
    command_line.wont_include(command)
  end

  it "serializes two concurrent operations on one session" do
    fake = install_fake_ssm_session
    gate = Channel(Nil).new(1)
    fake.gate = gate
    conn = ssm_test_connection(Krikri::SsmSettings.new("i-0123456789"))
    results = Channel(Krikri::SsmTransport::Result).new(2)

    spawn { results.send(Krikri::SsmTransport.exec(conn, "echo one", 10)) }
    fake.command_seen.receive

    spawn { results.send(Krikri::SsmTransport.exec(conn, "echo two", 10)) }
    # B must be waiting on the per-session lock, not interleaving markers.
    select
    when fake.command_seen.receive
      raise "the second operation wrote to the session while the first was in flight"
    when timeout(250.milliseconds)
    end

    gate.send(nil)
    first = results.receive
    first[:exit_code].must_equal(0)
    fake.command_seen.receive
    gate.send(nil)
    second = results.receive
    second[:exit_code].must_equal(0)
  end

  it "refuses a Windows-flavoured target before opening a session" do
    conn = ssm_test_connection(Krikri::SsmSettings.new("i-0123456789", shell_type: "powershell"))

    result = Krikri::SsmTransport.exec(conn, "echo hi", 10)

    result[:exit_code].must_equal(255)
    result[:stderr].must_equal(Krikri::SsmSettings::WINDOWS_UNSUPPORTED_MESSAGE)
  end
end

describe "Krikri::SSHManager (ssm transport delegation)" do
  serial!

  before_each do
    Krikri::SsmRegistry.close_all
    Krikri::SsmRegistry.session_factory = nil
  end

  after_each do
    Krikri::SsmRegistry.close_all
    Krikri::SsmRegistry.session_factory = nil
  end

  it "delegates exec to the SSM transport when the connection is SSM" do
    install_fake_ssm_session
    conn = ssm_test_connection(Krikri::SsmSettings.new("i-0123456789"))

    result = Krikri::SSHManager.exec("i-0123456789", "ssm-user", "echo hi", connection: conn)

    result[:exit_code].must_equal(0)
    result[:stdout].must_equal("hello\n")
  end
end
