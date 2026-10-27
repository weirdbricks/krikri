require "../minitest_helper"
require "file_utils"

# An until:/retries: task whose args fail to FINALIZE (issue #587,
# oatakan.windows_ec2_ena_driver's win_get_url) is ansible's exception
# shape, not a retryable failure: ansible raises the finalization error
# before the module ever runs, outside the attempt loop - no
# "FAILED - RETRYING" lines, no attempts key in the fatal - and prints
# the full [ERROR] chain block, whose fourth stanza carries the bare
# dict-attribute miss with Origin at the ROLE DEFAULT whose own template
# value bottoms out (`temp: "{{ cfg.TEMP }}"` under a plain `cfg: {}`).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization failure on an until/retries task" do
  it "escapes the retry loop without attempts and prints the four-stanza block ending at the role default" do
    tempdir = File.tempname("final-until-retries").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "retryrole")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    FileUtils.mkdir_p(File.join(role, "defaults"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      ---
      - hosts: localhost
        gather_facts: false
        vars:
          cfg: {}
          dl_url: https://example.com/driver.zip
        roles:
          - retryrole
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      ---

      - name: download zip file
        get_url:
          url: '{{ dl_url }}'
          dest: '{{ temp }}\\file.zip'
        register: download_driver
        until: download_driver is success
        delay: 3
        retries: 5
        ignore_errors: yes
      YAML
    defaults_file = File.join(role, "defaults", "main.yml")
    File.write(defaults_file, <<-YAML)
      ---
      temp: "{{ cfg.TEMP }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # ansible raises the finalization error before the module runs, so the
    # until loop never sees it: the failure is neither retried nor counted.
    text.wont_include("FAILED - RETRYING")
    text.wont_include("\"attempts\":")
    text.must_include("...ignoring")

    expected = "[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.get_url' failed: Error while resolving value for 'dest': object of type 'dict' has no attribute 'TEMP'\n\n" +
               "Task failed.\nOrigin: #{tasks_file}:3:3\n\n" \
               "1 ---\n" \
               "2\n" \
               "3 - name: download zip file\n" \
               "    ^ column 3\n\n" \
               "<<< caused by >>>\n\n" \
               "Finalization of task args for 'ansible.builtin.get_url' failed.\nOrigin: #{tasks_file}:4:3\n\n" \
               "2\n" \
               "3 - name: download zip file\n" \
               "4   get_url:\n" \
               "    ^ column 3\n\n" \
               "<<< caused by >>>\n\n" \
               "Error while resolving value for 'dest'.\nOrigin: #{tasks_file}:6:11\n\n" \
               "4   get_url:\n" \
               "5     url: '{{ dl_url }}'\n" \
               "6     dest: '{{ temp }}\\file.zip'\n" \
               "            ^ column 11\n\n" \
               "<<< caused by >>>\n\n" \
               "object of type 'dict' has no attribute 'TEMP'\nOrigin: #{defaults_file}:2:7\n\n" \
               "1 ---\n" \
               "2 temp: \"{{ cfg.TEMP }}\"\n" \
               "        ^ column 7\n\n"
    text.must_include(expected)
    # the fatal line carries no attempts key (the retry loop never ran)
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Finalization of task args for 'ansible.builtin.get_url' failed: Error while resolving value for 'dest': object of type 'dict' has no attribute 'TEMP'"}))
    status.exit_code.must_equal(0)
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
