require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in the
# executor's general with_first_found: no-match handling, which needs a
# real role/include_tasks dispatch to exercise cleanly.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "with_first_found: with no candidate matching (no skip:)" do
  it "fails an include_tasks: + with_first_found: task instead of silently skipping it" do
    # Real bug found benchmarking ccdc.cpp_gui_dev_tools (Atlantic round
    # 310144): its "Set up GUI developer tools" task is
    #   include_tasks: "{{ taskfile }}"
    #   with_first_found: ["{{ ansible_distribution }}-{{ ansible_
    #     distribution_major_version }}.yml", ...]
    # On a host whose distribution/family matches none of the role's
    # own tasks/<OS>.yml files, real ansible-playbook (core 2.19.4,
    # verified live with a minimal repro) FAILS the task with
    # "The lookup plugin 'first_found' failed: No file was found when
    # using first_found." - the keyword form's lookup raises for a
    # miss regardless of which module it is attached to. krikri
    # previously returned an empty loop list here, which surfaced as a
    # silent skip (failed=0 skipped=1) where real Ansible recaps
    # failed=1 - hiding a role that did nothing at all on that OS.
    src_dir = File.tempname("first-found-no-match-include-tasks")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "Debian.yml"), <<-YAML)
      - name: debian specific
        ansible.builtin.debug:
          msg: MATCHED_DEBIAN_YML
      YAML
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Set up GUI developer tools
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
          ansible_distribution: Rocky
          ansible_distribution_major_version: "9"
          ansible_os_family: RedHat
          ansible_system: Linux
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_false
    output.to_s.should contain("No file was found when using first_found")
    output.to_s.should contain("failed=1")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "still skips when the miss is explicitly skip: true, and still includes on a match" do
    src_dir = File.tempname("first-found-no-match-skip-true")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "Debian.yml"), <<-YAML)
      - name: debian specific
        ansible.builtin.debug:
          msg: MATCHED_DEBIAN_YML
      YAML
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: include os tasks
        include_tasks: "{{ taskfile }}"
        with_first_found:
          - files: "{{ ansible_os_family }}.yml"
            skip: true
        loop_control:
          loop_var: taskfile
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_os_family: RedHat
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("skipped=1")
    output.to_s.should_not contain("MATCHED_DEBIAN_YML")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "still includes the matched file when a candidate exists" do
    src_dir = File.tempname("first-found-no-match-still-includes")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "Debian.yml"), <<-YAML)
      - name: debian specific
        ansible.builtin.debug:
          msg: MATCHED_DEBIAN_YML
      YAML
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: include os tasks
        include_tasks: "{{ taskfile }}"
        with_first_found:
          - "{{ ansible_os_family }}.yml"
        loop_control:
          loop_var: taskfile
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          ansible_os_family: Debian
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("MATCHED_DEBIAN_YML")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
