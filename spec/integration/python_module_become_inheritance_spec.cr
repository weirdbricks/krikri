require "../spec_helper"
require "file_utils"

# Regression spec for a real become-resolution inconsistency found
# while investigating (but NOT the actual root cause of) newrelic.
# newrelic-infra's merge_yaml become failure: execute_python_module
# (the role-private library/*.py dispatcher) passed task.become? -
# the task's OWN parse-time guess - to PluginManager.execute_plugin,
# instead of the caller's already-resolved `become` value
# (resolve_task_become, which re-renders a TEMPLATED become:
# expression against live vars at runtime). Every OTHER plugin
# dispatch in the same method already used the resolved value; only
# the python-module path used the raw parse-time flag.
#
# This matters specifically for a TEMPLATED become: on the task itself
# (`become: "{{ some_var }}"`) - PlaybookParser.parse_become_value's
# own parse-time guess defaults ANY templated value to true (same
# wrong-direction guess ignore_errors:/no_log: shared, fixed
# elsewhere this session), so a python-module task with `become: "{{
# do_become }}"` resolving to false at runtime still had task.become?
# read as true, and used to attempt an unnecessary (and, on a
# controller without passwordless sudo for the target user, failing)
# privilege escalation. A LITERAL play-level `become: true` with no
# per-task become: at all was already handled correctly before this
# fix (PlaybookParser.resolve_become applies the play's own literal
# value as a fallback at PARSE time, so task.become? already carried
# it) - this spec covers the templated case specifically, where the
# two actually diverge.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "role-private python module dispatch re-resolves a templated become: at runtime" do
  it "does not attempt privilege escalation when a templated become: resolves to false" do
    root = File.tempname("py-module-become")
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "library"))
    Dir.mkdir_p(File.join(root, "roles", "reprorole", "tasks"))
    Dir.mkdir_p(File.join(root, "stub_bin"))

    sudo_log = File.join(root, "sudo_calls.log")
    File.write(File.join(root, "stub_bin", "sudo"), <<-SHIM)
      #!/bin/sh
      echo "$@" >> #{sudo_log}
      exit 1
      SHIM
    File.chmod(File.join(root, "stub_bin", "sudo"), 0o755)

    # A minimal old-style role-private module (no ansible.module_utils
    # import needed) that just prints a fixed result - become
    # resolution is what's under test here, not the module's own logic.
    File.write(File.join(root, "roles", "reprorole", "library", "reprofilter.py"), <<-PYTHON)
      #!/usr/bin/python
      print('{"changed": true, "msg": "ran"}')
      PYTHON

    File.write(File.join(root, "roles", "reprorole", "tasks", "main.yml"), <<-YAML)
      - name: dispatch python module with a templated become resolving to false
        reprofilter:
          name: x
        become: "{{ do_become }}"
        vars:
          do_become: false
      YAML

    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - reprorole
      YAML

    env = ENV.to_h
    env["PATH"] = "#{File.join(root, "stub_bin")}:#{env["PATH"]}"

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], env: env, output: output, error: output, chdir: root)

    status.success?.should be_true, output.to_s
    File.exists?(sudo_log).should be_false, output.to_s
  ensure
    FileUtils.rm_rf(root) if root
  end
end
