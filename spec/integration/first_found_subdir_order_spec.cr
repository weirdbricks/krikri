require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in which
# role subdirs the executor's with_first_found: KEYWORD form (not the
# lookup('first_found', ...) function form) searches by default, which
# only shows up with a real role dispatch.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "with_first_found: default search roots vs the task's action" do
  it "never matches vars/ for an include_tasks: with_first_found:, even when vars/ has the candidate" do
    # Real divergence benchmarking ccdc.ntp_configuration: its "Set up
    # NTP time synchronisation" include_tasks: + with_first_found: has
    # bare OS candidates and, on Debian, tasks/Debian.yml does not exist
    # but vars/Debian.yml (a vars MAPPING) does. Real ansible-playbook
    # (core 2.19.x) skips straight past it and resolves to
    # tasks/Linux.yml; krikri searched vars/ before tasks/ and matched
    # vars/Debian.yml, failing with "Included tasks file must be a YAML
    # list". A vars file can never be a valid include target, so vars/
    # (and files//templates/) must not be searched at all for an
    # include_tasks: action.
    src_dir = File.tempname("first-found-include-tasks-not-vars")
    role = File.join(src_dir, "roles", "myrole")
    Dir.mkdir_p(File.join(role, "tasks"))
    Dir.mkdir_p(File.join(role, "vars"))
    File.write(File.join(role, "vars", "Debian.yml"), <<-YAML)
      ntp_marker: from-vars-debian-yml
      YAML
    File.write(File.join(role, "tasks", "Linux.yml"), <<-YAML)
      - name: linux specific tasks
        ansible.builtin.debug:
          msg: TASKS_LINUX_YML
      YAML
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: Set up NTP time synchronisation
        include_tasks: "{{ taskfile }}"
        with_first_found:
          - "{{ ansible_distribution }}-{{ ansible_distribution_major_version }}.yml"
          - "{{ ansible_distribution }}.yml"
          - "{{ ansible_os_family }}.yml"
          - "{{ ansible_system }}.yml"
        loop_control:
          loop_var: taskfile
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_distribution: Debian
          ansible_distribution_major_version: "13"
          ansible_os_family: Debian
          ansible_system: Linux
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("TASKS_LINUX_YML")
    output.to_s.should_not contain("must be a YAML list")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "still finds an include_vars: with_first_found: candidate living under the role's tasks/ dir" do
    # Real divergence benchmarking so5.ssh_hostbased_auth and so5.pbspro:
    # their "include OS specific vars." include_vars: + with_first_found:
    # dict form (files: [...], no paths:) names a setup-<OS>.yml file
    # that only exists under tasks/ (never vars/ or files/). include_
    # file_dir is only set for include_tasks: statements, so a task
    # declared directly in a role's top-level tasks/main.yml previously
    # had no tasks/ root at all - the lookup exhausted and failed with
    # "No file was found when using first_found." where real Ansible
    # resolved to tasks/setup-Debian.yml and the role ran to completion.
    src_dir = File.tempname("first-found-include-vars-under-tasks")
    role = File.join(src_dir, "roles", "myrole")
    Dir.mkdir_p(File.join(role, "tasks"))
    Dir.mkdir_p(File.join(role, "vars"))
    File.write(File.join(role, "vars", "main.yml"), <<-YAML)
      unrelated: var
      YAML
    File.write(File.join(role, "tasks", "setup-Debian.yml"), <<-YAML)
      os_marker: from-tasks-setup-debian
      YAML
    File.write(File.join(role, "tasks", "main.yml"), <<-YAML)
      - name: include OS specific vars.
        include_vars: "{{ item }}"
        with_first_found:
          - files:
              - "setup-{{ ansible_distribution }}-{{ ansible_distribution_major_version }}.yml"
              - "setup-{{ ansible_distribution }}.yml"
              - "setup-{{ ansible_os_family }}.yml"
            skip: false
      - name: show loaded var
        ansible.builtin.debug:
          msg: "os_marker={{ os_marker }}"
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_distribution: Debian
          ansible_distribution_major_version: "13"
          ansible_os_family: Debian
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("os_marker=from-tasks-setup-debian")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
