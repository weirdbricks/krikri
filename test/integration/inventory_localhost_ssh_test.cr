require "../minitest_helper"
require "socket"

# Issue #677: an explicit inventory host named `localhost` is a REGULAR
# host in ansible-core, not the implicit localhost. Real ansible-playbook
# 2.19.11 (live-verified on this issue's exact repro) SSHes to it - a
# bare inventory `localhost` UNREACHABLEs with "ssh: connect to host
# localhost port 22: Connection refused" for both a direct and a
# delegated task, and one carrying ansible_port=2299 SSHes to that port.
# krikri's old name shortcut (name == "localhost" => local) ran the
# plugin on the CONTROLLER instead: with become: + ansible_become_
# password the become password was fed to the controller user's sudo
# ("Sorry, try again" x2) and nothing ever reached the target.
#
# The port here is a bound-then-closed loopback port instead of 22: the
# dev box may legitimately run sshd, so port 22 would make "connects
# over ssh" non-deterministic. A closed port gives the same UNREACHABLE
# shape deterministically, while proving the task did NOT run locally
# (a local run would print changed/ok, never a connection failure).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_playbook(inventory : String, yaml : String) : {Process::Status, String}
  dir = PluginSpecHelper.tmp_path("issue-677")
  FileUtils.mkdir_p(dir)
  inv = File.join(dir, "inv.ini")
  File.write(inv, inventory)
  playbook = File.join(dir, "play.yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inv, playbook], output: output, error: output)
  {status, output.to_s}
end

private def closed_loopback_port : Int32
  server = TCPServer.new("127.0.0.1", 0)
  port = server.local_address.port
  server.close
  port
end

describe "inventory-defined localhost is a regular ssh host (issue #677)" do
  it "ssh's an inventory localhost with ansible_port to that port, unreachable, not local" do
    port = closed_loopback_port
    status, output = run_playbook(
      "localhost ansible_port=#{port} ansible_user=tester\n",
      <<-YAML
        - hosts: localhost
          gather_facts: false
          tasks:
            - name: touched
              command: "true"
        YAML
    )

    status.exit_code.must_equal(4)
    output.must_match(/UNREACHABLE! => \{"changed": false, "msg": "Task failed: Failed to connect to the host via ssh: ssh: connect to host localhost port #{port}/)
    output.wont_match(/changed: \[localhost\]/)
    output.must_match(/localhost\s*: ok=0\s+changed=0\s+unreachable=1\s+failed=0/)
  end

  it "ssh's a delegated task to an inventory-defined localhost instead of running it locally" do
    port = closed_loopback_port
    status, output = run_playbook(
      "testhost ansible_connection=local\nlocalhost ansible_port=#{port} ansible_user=tester\n",
      <<-YAML
        - hosts: testhost
          gather_facts: false
          tasks:
            - name: delegated
              command: "true"
              delegate_to: localhost
        YAML
    )

    status.exit_code.must_equal(4)
    output.must_match(/fatal: \[testhost -> localhost\]: UNREACHABLE!/)
    output.must_match(/connect to host localhost port #{port}/)
    output.wont_match(/changed: \[testhost -> localhost\]/)
    output.must_match(/testhost\s*: ok=0\s+changed=0\s+unreachable=1\s+failed=0/)
  end

  it "still runs an inventory localhost with ansible_connection=local locally" do
    status, output = run_playbook(
      "localhost ansible_connection=local\n",
      <<-YAML
        - hosts: localhost
          gather_facts: false
          tasks:
            - name: touched
              command: "true"
        YAML
    )

    status.exit_code.must_equal(0)
    output.must_match(/changed: \[localhost\]/)
    output.must_match(/localhost\s*: ok=1\s+changed=1\s+unreachable=0/)
  end

  it "still runs a delegated localhost task locally when no inventory entry exists" do
    # The implicit-localhost idiom (ansible-community.ansible-vault's
    # delegate_to: 127.0.0.1 unarchive tasks, cloudalchemy.node_exporter's
    # delegate_to: localhost get_url tasks) - unchanged by #677.
    status, output = run_playbook(
      "testhost ansible_connection=local\n",
      <<-YAML
        - hosts: testhost
          gather_facts: false
          tasks:
            - name: delegated
              command: "true"
              delegate_to: localhost
        YAML
    )

    status.exit_code.must_equal(0)
    output.must_match(/changed: \[testhost -> localhost\]/)
    output.must_match(/testhost\s*: ok=1\s+changed=1\s+unreachable=0/)
  end
end
