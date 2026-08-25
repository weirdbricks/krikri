require "file_utils"
require "../spec_helper"

# `module_defaults:` supplies per-module default arguments. It was
# parsed to nothing, so a task relying on it ran with the argument
# MISSING - `ansible.builtin.debug:` with its msg coming from defaults
# failed outright with "msg or var parameter required".
#
# Expectations from an ansible-core 2.19.4 run of the same playbooks.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")

private def markers(playbook : String) : Array(String)
  dir = File.tempname("module-defaults")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), "localhost ansible_connection=local\n")
  File.write(File.join(dir, "pb.yml"), playbook)

  stdout_io = IO::Memory.new
  Process.run(BINARY, ["-i", "inv.ini", "pb.yml"], output: stdout_io, error: stdout_io, chdir: dir)
  stdout_io.to_s.scan(/^\s{2}([A-Z_]+)$/m).map { |m| m[1] }
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "module_defaults:" do
  # A task's own argument always beats a default. And the key matches on
  # the BARE module name, so an FQCN key supplies defaults to a
  # short-name task (verified both directions against real Ansible).
  it "applies play defaults, lets the task override, and matches short vs FQCN names" do
    markers(<<-YAML).should eq(["FROM_DEFAULTS", "FROM_TASK", "FROM_DEFAULTS"])
      - hosts: all
        gather_facts: false
        module_defaults:
          ansible.builtin.debug:
            msg: "FROM_DEFAULTS"
        tasks:
          - name: uses default
            ansible.builtin.debug:
          - name: overrides default
            ansible.builtin.debug:
              msg: "FROM_TASK"
          - name: short name form
            debug:
      YAML
  end

  # Play, block and task scope, nearest winning.
  it "honors block and task scope over play scope" do
    markers(<<-YAML).should eq(["PLAY_DEFAULT", "BLOCK_DEFAULT", "TASK_DEFAULT"])
      - hosts: all
        gather_facts: false
        module_defaults:
          debug:
            msg: "PLAY_DEFAULT"
        tasks:
          - name: fqcn task, short key
            ansible.builtin.debug:
          - name: block scope
            module_defaults:
              debug:
                msg: "BLOCK_DEFAULT"
            block:
              - name: inside block
                ansible.builtin.debug:
          - name: task scope
            ansible.builtin.debug:
            module_defaults:
              debug:
                msg: "TASK_DEFAULT"
      YAML
  end

  # An action-group key is skipped rather than treated as a module name -
  # this engine has no notion of action groups, and a `group/...` entry
  # must not break the rest of the mapping alongside it.
  it "ignores a group/ action-group key without disturbing the others" do
    markers(<<-YAML).should eq(["STILL_APPLIED"])
      - hosts: all
        gather_facts: false
        module_defaults:
          group/aws:
            region: eu-west-1
          debug:
            msg: "STILL_APPLIED"
        tasks:
          - name: t
            ansible.builtin.debug:
      YAML
  end

  # Guard against over-reach: a module with no defaults entry is
  # untouched, and a task whose argument is absent everywhere still
  # fails the way it always did.
  it "leaves an unrelated module alone" do
    markers(<<-YAML).should eq(["EXPLICIT"])
      - hosts: all
        gather_facts: false
        module_defaults:
          ansible.builtin.file:
            mode: "0640"
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: "EXPLICIT"
      YAML
  end
end
