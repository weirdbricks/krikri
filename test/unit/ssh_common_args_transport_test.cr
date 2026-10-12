require "../minitest_helper"
require "../../src/krikri/connection_settings"
require "../../src/krikri/plugin_manager"
require "../../src/krikri/ssh_manager"
require "../../src/krikri/plugin_helpers/synchronize_rsync"

# Issue #2: with a populated ssh-agent, the inventory's
# `ansible_ssh_common_args='-o IdentitiesOnly=yes'` must land in the argv
# of EVERY transport the engine spawns - the plugin-upload probe (round
# trip 1's `bash -s` script), the rsync/scp transfer, and the SSH call a
# controller-only plugin binary (fetch's remote read,
# wait_for_connection's connection probe) makes from its own process.
#
# Pure command construction, exactly like sshpass_wrapping_test.cr: no
# real ssh/scp/rsync process is ever started here, because a unit test
# cannot dial a host - what it CAN pin is the argv and the var plumbing
# those processes are built from. The end-to-end behavior against a real
# sshd stays with the ssh integration specs (which skip when no test
# sshd is reachable).
private def issue_host : Krikri::Host
  host = Krikri::Host.new("target", "root", 22)
  host.vars = {
    "ansible_host"                 => JSON::Any.new("192.0.2.10"),
    "ansible_ssh_private_key_file" => JSON::Any.new("/keys/id_ed25519"),
    "ansible_ssh_common_args"      => JSON::Any.new("-o IdentitiesOnly=yes"),
    "ansible_ssh_extra_args"       => JSON::Any.new("-o ServerAliveInterval=15"),
  } of String => JSON::Any
  host
end

private def assert_carries_identities_only(argv : Array(String), where : String)
  found = false
  argv.each_cons(2) do |pair|
    found = true if pair[0] == "-o" && pair[1] == "IdentitiesOnly=yes"
  end
  found.must_equal(true, "#{where} dropped ansible_ssh_common_args: #{argv}")
end

describe "ssh common args reach every transport argv (issue #2)" do
  it "resolves ansible_ssh_common_args from inventory vars into ssh_extra_options" do
    conn = Krikri::ConnectionSettings.resolve(issue_host, issue_host.vars)
    conn.identity_file.must_equal("/keys/id_ed25519")
    conn.ssh_extra_options.must_equal(["-o", "IdentitiesOnly=yes", "-o", "ServerAliveInterval=15"])
    conn.common_args.empty?.must_equal(false)
    conn.extra_args.empty?.must_equal(false)
  end

  it "carries them in the ssh argv the upload probe and dispatch use" do
    conn = Krikri::ConnectionSettings.resolve(issue_host, issue_host.vars)
    argv = Krikri::SSHManager.ssh_argv(
      "/tmp/.krikri-playbook-ssh/cp", conn.identity_file, conn.port,
      conn.user, conn.conn_host, ["bash", "-s"], nil,
      extra_options: conn.ssh_extra_options
    )
    argv.first.must_equal("ssh")
    argv.includes?("/keys/id_ed25519").must_equal(true)
    assert_carries_identities_only(argv, "ssh_argv")
    argv.includes?("ServerAliveInterval=15").must_equal(true)
  end

  it "carries them in the scp argv the plugin upload falls back to" do
    conn = Krikri::ConnectionSettings.resolve(issue_host, issue_host.vars)
    argv = Krikri::SSHManager.scp_argv(
      "/tmp/.krikri-playbook-ssh/cp", conn.identity_file, conn.port,
      conn.user, conn.conn_host, ["/local/plugins/command", "#{conn.user}@#{conn.conn_host}:/var/tmp/p/command"],
      recursive: false, connect_timeout: true, password: nil,
      extra_options: conn.ssh_extra_options
    )
    argv.first.must_equal("scp")
    assert_carries_identities_only(argv, "scp_argv")
    argv.includes?("ServerAliveInterval=15").must_equal(true)
  end

  it "carries them in the rsync -e ssh command the upload prefers" do
    conn = Krikri::ConnectionSettings.resolve(issue_host, issue_host.vars)
    command = Krikri::SSHManager.rsync_ssh_command(
      "/tmp/.krikri-playbook-ssh/cp", conn.identity_file, conn.port, nil,
      conn.ssh_extra_options
    )
    command.includes?("IdentitiesOnly=yes").must_equal(true)
    command.includes?("ServerAliveInterval=15").must_equal(true)
    command.includes?("-i '/keys/id_ed25519'").must_equal(true)
  end

  it "keeps the args in the pruned wire vars a controller-only plugin process resolves from" do
    # build_plugin_config prunes the vars context down to exactly this
    # list before handing it to the plugin binary; a controller-only
    # plugin (fetch, wait_for_connection) then resolves ITS OWN ssh
    # connection from that payload plus the config's host entry.
    Krikri::PluginManager::WIRE_VAR_KEYS.includes?("ansible_ssh_common_args").must_equal(true)
    Krikri::PluginManager::WIRE_VAR_KEYS.includes?("ansible_ssh_extra_args").must_equal(true)

    wire = Hash(String, JSON::Any).new
    issue_host.vars.each do |key, value|
      wire[key] = value if Krikri::PluginManager::WIRE_VAR_KEYS.includes?(key)
    end
    wire["ansible_connection"] = JSON::Any.new("ssh")

    # The config's `host` entry is what the plugin process rebuilds its
    # Host from (Host.from_json): name/user/port only, NO vars.
    plugin_host = Krikri::Host.from_json(JSON.parse({
      "name" => "target", "user" => "root", "port" => 22,
    }.to_json))
    conn = Krikri::ConnectionSettings.resolve(plugin_host, wire)
    conn.identity_file.must_equal("/keys/id_ed25519")
    conn.ssh_extra_options.must_equal(["-o", "IdentitiesOnly=yes", "-o", "ServerAliveInterval=15"])

    argv = Krikri::SSHManager.ssh_argv(
      "/tmp/.krikri-playbook-ssh/cp", conn.identity_file, conn.port,
      conn.user, conn.conn_host, ["true"], nil,
      extra_options: conn.ssh_extra_options
    )
    assert_carries_identities_only(argv, "controller-only plugin ssh_argv")
  end

  it "leaves synchronize's default rsh without them, and appends them under _ssh_args" do
    # ansible.posix only folds the connection's ssh args into the rsh
    # when the task sets use_ssh_args: yes (the action plugin passes the
    # result as `_ssh_args`), so the default rsh must NOT pick them up.
    base = {"verify_host" => "true"}
    default_argv = Krikri::SynchronizeRsync.build_argv("/local/a", "target:/b", base)
    default_argv.join(' ').includes?("IdentitiesOnly").must_equal(false)

    with_args = base.merge({"_ssh_args" => "-o IdentitiesOnly=yes"})
    argv = Krikri::SynchronizeRsync.build_argv("/local/a", "target:/b", with_args)
    rsh = argv.find(&.starts_with?("--rsh=")) || ""
    rsh.includes?("IdentitiesOnly=yes").must_equal(true)
  end
end
