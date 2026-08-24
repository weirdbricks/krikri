require "file_utils"
require "../spec_helper"

# A static import whose target can only be known from a FACT is refused
# before anything runs - real Ansible resolves import_tasks:/import_role:
# up front, against vars/extra-vars only. Verified against ansible-core
# 2.19.4, including the two different exit codes it uses.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_in_dir(yaml : String, &)
  dir = File.tempname("static-import")
  Dir.mkdir_p(File.join(dir, "roles", "myrole", "tasks"))
  File.write(File.join(dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
    - name: role task
      ansible.builtin.debug: {msg: "MYROLE"}
    YAML
  File.write(File.join(dir, "setup-Debian.yml"), <<-YAML)
    - name: inner
      ansible.builtin.debug: {msg: "INNER"}
    YAML
  File.write(File.join(dir, "pb.yml"), yaml)

  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"],
    output: stdout_io, error: stdout_io, chdir: dir)
  yield({status, stdout_io.to_s})
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "static import referencing a fact" do
  # import_tasks: PATH -> real Ansible's parser error, exit 4. This used
  # to be SILENT: the templated path missed the file and the task was
  # dropped with no banner, no failure and exit 0.
  it "refuses an import_tasks: path built from a fact, running nothing" do
    run_in_dir(<<-YAML) do |status, output|
      - name: P
        hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: BEFORE
            ansible.builtin.debug: {msg: "BEFORE"}
          - name: the import
            ansible.builtin.import_tasks: "setup-{{ ansible_os_family }}.yml"
      YAML
      status.exit_code.should eq(4)
      output.should_not contain("BEFORE")
      output.should contain("Error when evaluating variable in import path")
    end
  end

  # import_role: NAME -> real Ansible reports a plain undefined-variable
  # error with exit code 1, NOT the parser error 4 above.
  it "refuses an import_role: name built from a fact, with exit code 1" do
    run_in_dir(<<-YAML) do |status, output|
      - name: P
        hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: BEFORE
            ansible.builtin.debug: {msg: "BEFORE"}
          - name: the import
            ansible.builtin.import_role:
              name: "{{ ansible_os_family }}"
      YAML
      status.exit_code.should eq(1)
      output.should_not contain("BEFORE")
      output.should contain("'ansible_os_family' is undefined")
    end
  end

  # The same, through a filter chain. Strict-undefined stays lenient for
  # filters by design, so this is caught by the rendered name coming back
  # empty rather than by a raise.
  it "refuses an import_role: name whose fact goes through a filter" do
    run_in_dir(<<-YAML) do |status, output|
      - name: P
        hosts: localhost
        connection: local
        gather_facts: true
        tasks:
          - name: BEFORE
            ansible.builtin.debug: {msg: "BEFORE"}
          - name: the import
            ansible.builtin.import_role:
              name: "{{ ansible_os_family | lower }}"
      YAML
      status.exit_code.should eq(1)
      output.should_not contain("BEFORE")
      output.should contain("'ansible_os_family' is undefined")
    end
  end

  # Guard against over-reach: a name from a PLAY VAR is resolvable before
  # the run, which real Ansible allows and must keep working.
  it "still allows an import_role: name from a play var" do
    run_in_dir(<<-YAML) do |status, output|
      - name: P
        hosts: localhost
        connection: local
        gather_facts: false
        vars:
          which_role: myrole
        tasks:
          - name: import by play var
            ansible.builtin.import_role:
              name: "{{ which_role }}"
      YAML
      status.exit_code.should eq(0)
      output.should contain("MYROLE")
    end
  end
end
