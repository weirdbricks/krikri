require "../minitest_helper"
require "file_utils"

# A block-style MAPPING param (docker_container `env:`) chains two MORE
# error levels than a scalar param when one of its nested values bottoms
# out at an undefined var (issue #265): ansible-core 2.19.11 shortens the
# params stanza to "Error while resolving value for 'K'." with Origin at
# the mapping's FIRST key line, and appends a plain "'V' is undefined"
# stanza with Origin at that value token's first character (quote
# included) - byte-for-byte live-captured from real 2.19.11 on the
# opichon.mysql-backup task. A flow-style mapping value on the `K:` line
# itself is NOT that shape and must keep the scalar-param three-stanza
# block with Origin at the param's value position.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (block-style mapping param)" do
  it "prints the four-stanza block: mapping first key, then the failing value token" do
    tempdir = File.tempname("final-block-mapping").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "mysqlbuie")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        vars:
          mysql_backup_multifiles: all
          mysql_backup_databases: mydb
          mysql_backup_dump_options: --quick
          mysql_backup_host: localhost
        roles:
          - mysqlbuie
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      ---
      - name: Backup mysql databases
        docker_container:
          env:
            MULTI_FILES: "{{ mysql_backup_multifiles }}"
            MYSQLDUMP_DATABASE: "{{ mysql_backup_databases }}"
            MYSQLDUMP_OPTIONS: "{{ mysql_backup_dump_options }}"
            MYSQL_HOST: "{{ mysql_backup_host }}"
            MYSQL_PASSWORD: "{{ mysql_backup_password }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    expected = "[ERROR]: Task failed: Finalization of task args for 'community.docker.docker_container' failed: Error while resolving value for 'env': 'mysql_backup_password' is undefined\n\n" +
               "Task failed.\nOrigin: #{tasks_file}:2:3\n\n" \
               "1 ---\n" \
               "2 - name: Backup mysql databases\n" \
               "    ^ column 3\n\n" \
               "<<< caused by >>>\n\n" \
               "Finalization of task args for 'community.docker.docker_container' failed.\nOrigin: #{tasks_file}:3:3\n\n" \
               "1 ---\n" \
               "2 - name: Backup mysql databases\n" \
               "3   docker_container:\n" \
               "    ^ column 3\n\n" \
               "<<< caused by >>>\n\n" \
               "Error while resolving value for 'env'.\nOrigin: #{tasks_file}:5:7\n\n" \
               "3   docker_container:\n" \
               "4     env:\n" \
               "5       MULTI_FILES: \"{{ mysql_backup_multifiles }}\"\n" \
               "        ^ column 7\n\n" \
               "<<< caused by >>>\n\n" \
               "'mysql_backup_password' is undefined\nOrigin: #{tasks_file}:9:23\n\n" \
               "7       MYSQLDUMP_OPTIONS: \"{{ mysql_backup_dump_options }}\"\n" \
               "8       MYSQL_HOST: \"{{ mysql_backup_host }}\"\n" \
               "9       MYSQL_PASSWORD: \"{{ mysql_backup_password }}\"\n" \
               "                        ^ column 23\n\n"
    text.must_include(expected)
    # the first level and the fatal line still carry the full message
    status.exit_code.must_equal(2)
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Finalization of task args for 'community.docker.docker_container' failed: Error while resolving value for 'env': 'mysql_backup_password' is undefined"}))
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "keeps the three-stanza block and the value-position Origin for a flow-style mapping param" do
    playbook = File.tempname("final-block-mapping-flow", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          flow_x1: x1
        tasks:
          - name: Inline env
            ansible.builtin.set_fact:
              env: {"MULTI_FILES": "{{ flow_x1 }}", "MYSQL_PASSWORD": "{{ flow_undefined }}"}
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("<<< caused by >>>\n\nError while resolving value for 'env': 'flow_undefined' is undefined\nOrigin: #{playbook}:8:14\n\n" \
                      "6     - name: Inline env\n" \
                      "7       ansible.builtin.set_fact:\n" \
                      "8         env: {\"MULTI_FILES\": \"{{ flow_x1 }}\", \"MYSQL_PASSWORD\": \"{{ flow_undefined }}\"}\n" \
                      "               ^ column 14\n")
    # flow values are not the block-mapping shape: no fourth stanza
    text.wont_include("<<< caused by >>>\n\n'flow_undefined' is undefined\nOrigin: ")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
