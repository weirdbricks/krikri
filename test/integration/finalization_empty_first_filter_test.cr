require "../minitest_helper"
require "file_utils"

# lean_delivery.jmeter (issue #548, round29884121): a set_fact whose folded
# scalar arg ends in `| first` over an empty sequence used to fail with a
# bare "Task failed: No first item, sequence was empty." - no "Finalization
# of task args" wrapper, no "Error while resolving value for 'KEY':" link,
# no `<<< caused by >>>` chain. ansible-core 2.19 words the same failure as
# a full task-arg finalization failure (live-captured vs 2.19.11), because
# StopIteration from Jinja's do_first surfaces during arg templating, not
# as a module failure. The same untyped raise also crashed the whole
# process on a `when:`/`loop:` source using the same filter shape.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "empty-sequence first/last filter failure wording (issue #548)" do
  it "fails a set_fact arg through the full finalization chain" do
    tempdir = File.tempname("final-empty-first").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          empty_list: []
        tasks:
          - name: Find last release version
            set_fact:
              jmeter_version: >-
                {{ empty_list | first }}
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'jmeter_version': No first item, sequence was empty.")
    text.must_include("\nFinalization of task args for 'ansible.builtin.set_fact' failed.\nOrigin: #{playbook}:8:7")
    # 8 spaces + `jmeter_version: ` puts the folded-scalar marker at column 25.
    text.must_include("Error while resolving value for 'jmeter_version': No first item, sequence was empty.\nOrigin: #{playbook}:9:25")
    text.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for 'jmeter_version': No first item, sequence was empty.\"}")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "fails a when: that consumes an empty first with the conditional wording" do
    tempdir = File.tempname("final-empty-first-when").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          empty_list: []
        tasks:
          - name: Cond first on empty
            debug:
              msg: hello
            when: "{{ empty_list | first == 'y' }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Error while evaluating conditional: No first item, sequence was empty.")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Error while evaluating conditional: No first item, sequence was empty.\"}")
    text.wont_include("Unhandled exception")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "fails a loop source that consumes an empty first instead of crashing" do
    tempdir = File.tempname("final-empty-first-loop").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          empty_list: []
        tasks:
          - name: loop over empty first
            debug:
              msg: "item {{ item }}"
            loop: "{{ empty_list | first }}"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: No first item, sequence was empty.\"}")
    text.wont_include("Unhandled exception")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
