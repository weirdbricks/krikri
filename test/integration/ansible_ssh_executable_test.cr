require "../minitest_helper"

# Issue #1483: ansible_ssh_executable must change the ssh binary the
# connection runs. ansible's ssh plugin spawns exactly the program the
# variable names, and falls back to it for file transfers too (its
# `piped` transport method), so a wrapper - the reported case is a
# jump-host helper - has to stay in the path for the probe, the module
# dispatch and the transfer, not just for one of them.
#
# The wrapper below never dials anything: it records its own argv and
# answers every call with a marker on stderr and exit 255, which is
# enough to prove the engine spawned it (no sshd required).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "ansible_ssh_executable (issue #1483)" do
  it "spawns the configured binary for every transport instead of plain ssh" do
    dir = PluginSpecHelper.tmp_path("ssh-executable-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)
    wrapper = File.join(dir, "ssh-wrapper")
    marker = File.join(dir, "calls.log")
    File.write(wrapper, <<-SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> #{marker}
      echo "ssh-executable-marker" >&2
      exit 255
      SH
    File.chmod(wrapper, 0o755)

    inventory = File.join(dir, "inv.ini")
    File.write(inventory,
      "target ansible_connection=ssh ansible_host=192.0.2.1 ansible_user=root " \
      "ansible_ssh_executable=#{wrapper} ansible_ssh_common_args='-o ConnectTimeout=1'\n")

    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.ping:
      YAML

    output = IO::Memory.new
    Process.run(BINARY, ["-i", inventory, playbook],
      output: output, error: output, chdir: dir)
    text = output.to_s

    # The wrapper ran (pre-fix nothing ever invoked it - the engine used
    # the ssh on PATH and reported the host's own connection failure).
    File.exists?(marker).must_equal(true, "wrapper was never spawned: #{text}")
    text.includes?("ssh-executable-marker").must_equal(true, text)
    text.includes?("ok=1").must_equal(false, text)
    # Every spawn goes through the wrapper, so nothing ever got as far as
    # plain ssh's own connection-refused error.
    text.includes?("connect to host").must_equal(false, text)
  end

  # Issue #1683: when the binary ansible_ssh_executable names cannot be
  # executed at all, ansible's ssh connection plugin reports a CONTROLLER
  # error - AnsibleError("Unable to execute ssh command line on a
  # controller.") chained on the Popen OSError - and the task FAILS
  # (recap failed=1, exit 2). It must not book a 255 UNREACHABLE (exit 4)
  # or name plain `ssh` in the detail.
  it "fails the task (exit 2) with ansible's controller-error msg for an unspawnable binary" do
    dir = PluginSpecHelper.tmp_path("ssh-executable-missing-#{Random::Secure.hex(4)}")
    Dir.mkdir_p(dir)

    inventory = File.join(dir, "inv.ini")
    File.write(inventory,
      "target ansible_connection=ssh ansible_host=192.0.2.1 ansible_user=root " \
      "ansible_ssh_executable=/nonexistent/ssh ansible_ssh_common_args='-o ConnectTimeout=1'\n")

    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.ping:
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", inventory, playbook],
      output: output, error: output, chdir: dir)
    text = output.to_s

    status.exit_code.must_equal(2, text)
    text.includes?("UNREACHABLE!").must_equal(false, text)
    text.includes?("ssh: No such file or directory").must_equal(false, text)
    # The full ansible chain: the [ERROR] block (brief + the errno cause
    # as its own caused-by section) and the fatal msg carrying both.
    text.includes?("Task failed: Unable to execute ssh command line on a controller: [Errno 2] No such file or directory: b'/nonexistent/ssh'").must_equal(true, text)
    text.includes?("<<< caused by >>>").must_equal(true, text)
    text.includes?("[Errno 2] No such file or directory: b'/nonexistent/ssh'").must_equal(true, text)
    text.includes?("fatal: [target]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Unable to execute ssh command line on a controller: [Errno 2] No such file or directory: b'/nonexistent/ssh'\"}").must_equal(true, text)
    text.includes?("unreachable=0    failed=1").must_equal(true, text)
  end
end
