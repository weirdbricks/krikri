require "../minitest_helper"

# Issue #1245: `delegate_to:` on a handler was ignored - the handler's
# module dispatched over the NOTIFYING host's connection instead of the
# delegate's, and its result line read `ok: [host1]` where ansible-core
# 2.21.6 prints `ok: [host1 -> helper]`. The notifying host here is an
# unreachable ssh target on purpose: the delegated handler can only
# succeed if its module really dispatches over the delegate's local
# connection (live-verified against real ansible-playbook, which runs
# the handler on `helper` and reports ok).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private def run_delegated_handler_play(handler_lines : Array(String), task_lines : Array(String)) : {Process::Status, String}
  inventory = PluginSpecHelper.tmp_path("handler-delegate-inv-#{Random::Secure.hex(4)}.ini")
  File.write(inventory, <<-INI)
    [all]
    host1 ansible_connection=ssh ansible_host=192.0.2.1 ansible_ssh_common_args='-o ConnectTimeout=2'
    [other]
    helper ansible_connection=local ansible_host=127.0.0.1
  INI
  playbook = PluginSpecHelper.tmp_path("handler-delegate-#{Random::Secure.hex(4)}.yml")
  lines = ["- hosts: host1", "  gather_facts: false", "  handlers:"]
  lines.concat(handler_lines)
  lines << "  tasks:"
  lines.concat(task_lines)
  File.write(playbook, lines.join("\n") + "\n")
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(inventory) if inventory && File.exists?(inventory)
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "handler delegate_to: (handler_delegate_to_test.cr)" do
  it "runs the handler on the delegate and labels the result line with it" do
    marker = PluginSpecHelper.tmp_path("handler-delegate-marker-#{Random::Secure.hex(4)}")
    status, output = run_delegated_handler_play(
      [
        "    - name: delegated handler",
        "      ansible.builtin.command: sh -c 'echo handler-ran > #{marker}'",
        "      delegate_to: helper",
        "      changed_when: false",
      ],
      [
        "    - ansible.builtin.debug: {msg: notify}",
        "      changed_when: true",
        "      notify: delegated handler",
        "    - ansible.builtin.meta: flush_handlers",
      ]
    )

    status.success?.must_equal(true, output)
    output.must_include("ok: [host1 -> helper]")
    output.wont_include("UNREACHABLE")
    File.exists?(marker).must_equal(true, output)
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end

  it "labels a failing delegated handler's fatal line with the delegate" do
    status, output = run_delegated_handler_play(
      [
        "    - name: delegated fail handler",
        "      ansible.builtin.command: /bin/false",
        "      delegate_to: helper",
        "      ignore_errors: true",
      ],
      [
        "    - ansible.builtin.debug: {msg: notify}",
        "      changed_when: true",
        "      notify: delegated fail handler",
        "    - ansible.builtin.meta: flush_handlers",
      ]
    )

    status.success?.must_equal(true, output)
    output.must_include("fatal: [host1 -> helper]: FAILED!")
    output.must_include("...ignoring")
  end
end
