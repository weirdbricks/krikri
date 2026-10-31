require "../minitest_helper"
require "file_utils"

# A task arg consumed through an include_vars: FILE whose value is a
# container with several equally-failing leaves (issue #415,
# andrewrothstein.dotnet: `name: '{{ dotnet_deps }}'` over a vars/Ubuntu.yml
# list whose libcurl/libssl/libicu items all miss the same release key) is
# ansible's four-stanza finalization chain: the innermost stanza carries the
# bare dict-attribute miss with Origin at the FIRST failing leaf in the
# included file - real templates the leaves in document order and stops at
# the first failure - and that origin is only reachable because included
# vars carry per-value origins like file-defined layers do. Verified
# byte-for-byte against real 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization failure through an include_vars container" do
  it "ends the chain at the first failing leaf of the included vars file" do
    tempdir = File.tempname("include-vars-chain").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "incrole")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    FileUtils.mkdir_p(File.join(role, "vars"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        vars:
          wanted: two
        roles:
          - incrole
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      ---
      - include_vars: extra.yml
      - name: consume included list
        debug:
          msg: '{{ dep_list }}'
      YAML
    vars_file = File.join(role, "vars", "extra.yml")
    File.write(vars_file, <<-YAML)
      ---
      mapping:
        one: '1'
      dep_list:
        - alpha
        - beta{{ mapping[wanted] }}
        - gamma{{ mapping[wanted] }}
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    expected = "[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': object of type 'dict' has no attribute 'two'\n\n" +
               "Task failed.\nOrigin: #{tasks_file}:3:3\n\n" \
               "1 ---\n" \
               "2 - include_vars: extra.yml\n" \
               "3 - name: consume included list\n" \
               "    ^ column 3\n\n" \
               "<<< caused by >>>\n\n" \
               "Finalization of task args for 'ansible.builtin.debug' failed.\nOrigin: #{tasks_file}:4:3\n\n" \
               "2 - include_vars: extra.yml\n" \
               "3 - name: consume included list\n" \
               "4   debug:\n" \
               "    ^ column 3\n\n" \
               "<<< caused by >>>\n\n" \
               "Error while resolving value for 'msg'.\nOrigin: #{tasks_file}:5:10\n\n" \
               "3 - name: consume included list\n" \
               "4   debug:\n" \
               "5     msg: '{{ dep_list }}'\n" \
               "           ^ column 10\n\n" \
               "<<< caused by >>>\n\n" \
               "object of type 'dict' has no attribute 'two'\nOrigin: #{vars_file}:6:5\n\n" \
               "4 dep_list:\n" \
               "5   - alpha\n" \
               "6   - beta{{ mapping[wanted] }}\n" \
               "      ^ column 5\n\n"
    text.must_include(expected)
    text.must_include(%(fatal: [localhost]: FAILED! => {"msg": "Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': object of type 'dict' has no attribute 'two'"}))
    status.exit_code.must_equal(2)
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
