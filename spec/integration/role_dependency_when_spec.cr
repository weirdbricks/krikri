require "../spec_helper"
require "file_utils"

# A `when:` on a roles: entry, or on a meta/main.yml dependency entry
# (real Ansible's own RoleRequirement field, same shape in both places),
# is combined onto EVERY task the referenced role expands to - the role
# reference itself produces no result of its own. RoleLoader previously
# had no notion of `when:` on a role entry at all: `parse_role_entry`
# silently dropped it (worse, it leaked through as a fake role VAR
# literally named "when"), so a role dependency's tasks ran
# unconditionally regardless of its own when:.
#
# Found via Graylog2.graylog's own meta/main.yml dependency on
# lean_delivery.java (`when: graylog_install_java`, undefined - real
# Ansible fails/skips the WHOLE dependency's task tree; this engine ran
# it anyway, which walked straight into a real network 404 partway
# through that dependency's own task list).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "when: on a role entry propagates onto every task the role expands to" do
  it "a meta/main.yml dependency's own when: gates its whole task tree" do
    src_dir = File.tempname("role-dep-when-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "meta"))
    Dir.mkdir_p(File.join(src_dir, "roles", "depped", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "meta", "main.yml"), <<-YAML)
      dependencies:
        - role: depped
          when: install_dep
      YAML
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: myrole task
        debug:
          msg: myrole ran
      YAML
    File.write(File.join(src_dir, "roles", "depped", "tasks", "main.yml"), <<-YAML)
      - name: depped task
        debug:
          msg: DEP_SHOULD_NOT_RUN
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          install_dep: false
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("TASK [depped : depped task]")
    output.to_s.should_not contain("DEP_SHOULD_NOT_RUN")
    output.to_s.should contain("myrole ran")
    output.to_s.should match(/skipped=1\b/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "a play-level roles: entry's own when: gates its whole task tree" do
    src_dir = File.tempname("role-dep-when-play-level-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "a", "tasks"))
    File.write(File.join(src_dir, "roles", "a", "tasks", "main.yml"), <<-YAML)
      - name: a task
        debug:
          msg: A_SHOULD_NOT_RUN
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          run_a: false
        roles:
          - role: a
            when: run_a
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should_not contain("A_SHOULD_NOT_RUN")
    output.to_s.should match(/skipped=1\b/)
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "still runs the dependency normally when its own when: is true" do
    src_dir = File.tempname("role-dep-when-true-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "meta"))
    Dir.mkdir_p(File.join(src_dir, "roles", "depped", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "meta", "main.yml"), <<-YAML)
      dependencies:
        - role: depped
          when: install_dep
      YAML
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: myrole task
        debug:
          msg: myrole ran
      YAML
    File.write(File.join(src_dir, "roles", "depped", "tasks", "main.yml"), <<-YAML)
      - name: depped task
        debug:
          msg: DEP_DID_RUN
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          install_dep: true
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("DEP_DID_RUN")
    output.to_s.should contain("myrole ran")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
