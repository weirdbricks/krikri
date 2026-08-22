require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook, since this bug is
# in the executor's include_role: vars: rendering path end to end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "include_role: vars: where one entry references a sibling entry" do
  it "resolves regardless of which entry is declared first in the YAML" do
    # Real bug found benchmarking linux-system-roles.logging (round
    # 159). Its own tasks/main.yml declares:
    #   vars:
    #     rsyslog_custom_config_files: "{{ __custom_config_files + logging_custom_config_files }}"
    #     __custom_config_files: "{{ logging_outputs | d([]) | ... | flatten | list }}"
    #   include_role:
    #     name: "{{ role_path }}/roles/rsyslog"
    # rsyslog_custom_config_files is declared BEFORE the
    # __custom_config_files entry it depends on. render_include_role_vars
    # rendered each vars: entry one at a time straight against the
    # ORIGINAL vars_context, which never had __custom_config_files in
    # it yet (it only exists as a sibling of the SAME vars: block) -
    # so `__custom_config_files + logging_custom_config_files` saw an
    # undefined left operand and silently mis-rendered to the STRING
    # "[]" instead of a real empty array, which `| flatten` downstream
    # then split into two bogus loop items ("[" and "]").
    src_dir = File.tempname("include-role-vars-xref")
    Dir.mkdir_p(File.join(src_dir, "roles", "inner", "tasks"))
    Dir.mkdir_p(File.join(src_dir, "roles", "outer", "tasks"))
    File.write(File.join(src_dir, "roles", "inner", "tasks", "main.yml"), <<-YAML)
      - name: probe
        debug:
          msg: "combined={{ my_list }} flattened={{ my_list | flatten }}"
      YAML
    File.write(File.join(src_dir, "roles", "outer", "tasks", "main.yml"), <<-YAML)
      - name: Include inner role
        vars:
          my_list: "{{ __helper_list + extra_list }}"
          __helper_list: "{{ source_list | d([]) | list }}"
        include_role:
          name: inner
      YAML

    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          source_list: []
          extra_list: []
        roles:
          - outer
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("combined=[] flattened=[]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
