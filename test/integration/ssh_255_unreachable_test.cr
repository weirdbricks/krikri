require "../minitest_helper"

# Issue #1663 (third report of the #1543/#1659 family): ssh(1) reserves
# exit 255 for its own failures, and ansible's ssh connection plugin books
# EVERY 255 as AnsibleConnectionFailure - UNREACHABLE, recap
# `unreachable=1 failed=0`, exit 4 - apart from a short list of signatures
# that mean some other program produced the exit
# (plugins/connection/ssh.py's _handle_error/b_NOT_SSH_ERRORS). This engine
# used to instead require ssh's stderr to match a handful of wordings it
# had already observed, so any wording it did not know (a different ssh
# build's ProxyCommand failure on macOS, "Connection to <host> closed by
# remote host.", a bare silent death) fell through to a generic
# `fatal: FAILED!` carrying the raw `_connection_failure` payload, with
# recap `failed=1` and exit 2.
#
# These run the whole binary against a wrapper that never dials anything
# (no sshd needed): `ansible_ssh_executable` points at a script that exits
# 255 with a wording that is deliberately NOT one of the old patterns.
# The looped-handler shape is covered by the real-host corpus instead
# (test/fixtures/divergence/live/cases.txt): it needs a handler to be
# notified first, which a connection that always fails cannot do.
private SSH_255_PROJECT_ROOT = File.expand_path("../..", __DIR__)
private SSH_255_BINARY       = File.join(SSH_255_PROJECT_ROOT, "bin", "krikri-playbook")
private SSH_255_WORDING      = "Connection to 192.0.2.1 closed by remote host."

# Writes the always-255 ssh wrapper plus an inventory naming it, and
# returns the inventory path. The host address is TEST-NET-1: nothing may
# dial it, the wrapper is what runs.
private def ssh_255_fixture(dir : String) : String
  wrapper = File.join(dir, "ssh-wrapper")
  File.write(wrapper, <<-SH)
    #!/bin/sh
    echo "#{SSH_255_WORDING}" >&2
    exit 255
    SH
  File.chmod(wrapper, 0o755)

  inventory = File.join(dir, "inv.ini")
  File.write(inventory,
    "target ansible_connection=ssh ansible_host=192.0.2.1 ansible_user=root " \
    "ansible_ssh_executable=#{wrapper} ansible_ssh_common_args='-o ConnectTimeout=1'\n")
  inventory
end

private def ssh_255_run(playbook : String, inventory : String, dir : String) : {String, Int32}
  output = IO::Memory.new
  status = Process.run(SSH_255_BINARY, ["-i", inventory, playbook],
    output: output, error: output, chdir: dir)
  {output.to_s, status.exit_code}
end

private def ssh_255_assertions(text : String, exit_code : Int32) : Nil
  text.includes?("UNREACHABLE! =>").must_equal(true, text)
  text.includes?("FAILED!").must_equal(false, text)
  # The raw dispatch shape must never reach the display (issue #1663's
  # actual output).
  text.includes?("Plugin execution failed on remote").must_equal(false, text)
  text.includes?("_connection_failure").must_equal(false, text)
  text.includes?("unreachable=1    failed=0").must_equal(true, text)
  exit_code.must_equal(4, text)
end

describe "ssh 255 exit classification (issue #1663)" do
  it "books a plain task UNREACHABLE for an ssh wording the old pattern list did not know" do
    dir = PluginSpecHelper.tmp_path("ssh255-task-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    inventory = ssh_255_fixture(dir)
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ping:
      YAML

    text, exit_code = ssh_255_run(playbook, inventory, dir)
    ssh_255_assertions(text, exit_code)
    text.includes?(SSH_255_WORDING).must_equal(true, text)
  end

  it "books a 255 inside an until: retry loop UNREACHABLE, not failed" do
    dir = PluginSpecHelper.tmp_path("ssh255-retries-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    inventory = ssh_255_fixture(dir)
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ping:
            register: r
            until: r is succeeded
            retries: 2
            delay: 1
      YAML

    text, exit_code = ssh_255_run(playbook, inventory, dir)
    ssh_255_assertions(text, exit_code)
  end
end
