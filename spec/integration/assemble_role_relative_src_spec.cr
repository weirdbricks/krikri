require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug is in the
# task-executor's role-relative src: resolution (not in the assemble
# plugin itself, which handles absolute paths fine).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "assemble:'s relative src: resolves against the role's files/ directory" do
  it "resolves src: files/ (remote_src: false) to the role's own files/ dir" do
    # Real bug found benchmarking ome.prometheus_postgres: its
    # configuration task is `assemble: {src: "{{ prometheus_postgres_
    # query_directory }}", remote_src: false}` with the variable
    # defaulting to "files/" - fragment files shipped inside the role's
    # own files/ directory. Only copy:/template: were wired into
    # resolve_role_relative_src, so assemble:'s src: reached the plugin
    # as the bare relative string "files/" and failed with
    # "Source (files/) does not exist" while real ansible-playbook
    # (whose assemble action plugin runs _find_needle('files', src))
    # assembled it fine.
    src_dir = File.tempname("assemble-role-relative-src")
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "files"))
    Dir.mkdir_p(File.join(src_dir, "roles", "myrole", "tasks"))
    File.write(File.join(src_dir, "roles", "myrole", "files", "queries-default.yml"), "query one\n")
    File.write(File.join(src_dir, "roles", "myrole", "files", "queries-extra.yml"), "query two\n")
    File.write(File.join(src_dir, "roles", "myrole", "files", "README.md"), "not a fragment\n")
    File.write(File.join(src_dir, "roles", "myrole", "tasks", "main.yml"), <<-YAML)
      - name: assemble role-relative src
        ansible.builtin.assemble:
          src: files/
          dest: #{File.join(src_dir, "out.yml")}
          remote_src: false
          regexp: "^queries-.*$"
          mode: "0644"
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

    status.success?.should be_true, output.to_s
    output.to_s.should_not contain("does not exist")
    File.read(File.join(src_dir, "out.yml")).should eq("query one\nquery two\n")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
