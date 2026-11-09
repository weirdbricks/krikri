require "file_utils"
require "socket"
require "../minitest_helper"

# Issue #1067 end-to-end: the three ways ansible picks the SSH user, key
# and port that this engine used to ignore - ANSIBLE_PRIVATE_KEY_FILE,
# ANSIBLE_REMOTE_USER, and the `host:port` INI inventory form. Each case
# is the issue's own repro shape against a real sshd (a common
# StrictHostKeyChecking/UserKnownHostsFile/IdentitiesOnly arg set so only
# the setting under test differs): before the fix every case went
# UNREACHABLE while ansible-playbook reported ok=1, after it both engines
# play clean. The fourth case covers the controller-side plugin
# transport (fetch's remote read dials back out through BasePlugin's own
# identity ladder).
#
# This spec needs a real sshd reachable from the controller and skips
# without one - the shared throwaway documented in
# task_timeout_ssh_loop_test.cr's header, overridable through
# KRIKRI_TEST_SSHD_HOST/PORT/USER/KEY.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private SSHD_HOST = ENV["KRIKRI_TEST_SSHD_HOST"]? || "127.0.0.1"
private SSHD_PORT = (ENV["KRIKRI_TEST_SSHD_PORT"]? || "2224").to_i
private SSHD_USER = ENV["KRIKRI_TEST_SSHD_USER"]? || "root"
private SSHD_KEY  = ENV["KRIKRI_TEST_SSHD_KEY"]? || "/tmp/kkt-key"

private SSH_OPTS = "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o IdentitiesOnly=yes"

private PING_PLAY = <<-YAML
  - hosts: all
    gather_facts: false
    tasks:
      - ansible.builtin.ping:
  YAML

private def env_conn_sshd_reachable? : Bool
  return false unless File.exists?(SSHD_KEY)
  TCPSocket.new(SSHD_HOST, SSHD_PORT, connect_timeout: 1).close
  true
rescue
  false
end

private def run_env_conn(inventory_line : String, playbook : String, extra_env : Hash(String, String)) : String
  dir = PluginSpecHelper.tmp_path("env-conn-ssh-#{Random::Secure.hex(4)}")
  Dir.mkdir_p(dir)
  inventory = File.join(dir, "inv.ini")
  play = File.join(dir, "pb.yml")
  File.write(inventory, inventory_line + "\n")
  File.write(play, playbook)

  output = IO::Memory.new
  Process.run(BINARY, ["-i", inventory, play],
    output: output, error: output, chdir: dir, env: extra_env)
  output.to_s
ensure
  File.delete(inventory) if inventory && File.exists?(inventory)
  File.delete(play) if play && File.exists?(play)
end

describe "env connection settings over ssh (issue #1067)" do
  # Symptom 1: ANSIBLE_PRIVATE_KEY_FILE - the env form of ansible's
  # PRIVATE_KEY_FILE setting - authenticates when the inventory sets no
  # key of its own.
  it "authenticates from ANSIBLE_PRIVATE_KEY_FILE when no inventory key is set" do
    skip "no reachable test sshd (see task_timeout_ssh_loop_test.cr's header)" unless env_conn_sshd_reachable?

    output = run_env_conn(
      "h ansible_host=#{SSHD_HOST} ansible_port=#{SSHD_PORT} ansible_user=#{SSHD_USER} " \
      "ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args='#{SSH_OPTS}'",
      PING_PLAY,
      {"ANSIBLE_PRIVATE_KEY_FILE" => SSHD_KEY})

    output.must_include("ok=1")
    output.wont_include("UNREACHABLE")
  end

  # Symptom 2: ANSIBLE_REMOTE_USER - the env form of ansible's
  # DEFAULT_REMOTE_USER setting - supplies the login user when the
  # inventory sets none (krikri used to dial the LOCAL user).
  it "connects as ANSIBLE_REMOTE_USER when the inventory sets no user" do
    skip "no reachable test sshd (see task_timeout_ssh_loop_test.cr's header)" unless env_conn_sshd_reachable?

    output = run_env_conn(
      "h ansible_host=#{SSHD_HOST} ansible_port=#{SSHD_PORT} " \
      "ansible_ssh_private_key_file=#{SSHD_KEY} " \
      "ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args='#{SSH_OPTS}'",
      PING_PLAY,
      {"ANSIBLE_REMOTE_USER" => SSHD_USER})

    output.must_include("ok=1")
    output.wont_include("UNREACHABLE")
  end

  # Symptom 3: a `host:port` inventory entry - the documented INI form -
  # splits into the hostname and ansible_port; the host is named WITHOUT
  # the port (verified against ansible-inventory --list) and connects on
  # the split port.
  it "connects on the port from a host:port entry, naming the host without it" do
    skip "no reachable test sshd (see task_timeout_ssh_loop_test.cr's header)" unless env_conn_sshd_reachable?

    output = run_env_conn(
      "#{SSHD_HOST}:#{SSHD_PORT} ansible_user=#{SSHD_USER} " \
      "ansible_ssh_private_key_file=#{SSHD_KEY} " \
      "ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args='#{SSH_OPTS}'",
      PING_PLAY,
      {} of String => String)

    output.must_include("ok=1")
    output.wont_include("UNREACHABLE")
    output.must_include("ok: [#{SSHD_HOST}]")
  end

  # The env key reaches the controller-side plugin transport too (fetch's
  # remote read dials back out over BasePlugin's own identity ladder,
  # which used to see only the inventory's ansible_ssh_private_key_file).
  it "fetches through the plugin-side identity ladder with the env key" do
    skip "no reachable test sshd (see task_timeout_ssh_loop_test.cr's header)" unless env_conn_sshd_reachable?

    dest_root = PluginSpecHelper.tmp_path("env-conn-fetch-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dest_root)
    dest = File.join(dest_root, "fetched-hostname")

    output = run_env_conn(
      "h ansible_host=#{SSHD_HOST} ansible_port=#{SSHD_PORT} ansible_user=#{SSHD_USER} " \
      "ansible_python_interpreter=/usr/bin/python3 ansible_ssh_common_args='#{SSH_OPTS}'",
      <<-YAML,
        - hosts: all
          gather_facts: false
          tasks:
            - ansible.builtin.fetch:
                src: /etc/hostname
                dest: #{dest}
                flat: true
        YAML
      {"ANSIBLE_PRIVATE_KEY_FILE" => SSHD_KEY})

    output.must_include("ok=1")
    output.wont_include("UNREACHABLE")
    File.exists?(dest).must_equal(true)
  end
end
