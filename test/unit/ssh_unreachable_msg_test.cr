require "../minitest_helper"
require "../../src/krikri/ssh_unreachable_msg"
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
