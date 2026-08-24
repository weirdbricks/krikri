require "file_utils"
require "../spec_helper"

# Real Ansible reserves exit code 4 for PARSER errors, distinct from 1
# (generic error), 2 (failed hosts) and 3 (unreachable). This engine
# exited 1 for both cases below. Verified against a real local
# ansible-core 2.19.4 install.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook_file(path : String, dir : String? = nil)
  stdout_io = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, path],
    output: stdout_io, error: stdout_io, chdir: dir)
  {status, stdout_io.to_s}
end

describe "parser-error exit code" do
  it "exits 4 for an unparseable playbook" do
    playbook = File.tempname("parser-exit", ".yml")
    File.write(playbook, "this: is: not: valid: yaml: [\n")

    begin
      status, _ = run_playbook_file(playbook)
      status.exit_code.should eq(4)
    ensure
      File.delete(playbook) if File.exists?(playbook)
    end
  end

  it "exits 4 when a static import path references a fact" do
    dir = File.tempname("parser-exit-import")
    Dir.mkdir_p(File.join(dir, "roles", "r", "tasks"))
    File.write(File.join(dir, "roles", "r", "tasks", "main.yml"), <<-YAML)
      - name: static import with a fact-derived filename
        ansible.builtin.import_tasks: "setup-{{ ansible_os_family }}.yml"
      YAML
    File.write(File.join(dir, "roles", "r", "tasks", "setup-Debian.yml"), <<-YAML)
      - name: debian setup
        ansible.builtin.debug:
          msg: "debian"
      YAML
    playbook = File.join(dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: true
        roles:
          - r
      YAML

    begin
      status, output = run_playbook_file("pb.yml", dir)
      status.exit_code.should eq(4)
      output.should contain("Static imports cannot use variables from facts")
    ensure
      FileUtils.rm_rf(dir) if Dir.exists?(dir)
    end
  end

  # Guard: a MISSING playbook is not a parser error - real Ansible exits
  # 1 there, and so must this engine (that check runs earlier, before
  # the parse block whose rc changed).
  it "still exits 1 for a missing playbook file" do
    status, _ = run_playbook_file("definitely-missing-playbook-xyz.yml")
    status.exit_code.should eq(1)
  end

  # Guard: the ordinary success / failed-host codes are untouched.
  it "still exits 0 on success and 2 on a failed task" do
    ok = File.tempname("parser-exit-ok", ".yml")
    File.write(ok, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: fine
            ansible.builtin.debug:
              msg: "fine"
      YAML

    bad = File.tempname("parser-exit-bad", ".yml")
    File.write(bad, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: boom
            ansible.builtin.command: /bin/false
      YAML

    begin
      run_playbook_file(ok)[0].exit_code.should eq(0)
      run_playbook_file(bad)[0].exit_code.should eq(2)
    ensure
      File.delete(ok) if File.exists?(ok)
      File.delete(bad) if File.exists?(bad)
    end
  end
end
