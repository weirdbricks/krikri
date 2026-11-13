require "../minitest_helper"
require "file_utils"

# Issue #1005: which Python runs a module that is not one of this
# engine's native plugins.
#
# Real ansible runs such a module under the interpreter its task vars
# select (module_common's _get_shebang): the host's
# ansible_python_interpreter, or the interpreter discovery recorded in
# discovered_interpreter_python, or discovery itself. For the IMPLICIT
# localhost it also stamps its own sys.executable onto the host
# (inventory/data.py `_create_implicit_localhost`), so a module
# delegated to localhost runs under the very Python ansible runs under -
# the only one with libraries installed beside ansible (boto3 for
# amazon.aws). krikri used discovery in all three cases, which on a
# Homebrew/pipx controller is a different python without those
# libraries: "Failed to import the required Python library".
#
# The stand-in interpreters below answer every module run with a marker
# instead of executing it, so the assertions say WHICH interpreter was
# picked without depending on the pythons this host happens to have. A
# fake `ansible-playbook` names the controller interpreter through its
# shebang, the same way a real install does.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

# Drains stdin first: a real interpreter reads the new-style args blob
# from it, and leaving it unread lets the double exit while krikri is
# still writing, which raced into a spurious EPIPE failure (issue #1188).
private def write_marker_interpreter(bin : String, name : String, marker : String) : String
  Dir.mkdir_p(bin)
  path = File.join(bin, name)
  File.write(path, "#!/bin/sh\ncat >/dev/null\nprintf '%s\\n' '{\"changed\": false, \"executable\": \"#{marker}\"}'\n")
  File.chmod(path, 0o755)
  path
end

private def write_ansible_playbook(bin : String, interpreter : String) : String
  Dir.mkdir_p(bin)
  path = File.join(bin, "ansible-playbook")
  File.write(path, "#!#{interpreter}\nraise SystemExit(0)\n")
  File.chmod(path, 0o755)
  path
end

# A playbook-adjacent library/ module, so the task dispatches through
# the arbitrary-python-module runner instead of a native plugin.
private def write_whichpy(root : String) : Nil
  Dir.mkdir_p(File.join(root, "library"))
  File.write(File.join(root, "library", "whichpy.py"), <<-PYTHON)
    #!/usr/bin/python
    import sys
    from ansible.module_utils.basic import AnsibleModule

    def main():
        module = AnsibleModule(argument_spec={})
        module.exit_json(changed=False, executable=sys.executable)

    if __name__ == '__main__':
        main()
    PYTHON
end

private def run_playbook(root : String, inventory : String, bin : String, playbook : String) : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inventory, playbook], output: output, error: output,
    chdir: root, env: {"PATH" => "#{bin}:#{ENV["PATH"]}"})
  {status, output.to_s}
end

describe "which Python runs a delegated/custom module (issue #1005)" do
  it "runs a delegate_to: localhost module under the interpreter ansible itself runs under" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")

    root = PluginSpecHelper.tmp_path("delegated-python-interpreter")
    bin = File.join(root, "bin")
    # The controller python real would report as sys.executable...
    controller_python = write_marker_interpreter(bin, "python3", "ansibles-own-python")
    write_ansible_playbook(bin, controller_python)
    # ...and an interpreter pinned for the plain (non-delegated) host, so
    # the two cases cannot be satisfied by the same fallback.
    pinned = write_marker_interpreter(bin, "pinned-python", "the-inventory-pin")
    write_whichpy(root)
    File.write(File.join(root, "inv.ini"), "target ansible_connection=local\n")
    File.write(File.join(root, "inv_pinned.ini"),
      "target ansible_connection=local ansible_python_interpreter=#{pinned}\n")
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: target
        gather_facts: false
        tasks:
          - whichpy:
            delegate_to: localhost
            register: via_delegate
          - ansible.builtin.debug:
              msg: "DELEGATE {{ via_delegate.executable }}"
      YAML
    File.write(File.join(root, "pb_local.yml"), <<-YAML)
      - hosts: target
        gather_facts: false
        tasks:
          - whichpy:
            register: direct
          - ansible.builtin.debug:
              msg: "DIRECT {{ direct.executable }}"
      YAML

    # The issue's own repro: delegated to localhost, no interpreter var
    # anywhere, so real runs it under its own python.
    status, output = run_playbook(root, File.join(root, "inv.ini"), bin, "pb.yml")
    status.success?.must_equal(true, output)
    output.must_include("DELEGATE ansibles-own-python", output)

    # The same module on a plain local connection honours the inventory's
    # ansible_python_interpreter, the way real's _get_shebang does.
    status, output = run_playbook(root, File.join(root, "inv_pinned.ini"), bin, "pb_local.yml")
    status.success?.must_equal(true, output)
    output.must_include("DIRECT the-inventory-pin", output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "exposes that interpreter through hostvars['localhost']" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")

    root = PluginSpecHelper.tmp_path("implicit-localhost-hostvars-interpreter")
    bin = File.join(root, "bin")
    controller_python = write_marker_interpreter(bin, "python3", "ansibles-own-python")
    write_ansible_playbook(bin, controller_python)
    File.write(File.join(root, "inv.ini"), "target ansible_connection=local\n")
    # Real sets it as a host var on the implicit host, so it shows up in
    # hostvars for plays that never target localhost at all.
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: target
        gather_facts: false
        tasks:
          - ansible.builtin.debug:
              var: hostvars['localhost'].ansible_python_interpreter
      YAML

    status, output = run_playbook(root, File.join(root, "inv.ini"), bin, "pb.yml")
    status.success?.must_equal(true, output)
    output.must_include(%("hostvars['localhost'].ansible_python_interpreter": "#{controller_python}"), output)
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "ranks a delegated task's play and task interpreter above the delegate's host vars" do
    skip("python3 not available") unless File.exists?("/usr/bin/python3")

    root = PluginSpecHelper.tmp_path("delegated-python-interpreter-precedence")
    bin = File.join(root, "bin")
    controller_python = write_marker_interpreter(bin, "python3", "ansibles-own-python")
    write_ansible_playbook(bin, controller_python)
    task_pin = write_marker_interpreter(bin, "task-pin-python", "the-task-pin")
    play_pin = write_marker_interpreter(bin, "play-pin-python", "the-play-pin")
    origin_pin = write_marker_interpreter(bin, "origin-pin-python", "the-origin-host-pin")
    write_whichpy(root)
    # The origin host pins an interpreter of its OWN - a value real never
    # applies to the delegate, since a delegated task runs under the
    # delegate's vars, while the play/task vars outrank the delegate's
    # host vars.
    File.write(File.join(root, "inv.ini"),
      "target ansible_connection=local ansible_python_interpreter=#{origin_pin}\n")
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: target
        gather_facts: false
        tasks:
          - whichpy:
            delegate_to: localhost
            vars:
              ansible_python_interpreter: #{task_pin}
            register: task_pinned
          - whichpy:
            delegate_to: localhost
            register: plain
          - ansible.builtin.debug:
              msg: "TASK {{ task_pinned.executable }} PLAIN {{ plain.executable }}"
      YAML
    File.write(File.join(root, "pb_playvar.yml"), <<-YAML)
      - hosts: target
        gather_facts: false
        vars:
          ansible_python_interpreter: #{play_pin}
        tasks:
          - whichpy:
            delegate_to: localhost
            register: play_pinned
          - ansible.builtin.debug:
              msg: "PLAYVAR {{ play_pinned.executable }}"
      YAML

    status, output = run_playbook(root, File.join(root, "inv.ini"), bin, "pb.yml")
    status.success?.must_equal(true, output)
    output.must_include("TASK the-task-pin PLAIN ansibles-own-python", output)

    status, output = run_playbook(root, File.join(root, "inv.ini"), bin, "pb_playvar.yml")
    status.success?.must_equal(true, output)
    output.must_include("PLAYVAR the-play-pin", output)
  ensure
    FileUtils.rm_rf(root) if root
  end
end
