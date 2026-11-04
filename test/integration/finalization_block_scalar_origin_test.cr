require "../minitest_helper"
require "file_utils"

# A block-style SCALAR param (the value's quoted text starts on the line
# after `key:`) used to point the finalization [ERROR] chain's innermost
# Origin at the key's own colon (key line, column just past it); ansible's
# observed behaviour (issue #798, lean_delivery.solr_slave round
# round29895853, live-captured vs 2.19.11) points it at the VALUE NODE's
# own position - the first non-space character of the next deeper content
# line, blank and comment-only lines skipped. A `|`/`>` block indicator
# sits inline after the colon and keeps the value-token-on-the-key-line
# position the inline formula already yields (live-captured: `f: >-` ->
# the `>` column).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "task-arg finalization error block (next-line block scalar)" do
  it "points the innermost Origin at the value token on the line after the key" do
    tempdir = File.tempname("final-block-scalar").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "scalarblock")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          solr_ssl_enabled: false
        roles:
          - scalarblock
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      - name: Generate Solr Master URL using inventory
        set_fact:
          solr_master_generated_url:
            '{{ groups[(master_group | default("solr-master"))]|first }}'
        when: solr_master_defined_host is not defined
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'solr_master_generated_url': object of type 'dict' has no attribute 'solr-master'")
    text.must_include("\nTask failed.\nOrigin: #{tasks_file}:1:3")
    text.must_include("\nFinalization of task args for 'ansible.builtin.set_fact' failed.\nOrigin: #{tasks_file}:2:3")
    # the value token's quote on the line AFTER the `solr_master_generated_url:`
    # key (line 4, column 7), with the key's line as context above it
    text.must_include("Error while resolving value for 'solr_master_generated_url': object of type 'dict' has no attribute 'solr-master'\nOrigin: #{tasks_file}:4:7\n")
    text.must_include("2   set_fact:\n3     solr_master_generated_url:\n4       '{{ groups[(master_group | default(\"solr-master\"))]|first }}'\n        ^ column 7\n")
    text.must_include(%(fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'solr_master_generated_url': object of type 'dict' has no attribute 'solr-master'"}))
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "skips blank and comment lines between the key and the block scalar" do
    tempdir = File.tempname("final-block-scalar-cmt").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "scalarblockcmt")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - scalarblockcmt
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      - name: Block scalar with comment after the colon
        set_fact:
          c:  # a comment
            "{{ undefined_c_var }}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # live-captured vs 2.19.11: the quote on the value's own line (4:7),
    # not the key line's column after the comment
    text.must_include("Error while resolving value for 'c': 'undefined_c_var' is undefined\nOrigin: #{tasks_file}:4:7\n")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "keeps the indicator position on the key line for an explicit block scalar" do
    tempdir = File.tempname("final-block-scalar-ind").tap { |dir| Dir.mkdir(dir) }
    role = File.join(tempdir, "roles", "scalarblockind")
    FileUtils.mkdir_p(File.join(role, "tasks"))
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        roles:
          - scalarblockind
      YAML
    tasks_file = File.join(role, "tasks", "main.yml")
    File.write(tasks_file, <<-YAML)
      - name: Block folded indicator
        set_fact:
          f: >-
            {{ undefined_f_var }}
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # live-captured vs 2.19.11: the `>` of `f: >-` on the key's own line (3:8)
    text.must_include("Error while resolving value for 'f': 'undefined_f_var' is undefined\nOrigin: #{tasks_file}:3:8\n")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
