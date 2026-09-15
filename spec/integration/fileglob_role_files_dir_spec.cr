require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since this bug is specifically about
# TaskExecutor#resolve_fileglob, a private method not reachable from a
# unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# Real bug found in the mismatch-traefik round: a role task
# `with_fileglob: "*.yml"` globbed the process's current working
# directory (resolve_fileglob passed the bare pattern to Dir.glob with
# NO base-directory resolution at all), so a playbook file sitting in
# the invocation directory matched ITSELF - real ansible-playbook's own
# fileglob lookup dwims a relative pattern against the role's files/
# dir (path_dwim_relative with 'files') and found only the role's
# middleware.yml/redirect.yml, never the playbook file. Confirmed live
# against real ansible-playbook.
describe "with_fileglob: relative pattern inside a role" do
  it "resolves a bare pattern against the role's files/ dir, yielding full resolved paths" do
    dir = File.tempname("fileglob-role-spec")
    Dir.mkdir_p(File.join(dir, "roles", "myrole", "files"))
    Dir.mkdir_p(File.join(dir, "roles", "myrole", "tasks"))
    File.write(File.join(dir, "roles", "myrole", "files", "middleware.yml"), "m")
    File.write(File.join(dir, "roles", "myrole", "files", "redirect.yml"), "r")
    # The decoy: a playbook-named file matching *.yml in the invocation
    # directory - exactly what krikri globbed instead of the role's
    # files/ dir before this fix.
    File.write(File.join(dir, "site.yml"), "decoy")

    File.write(File.join(dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: glob
        ansible.builtin.debug:
          msg: "{{ item }}"
        with_fileglob: "*.yml"
        register: glob_result
      - name: assert count
        ansible.builtin.assert:
          that:
            - glob_result.results | length == 2
      YAML

    File.write(File.join(dir, "playbook.yml"), <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "playbook.yml"], output: output, error: output, chdir: dir)

    status.success?.should be_true
    role_files = File.join(dir, "roles", "myrole", "files")
    output.to_s.should contain(File.join(role_files, "middleware.yml"))
    output.to_s.should contain(File.join(role_files, "redirect.yml"))
    output.to_s.should_not contain("site.yml")
  ensure
    FileUtils.rm_rf(dir) if dir
  end

  it "resolves each item of a JSON-array pattern list against the role's files/ dir too" do
    # `with_fileglob: "{{ some_list_var }}"` (real Ansible's own idiom,
    # see fileglob_list_spec) goes through resolve_fileglob's
    # JSON-array branch, which shared the same cwd-relative globbing -
    # the fix has to cover both branches identically.
    dir = File.tempname("fileglob-role-list-spec")
    Dir.mkdir_p(File.join(dir, "roles", "myrole", "files"))
    Dir.mkdir_p(File.join(dir, "roles", "myrole", "tasks"))
    File.write(File.join(dir, "roles", "myrole", "files", "middleware.yml"), "m")
    File.write(File.join(dir, "roles", "myrole", "files", "redirect.yml"), "r")
    File.write(File.join(dir, "site.yml"), "decoy")

    File.write(File.join(dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: glob
        ansible.builtin.debug:
          msg: "{{ item }}"
        with_fileglob: "{{ glob_patterns }}"
        register: glob_result
      - name: assert count
        ansible.builtin.assert:
          that:
            - glob_result.results | length == 2
      YAML

    File.write(File.join(dir, "playbook.yml"), <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          glob_patterns:
            - "*.yml"
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "playbook.yml"], output: output, error: output, chdir: dir)

    status.success?.should be_true
    role_files = File.join(dir, "roles", "myrole", "files")
    output.to_s.should contain(File.join(role_files, "middleware.yml"))
    output.to_s.should contain(File.join(role_files, "redirect.yml"))
    output.to_s.should_not contain("site.yml")
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
