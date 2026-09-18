require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the bug spans the
# parser (string module args that are one whole {{ ... }} expression
# must NOT become _raw_params) and the executor (the substituted dict
# becomes the module's real params).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "whole-args template (`module: \"{{ item }}\"`)" do
  # Real bug found in round 827232 (calvinbui.ansible_apt): its only
  # task is `apt: "{{ item }}"` with `loop: "{{ apt_install_packages }}"`,
  # each item a dict like {"name": "git"}. Real Ansible templates the
  # args string first and, because the rendered value is a dict, uses it
  # AS the module params; krikri kv-parsed the raw template text, found
  # no "=", and dumped it into _raw_params, which apt's strict argument
  # spec rejected ("Unsupported parameters ... _raw_params").
  it "expands a dict-valued loop item into the module's real params" do
    src_dir = File.tempname("whole-args-template")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: templated whole args
            debug:
              "{{ item }}"
            loop:
              - {"msg": "expanded-ok"}
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, File.join(src_dir, "pb.yml")],
      output: output, error: output, chdir: src_dir)
    text = output.to_s
    status.success?.should be_true, text
    text.should contain("expanded-ok")
    text.should_not contain("_raw_params")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "expands a string-valued loop item via free-form k=v parsing" do
    src_dir = File.tempname("whole-args-template-kv")
    Dir.mkdir_p(src_dir)
    File.write(File.join(src_dir, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: templated string args
            debug:
              "{{ item }}"
            loop:
              - "msg=k=v-works"
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, File.join(src_dir, "pb.yml")],
      output: output, error: output, chdir: src_dir)
    text = output.to_s
    status.success?.should be_true, text
    text.should contain("k=v-works")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
