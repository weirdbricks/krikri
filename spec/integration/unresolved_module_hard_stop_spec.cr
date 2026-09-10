require "../spec_helper"
require "file_utils"

# The UnresolvedModuleError hard-stop, end to end: a task whose module
# name resolves to nothing krikri can run - a tombstoned-removed module
# like `ec2_remote_facts`, OR (since 0.9.903, owner decision, safety-
# motivated) ANY module krikri simply hasn't implemented yet - must
# refuse to run the playbook AT ALL, rc=4, no PLAY RECAP, nothing
# executes - matching real Ansible's own playbook-load module-resolution
# check for the tombstone case (verified live against ansible-core
# 2.19.4, including the when:-gated variant: the resolution check is a
# playbook-LOAD check there, not a per-task one), and krikri's own
# explicit safety posture for the "real Ansible would resolve this fine,
# krikri just hasn't ported it" case (a silently-skipped task with real
# consequences - a firewall rule, a security config - is worse than
# refusing to run).
#
# Before 0.9.903, only tombstoned names hard-stopped; everything else
# unresolvable took a graceful per-task unavailable_module skip (warning
# printed, task marked skipped, play continued) - see git log /
# KNOWN_MISSING.md for that history. The ONLY module resolving to
# nothing krikri ships that still degrades gracefully is a role-private
# `library/<name>.py` (or playbook-adjacent `library/`) source, which
# genuinely runs via PythonModuleRunner - that's not "unimplemented",
# it's a real module this engine executes.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(pb : String) : {Process::Status, String}
  playbook = File.tempname("unresolved-module", ".yml")
  File.write(playbook, pb)
  captured = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: captured, error: captured)
  {status, captured.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "unresolvable module names hard-stop the run (UnresolvedModuleError)" do
  it "aborts before any task runs for a bare module removed from ansible-core (ec2_remote_facts)" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: removed module
            ec2_remote_facts:
          - name: normal
            ansible.builtin.debug: msg=hi
      YAML
    status.success?.should be_false, output
    output.should contain("[ERROR]: couldn't resolve module/action 'ec2_remote_facts'"), output
    output.should_not contain("PLAY RECAP"), output
    output.should_not contain("TASK ["), output
    output.should_not contain("Gathering Facts"), output
  end

  it "hard-stops for a module from a collection with zero krikri modules (0.9.903, unconditional - was a graceful skip before)" do
    # kubernetes.core is a real, commonly-installed collection real
    # ansible-playbook would resolve and run fine here - krikri simply
    # hasn't ported this specific module, and since 0.9.903 that's
    # ALSO refused, with krikri's own wording (not real Ansible's, which
    # would have succeeded). Also confirms the hard-stop is UNCONDITIONAL,
    # same as the tombstone shape above: a when:-gated task that would
    # never actually run on this host still aborts the whole load.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: normal
            ansible.builtin.debug: msg=hi
          - name: unported collection, when-gated - still hard-stops
            kubernetes.core.helm_repository:
              repo_name: foo
            when: ansible_os_family == "Windows"
      YAML
    status.success?.should be_false, output
    status.exit_code.should eq(4), output
    output.should contain("krikri does not yet have module 'kubernetes.core.helm_repository' implemented"), output
    output.should_not contain("PLAY RECAP"), output
  end

  it "hard-stops for a not-yet-implemented module from a RECOGNIZED collection too (0.9.903, unconditional)" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: unimplemented builtin
            ansible.builtin.sysvinit:
              name: foo
          - name: normal
            ansible.builtin.debug: msg=hi
      YAML
    status.success?.should be_false, output
    status.exit_code.should eq(4), output
    output.should contain("krikri does not yet have module 'ansible.builtin.sysvinit' implemented"), output
    output.should_not contain("PLAY RECAP"), output
  end

  it "hard-stops for an unimplemented module used as a HANDLER too, not just as a regular task (0.9.903)" do
    # juju4.falco's own shape: kubernetes.core.helm_repository as a
    # notified handler, not a regular task - the parse-time hard-stop
    # applies identically regardless of where in the playbook the name
    # appears, same as the tombstone shape.
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: normal task that notifies the handler
            ansible.builtin.debug: msg=hi
            notify: unported handler
        handlers:
          - name: unported handler
            kubernetes.core.helm_repository:
              repo_name: foo
      YAML
    status.success?.should be_false, output
    status.exit_code.should eq(4), output
    output.should contain("krikri does not yet have module 'kubernetes.core.helm_repository' implemented"), output
    output.should_not contain("PLAY RECAP"), output
  end

  it "still runs a role-private library/*.py module (the one exception - genuinely runs here, not unimplemented)" do
    root = File.tempname("role-private-module-still-runs")
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "library"))
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "tasks"))
    File.write(File.join(root, "roles", "reprorole", "library", "reprofilter.py"), <<-PYTHON)
      #!/usr/bin/python
      print('{"changed": true, "msg": "ran"}')
      PYTHON
    File.write(File.join(root, "roles", "reprorole", "tasks", "main.yml"), <<-YAML)
      - name: dispatch a role-private python module
        reprofilter:
          name: x
      YAML
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - reprorole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.should be_true, output.to_s
    output.to_s.should contain("PLAY RECAP"), output.to_s
    output.to_s.should_not contain("krikri does not yet have module"), output.to_s
  ensure
    FileUtils.rm_rf(root) if root
  end
end
