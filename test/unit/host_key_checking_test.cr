require "../minitest_helper"
require "file_utils"
require "../../src/krikri/ansible_config"
require "../../src/krikri/connection_settings"
require "../../src/krikri/ssh_manager"

# Issue #1682: host key checking was not configurable - every ssh/scp/
# rsync dial hardcoded `-o StrictHostKeyChecking=accept-new` and ignored
# ANSIBLE_HOST_KEY_CHECKING, ansible.cfg's host_key_checking and the
# ansible_host_key_checking inventory var. The pins here mirror
# ansible-core's ssh.py host_key_checking option: only a DISABLED check
# adds `-o StrictHostKeyChecking=no`; an enabled one adds nothing (ssh's
# own `ask` default then refuses unknown and changed keys
# non-interactively), with the option's vars > env > ini ladder.
private HOST_KEY_ENV_KEYS = %w[
  ANSIBLE_HOST_KEY_CHECKING
  ANSIBLE_SSH_HOST_KEY_CHECKING
  ANSIBLE_CONFIG
]

private def with_clean_host_key_state(&)
  saved = {} of String => String
  HOST_KEY_ENV_KEYS.each do |key|
    saved[key] = ENV[key] if ENV.has_key?(key)
    ENV.delete(key)
  end
  Krikri::SSHManager.clear_host_key_checkings_for_spec
  begin
    yield
  ensure
    Krikri::SSHManager.clear_host_key_checkings_for_spec
    HOST_KEY_ENV_KEYS.each do |key|
      if value = saved[key]?
        ENV[key] = value
      else
        ENV.delete(key)
      end
    end
  end
end

# Writes *content* as the run's ansible.cfg (ANSIBLE_CONFIG pointing at
# it) for the duration of the block - the ansible_config_test.cr pattern.
private def with_host_key_cfg(content : String, &)
  dir = PluginSpecHelper.tmp_path("host-key-cfg-#{Random::Secure.hex(4)}")
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "ansible.cfg"), content)
  ENV["ANSIBLE_CONFIG"] = File.join(dir, "ansible.cfg")
  begin
    Krikri::AnsibleConfig.base_dir = dir
    yield
  ensure
    Krikri::AnsibleConfig.base_dir = Dir.current
  end
end

private def host_key_host(vars : Hash(String, JSON::Any) = Hash(String, JSON::Any).new) : Krikri::Host
  host = Krikri::Host.new("hk1", "root", 2222)
  host.vars = vars
  host
end

private def strict_value(argv : Array(String)) : String?
  argv.each_cons(2).compact_map { |pair| pair[1] if pair[0] == "-o" && pair[1].starts_with?("StrictHostKeyChecking=") }.first?
end

describe "host key checking resolution" do
  # ENV, the process-global AnsibleConfig cache and SSHManager's
  # process-global host-key registry are all mutated here.
  exclusive!

  it "dials with no StrictHostKeyChecking option when nothing disables checking" do
    with_clean_host_key_state do
      with_host_key_cfg("[defaults]\n") do
        ssh = Krikri::SSHManager.ssh_argv("/cp", nil, 22, "root", "h", ["true"])
        scp = Krikri::SSHManager.scp_argv("/cp", nil, 22, "root", "h", ["a", "b"])
        rsync = Krikri::SSHManager.rsync_ssh_command("/cp", nil, 22)
        strict_value(ssh).must_be_nil
        strict_value(scp).must_be_nil
        rsync.wont_include("StrictHostKeyChecking")
      end
    end
  end

  it "adds StrictHostKeyChecking=no when ANSIBLE_HOST_KEY_CHECKING is false" do
    with_clean_host_key_state do
      ENV["ANSIBLE_HOST_KEY_CHECKING"] = "False"
      argv = Krikri::SSHManager.ssh_argv("/cp", nil, 22, "root", "h", ["true"])
      strict_value(argv).must_equal("StrictHostKeyChecking=no")
    end
  end

  it "adds nothing when the env explicitly enables checking" do
    with_clean_host_key_state do
      ENV["ANSIBLE_HOST_KEY_CHECKING"] = "True"
      strict_value(Krikri::SSHManager.ssh_argv("/cp", nil, 22, "root", "h", ["true"])).must_be_nil
    end
  end

  it "lets ANSIBLE_SSH_HOST_KEY_CHECKING outrank ANSIBLE_HOST_KEY_CHECKING" do
    with_clean_host_key_state do
      ENV["ANSIBLE_HOST_KEY_CHECKING"] = "True"
      ENV["ANSIBLE_SSH_HOST_KEY_CHECKING"] = "False"
      strict_value(Krikri::SSHManager.ssh_argv("/cp", nil, 22, "root", "h", ["true"]))
        .must_equal("StrictHostKeyChecking=no")

      ENV["ANSIBLE_HOST_KEY_CHECKING"] = "False"
      ENV["ANSIBLE_SSH_HOST_KEY_CHECKING"] = "True"
      strict_value(Krikri::SSHManager.ssh_argv("/cp", nil, 22, "root", "h", ["true"])).must_be_nil
    end
  end

  it "reads host_key_checking from ansible.cfg [defaults]" do
    with_clean_host_key_state do
      with_host_key_cfg("[defaults]\nhost_key_checking = False\n") do
        strict_value(Krikri::SSHManager.ssh_argv("/cp", nil, 22, "root", "h", ["true"]))
          .must_equal("StrictHostKeyChecking=no")
      end
    end
  end

  it "lets the [ssh_connection] entry outrank the [defaults] one" do
    with_clean_host_key_state do
      with_host_key_cfg("[defaults]\nhost_key_checking = False\n[ssh_connection]\nhost_key_checking = True\n") do
        Krikri::AnsibleConfig.host_key_checking.must_equal(true)
        strict_value(Krikri::SSHManager.ssh_argv("/cp", nil, 22, "root", "h", ["true"])).must_be_nil
      end
      with_host_key_cfg("[defaults]\nhost_key_checking = True\n[ssh_connection]\nhost_key_checking = False\n") do
        Krikri::AnsibleConfig.host_key_checking.must_equal(false)
        strict_value(Krikri::SSHManager.ssh_argv("/cp", nil, 22, "root", "h", ["true"]))
          .must_equal("StrictHostKeyChecking=no")
      end
    end
  end

  it "resolves the ansible_host_key_checking var above env and ansible.cfg" do
    with_clean_host_key_state do
      with_host_key_cfg("[defaults]\nhost_key_checking = False\n") do
        ENV["ANSIBLE_HOST_KEY_CHECKING"] = "False"
        vars = {"ansible_host_key_checking" => JSON::Any.new(true)}
        conn = Krikri::ConnectionSettings.resolve(host_key_host, vars)
        conn.host_key_checking.must_equal(true)
        strict_value(Krikri::SSHManager.ssh_argv("/cp", nil, 22, "root", "h", ["true"], host_key_checking: conn.host_key_checking))
          .must_be_nil
      end
    end
  end

  it "resolves a false var above enabling env and ansible.cfg" do
    with_clean_host_key_state do
      with_host_key_cfg("[defaults]\nhost_key_checking = True\n") do
        ENV["ANSIBLE_HOST_KEY_CHECKING"] = "True"
        vars = {"ansible_host_key_checking" => JSON::Any.new(false)}
        conn = Krikri::ConnectionSettings.resolve(host_key_host, vars)
        strict_value(Krikri::SSHManager.ssh_argv("/cp", nil, 22, "root", "h", ["true"], host_key_checking: conn.host_key_checking))
          .must_equal("StrictHostKeyChecking=no")
      end
    end
  end

  it "keeps the ansible_ssh_ alias above the canonical var name" do
    with_clean_host_key_state do
      canonical_true = {
        "ansible_host_key_checking"     => JSON::Any.new(true),
        "ansible_ssh_host_key_checking" => JSON::Any.new(false),
      }
      Krikri::ConnectionSettings.resolve(host_key_host, canonical_true).host_key_checking.must_equal(false)

      canonical_false = {
        "ansible_host_key_checking"     => JSON::Any.new(false),
        "ansible_ssh_host_key_checking" => JSON::Any.new(true),
      }
      Krikri::ConnectionSettings.resolve(host_key_host, canonical_false).host_key_checking.must_equal(true)
    end
  end

  it "reads inventory-level vars too, and coerces strings like convert_bool" do
    with_clean_host_key_state do
      conn = Krikri::ConnectionSettings.resolve(host_key_host({"ansible_host_key_checking" => JSON::Any.new("yes")}), nil)
      conn.host_key_checking.must_equal(true)

      conn = Krikri::ConnectionSettings.resolve(host_key_host({"ansible_host_key_checking" => JSON::Any.new("0")}), nil)
      conn.host_key_checking.must_equal(false)

      # A real JSON boolean, and an integer spelling.
      conn = Krikri::ConnectionSettings.resolve(host_key_host({"ansible_host_key_checking" => JSON::Any.new(true)}), nil)
      conn.host_key_checking.must_equal(true)
      conn = Krikri::ConnectionSettings.resolve(host_key_host({"ansible_host_key_checking" => JSON::Any.new(0)}), nil)
      conn.host_key_checking.must_equal(false)

      # An unrendered template or unparseable string stays unset: the
      # env/ini/default ladder below decides, it never flips the setting.
      conn = Krikri::ConnectionSettings.resolve(host_key_host({"ansible_host_key_checking" => JSON::Any.new("{{ hk }}")}), nil)
      conn.host_key_checking.must_be_nil
      conn = Krikri::ConnectionSettings.resolve(host_key_host({"ansible_host_key_checking" => JSON::Any.new("nonsense")}), nil)
      conn.host_key_checking.must_equal(false)
    end
  end

  it "leaves the var unset when no layer sets it, so the ladder below decides" do
    with_clean_host_key_state do
      Krikri::ConnectionSettings.resolve(host_key_host, nil).host_key_checking.must_be_nil

      ENV["ANSIBLE_HOST_KEY_CHECKING"] = "False"
      argv = Krikri::SSHManager.ssh_argv("/cp", nil, 22, "root", "h", ["true"], host_key_checking: nil)
      strict_value(argv).must_equal("StrictHostKeyChecking=no")
    end
  end
end
