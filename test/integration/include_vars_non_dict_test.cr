require "../minitest_helper"
require "file_utils"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

describe "include_vars: of a file whose top level is not a mapping" do
  it "fails the with_first_found item instead of loading nothing" do
    # lean_delivery.oracle_instant_client ships vars/not-supported.yml as a
    # tasks-style list; ansible-core's include_vars refuses it with
    # "<path> must be stored as a dictionary/hash".
    src_dir = File.tempname("include-vars-non-dict")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "vars"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "vars", "list.yml"), "- name: x\n  debug:\n    msg: hi\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: Load a variables
        include_vars: "{{ platform }}"
        with_first_found:
          - "list.yml"
        loop_control:
          loop_var: platform
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

    status.success?.must_equal(false)
    output.to_s.must_include("failed: [localhost] (item=")
    output.to_s.must_include("vars/list.yml must be stored as a dictionary/hash")
    output.to_s.must_include("\"ansible_loop_var\": \"platform\"")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
