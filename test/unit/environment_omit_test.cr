require "../minitest_helper"
require "file_utils"

# `environment: "{{ proxy_env | default(omit) }}"` with proxy_env undefined:
# ansible-playbook drops the environment entirely and runs the task (roles
# commonly leave proxy_env unset by design). krikri's string-form branch
# rendered the omit sentinel and JSON.parsed it, crashing task finalization
# with "Unexpected char '_'" before the task ever ran. Only a live local
# run proves the task actually executes with no env, since the substitution
# happens deep inside the executor's protected finalization block.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "environment string form rendering to omit drops the environment" do
  it "runs the task with no environment when the template resolves to omit" do
    root = File.tempname("environment-omit-undefined")
    Dir.mkdir_p(root)
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: prove no env is set
            ansible.builtin.command: sh -c 'test -z "$PROXY_ENV"'
            environment: "{{ proxy_env | default(omit) }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(true, output.to_s)
    output.to_s.wont_include("Unexpected char")
    output.to_s.wont_include("__crystal_ansible_omit__")
    output.to_s.must_include("failed=0")
  ensure
    FileUtils.rm_rf(root) if root
  end

  it "still applies the environment when the template resolves to a dict" do
    root = File.tempname("environment-omit-defined")
    Dir.mkdir_p(root)
    File.write(File.join(root, "pb.yml"), <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: prove the env value is set
            ansible.builtin.command: sh -c 'test "$PROXY_ENV" = set'
            environment: "{{ proxy_env | default(omit) }}"
            vars:
              proxy_env:
                PROXY_ENV: set
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, "pb.yml"], output: output, error: output, chdir: root)

    status.success?.must_equal(true, output.to_s)
    output.to_s.must_include("failed=0")
  ensure
    FileUtils.rm_rf(root) if root
  end
end
