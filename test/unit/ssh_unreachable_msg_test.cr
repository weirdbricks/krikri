require "../minitest_helper"
require "../../src/krikri/ssh_unreachable_msg"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/host"

# Issue #1068: the lead text of an ssh transport-failure unreachable msg is
# pipelining-dependent in ansible (SSHUnreachableMsg's doc comment carries the
# live-verified 2.21.5 shapes).
describe "Krikri::SSHUnreachableMsg" do
  serial! # pins process-wide ENV

  private def with_env(pairs : Hash(String, String?), &)
    previous = pairs.keys.to_h { |key| {key, ENV[key]?} }
    begin
      pairs.each do |key, value|
        value ? (ENV[key] = value) : ENV.delete(key)
      end
      yield
    ensure
      previous.each do |key, value|
        value ? (ENV[key] = value) : ENV.delete(key)
      end
    end
  end

  describe ".unreachable_msg" do
    it "keeps ansible's plain failed-to-connect lead without pipelining" do
      Krikri::SSHUnreachableMsg.unreachable_msg("ssh: connect to host localhost port 22: Connection refused",
        false, "localhost").must_equal(
        "Failed to connect to the host via ssh: ssh: connect to host localhost port 22: Connection refused"
      )
    end

    it "uses ansible's pipelined Data-could-not-be-sent lead, embedding the connection host" do
      Krikri::SSHUnreachableMsg.unreachable_msg("ssh: connect to host localhost port 22: Connection refused",
        true, "10.0.0.5").must_equal(
        "Data could not be sent to remote host \"10.0.0.5\". Make sure this host can be reached over ssh: " \
        "ssh: connect to host localhost port 22: Connection refused"
      )
    end

    it "leaves the SSM Windows refusal unwrapped" do
      # The Windows guard fails before any session (or ssh) exists, so the
      # ssh lead ("Make sure this host can be reached over ssh") would
      # misreport both the transport and the cause.
      text = Krikri::SsmUnreachableMsg::WINDOWS_UNSUPPORTED
      Krikri::SSHUnreachableMsg.unreachable_msg(text, true, "10.0.0.5").must_equal(text)
      Krikri::SSHUnreachableMsg.unreachable_msg(text, false, "10.0.0.5").must_equal(text)
    end

    it "trims the trailing space an empty ssh detail would leave" do
      # Issue #1663's silent-death shape: ssh exits 255 with nothing on
      # stderr, so there is no detail to append. ansible-playbook's msg
      # ends `... can be reached over ssh:` - the task error is
      # str(value).rstrip()'d (_internal/_task.py), so no trailing space
      # survives into the printed line or the fatal JSON (live-verified
      # vs 2.21.6).
      Krikri::SSHUnreachableMsg.unreachable_msg("", true, "127.0.0.1").must_equal(
        "Data could not be sent to remote host \"127.0.0.1\". Make sure this host can be reached over ssh:"
      )
      Krikri::SSHUnreachableMsg.unreachable_msg("", false, "127.0.0.1").must_equal(
        "Failed to connect to the host via ssh:"
      )
      # A detail with trailing whitespace is trimmed too (ssh's own
      # stderr usually ends with a newline).
      Krikri::SSHUnreachableMsg.unreachable_msg("Connection closed by 10.0.0.1 port 22\r\n",
        false, "10.0.0.1").must_equal(
        "Failed to connect to the host via ssh: Connection closed by 10.0.0.1 port 22"
      )
    end
  end

  describe ".pipelining_enabled?" do
    it "defaults to false with no vars and no env" do
      with_env({"ANSIBLE_PIPELINING" => nil, "ANSIBLE_SSH_PIPELINING" => nil}) do
        Krikri::SSHUnreachableMsg.pipelining_enabled?(nil).must_equal(false)
      end
    end

    it "reads the ansible_pipelining var over ansible's boolean() spellings" do
      with_env({"ANSIBLE_PIPELINING" => nil, "ANSIBLE_SSH_PIPELINING" => nil}) do
        Krikri::SSHUnreachableMsg.pipelining_enabled?(
          {"ansible_pipelining" => JSON::Any.new(true)} of String => JSON::Any
        ).must_equal(true)
        Krikri::SSHUnreachableMsg.pipelining_enabled?(
          {"ansible_pipelining" => JSON::Any.new("no")} of String => JSON::Any
        ).must_equal(false)
      end
    end

    it "honors the ansible_ssh_pipelining alias" do
      with_env({"ANSIBLE_PIPELINING" => nil, "ANSIBLE_SSH_PIPELINING" => nil}) do
        Krikri::SSHUnreachableMsg.pipelining_enabled?(
          {"ansible_ssh_pipelining" => JSON::Any.new("yes")} of String => JSON::Any
        ).must_equal(true)
      end
    end

    it "falls through an unparseable var value to the env var" do
      with_env({"ANSIBLE_PIPELINING" => "1", "ANSIBLE_SSH_PIPELINING" => nil}) do
        Krikri::SSHUnreachableMsg.pipelining_enabled?(
          {"ansible_pipelining" => JSON::Any.new("{{ toggle }}")} of String => JSON::Any
        ).must_equal(true)
      end
    end

    it "reads the env var when no vars carry the option" do
      with_env({"ANSIBLE_PIPELINING" => nil, "ANSIBLE_SSH_PIPELINING" => "yes"}) do
        Krikri::SSHUnreachableMsg.pipelining_enabled?(nil).must_equal(true)
      end
      with_env({"ANSIBLE_PIPELINING" => "false", "ANSIBLE_SSH_PIPELINING" => nil}) do
        Krikri::SSHUnreachableMsg.pipelining_enabled?(nil).must_equal(false)
      end
    end

    it "uses the Host convenience form, embedding the connection host" do
      host = Krikri::Host.new("web1")
      host.vars["ansible_host"] = JSON::Any.new("10.0.0.9")
      Krikri::SSHUnreachableMsg.unreachable_msg("ssh: connect to host 10.0.0.9 port 22: Connection refused",
        nil, host).must_equal(
        "Failed to connect to the host via ssh: ssh: connect to host 10.0.0.9 port 22: Connection refused"
      )
    end
  end
end

describe "Krikri::SSHManager SSM error classification" do
  it "books an SSM configuration error as a failed task, not unreachable" do
    text = "#{Krikri::SsmUnreachableMsg::CONFIGURATION_ERROR}: chunk_size must be positive"
    Krikri::SSHManager.connection_level_failure?(255, text).must_equal(false)
    Krikri::SSHManager.connection_level_exception?(Exception.new(text)).must_equal(false)
  end

  it "books an invalid session document as a failed task" do
    text = "#{Krikri::SsmUnreachableMsg::INVALID_DOCUMENT}: document not found"
    Krikri::SSHManager.connection_level_failure?(255, text).must_equal(false)
    Krikri::SSHManager.connection_level_exception?(Exception.new(text)).must_equal(false)
  end

  it "keeps a dead target, missing credentials and access denial unreachable" do
    [Krikri::SsmUnreachableMsg::TARGET_NOT_CONNECTED,
     Krikri::SsmUnreachableMsg::NO_CREDENTIALS,
     Krikri::SsmUnreachableMsg::ACCESS_DENIED].each do |text|
      Krikri::SSHManager.connection_level_failure?(255, text).must_equal(true)
      Krikri::SSHManager.connection_level_exception?(Exception.new(text)).must_equal(true)
    end
  end
end
