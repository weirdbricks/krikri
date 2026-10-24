require "../minitest_helper"
require "file_utils"

# A block-style LIST param (s2ansible.zabbix_host's local_action
# zabbix_host `host_groups` with an undefined var, issue #323) chains
# the same two MORE error levels as a block-style mapping param (issue
# #265): ansible-core 2.19.11 shortens the params stanza to "Error while
# resolving value for 'K'." with Origin at the list's FIRST item line
# (the dash, column = indent+1), and appends a plain "'V' is undefined"
# stanza with Origin at the failing item's value token right after the
# "- " marker (quote included) - byte-for-byte live-captured from real
# 2.19.11 on the s2ansible.zabbix_host task. A flow-style list value on
# the `K:` line itself is NOT that shape and must keep the scalar-param
# three-stanza block with Origin at the param's value position.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (block-style list param)" do
  it "prints the four-stanza block: list first dash, then the failing value token" do
    tempdir = File.tempname("final-block-list").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "zhostrole")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    FileUtils.mkdir_p(File.join(role, "defaults"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - zhostrole
      YAML
    File.write(File.join(role, "defaults", "main.yml"), <<-YAML)
      ---
      zabbix_server_url: https://zabbix.example.com
      zabbix_login_user: user
      zabbix_login_password: pass
      zabbix_host_name: myhost
      zabbix_templates: tmpl
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      ---
      # tasks file for ansible-role-zabbix-host
        - name: Create a new host or update an existing host's info
          local_action:
            module: zabbix_host
            server_url: "{{ zabbix_server_url }}"
            login_user: "{{ zabbix_login_user }}"
            login_password: "{{ zabbix_login_password }}"
            host_name: "{{ zabbix_host_name }}"
            host_groups:
              - "{{ zabbix_host_groups }}"
            link_templates:
              - "{{ zabbix_templates }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    expected = "<<< caused by >>>\n\n" +
               "Error while resolving value for 'host_groups'.\nOrigin: #{tasks_file}:11:9\n\n" \
               " 9       host_name: \"{{ zabbix_host_name }}\"\n" \
               "10       host_groups:\n" \
               "11         - \"{{ zabbix_host_groups }}\"\n" \
               "           ^ column 9\n\n" \
               "<<< caused by >>>\n\n" \
               "'zabbix_host_groups' is undefined\nOrigin: #{tasks_file}:11:11\n\n" \
               " 9       host_name: \"{{ zabbix_host_name }}\"\n" \
               "10       host_groups:\n" \
               "11         - \"{{ zabbix_host_groups }}\"\n" \
               "             ^ column 11\n"
    text.must_include(expected)
    # the fatal line still carries the full single-sentence message
    status.exit_code.must_equal(2)
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Finalization of task args for 'community.zabbix.zabbix_host' failed: Error while resolving value for 'host_groups': 'zabbix_host_groups' is undefined"}))
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
