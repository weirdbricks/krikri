require "../minitest_helper"
require "file_utils"

# A task param that arrives through a YAML merge key (`<<: *name`) is not
# written in the task itself, so the origin scan finds no `key:` line in
# the task's span and krikri used to fall back to the module key line.
# ansible-core 2.19 instead points the innermost Origin at the value token
# on the ANCHOR DEFINITION's line - the anchor lives under the task's
# `vars:` ABOVE the module key, while the `<<:` line is below it (real
# CiscoUcs.ucs/admin/timezone shape, issue #376, live-captured vs 2.19:
# tasks/main.yml:7:17, caret under the opening quote of
# `hostname: "{{ ucs_hostname }}"`, context showing the two anchor lines).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (merge-key param)" do
  it "points the innermost Origin at the value token on the anchor definition line" do
    tempdir = File.tempname("final-merge-key").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "mergerole")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - mergerole
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      - name: Configure Time Zone
        vars:
          login_info: &login_info
            hostname: "{{ ucs_hostname }}"
            username: "{{ ucs_username }}"
        block:
        - name: Configure Time Zone
          ansible.builtin.set_fact:
            <<: *login_info
            timezone: UTC
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'hostname': 'ucs_hostname' is undefined")
    # 10 spaces + `hostname: ` puts the value quote at column 17, line 4.
    text.must_include("Error while resolving value for 'hostname': 'ucs_hostname' is undefined\nOrigin: #{tasks_file}:4:17\n")
    text.must_include("                  ^ column 17\n")
    text.must_include("\n2   vars:\n3     login_info: &login_info\n4       hostname: \"{{ ucs_hostname }}\"\n")
    text.wont_include("Error while resolving value for 'hostname': 'ucs_hostname' is undefined\nOrigin: #{tasks_file}:8:")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
