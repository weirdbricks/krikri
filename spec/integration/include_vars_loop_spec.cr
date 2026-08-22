require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook, since this bug is
# in the executor's controller-side include_vars: dispatch, not
# something a unit spec against a single method can exercise cleanly
# (it needs the real loop/vars/when interplay end to end).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "include_vars: with a literal loop: (not with_first_found:)" do
  it "evaluates when: per item, with `item` bound, instead of skipping the whole task" do
    # Real bug found benchmarking linux-system-roles.storage (round
    # 159). Its own tasks/set_vars.yml has:
    #   include_vars: "{{ __vars_file }}"
    #   loop: ["{{ os_family }}.yml", "{{ distribution }}_{{ major }}.yml", ...]
    #   vars:
    #     __vars_file: "{{ role_path }}/vars/{{ item }}"
    #   when: __vars_file is file
    # include_vars: only ever supported with_first_found: as a loop
    # form - a plain loop: was dispatched straight to
    # execute_include_vars before the executor's generic loop-handling
    # ever ran, so the task executed once with `item` never bound:
    # `__vars_file` rendered with a literal "undefined" item, the
    # `is file` test failed for every candidate, and the whole task
    # silently skipped instead of loading the one candidate that
    # actually exists on disk.
    src_dir = File.tempname("include-vars-loop-role")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "vars"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "vars", "present.yml"), "myvar: [foo, bar]\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Set platform/version specific variables
        include_vars: "{{ __vars_file }}"
        loop:
          - "absent.yml"
          - "present.yml"
        vars:
          __vars_file: "{{ role_path }}/vars/{{ item }}"
        when: __vars_file is file
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        roles:
          - myrole
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.should be_true
    output.to_s.should contain("ok: [localhost] => (item=present.yml)")
    output.to_s.should contain("skipping: [localhost] => (item=absent.yml)")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
