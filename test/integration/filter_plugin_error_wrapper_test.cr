require "../minitest_helper"
require "file_utils"

# ansible-core names the filter plugin in the failure it reports for an
# exception raised inside a filter's own body:
#
#   Finalization of task args for 'ansible.builtin.file' failed: Error
#   while resolving value for 'path': The filter plugin
#   'ansible.builtin.password_hash' failed: <cause>
#
# (live-captured vs ansible-core 2.21.6; 2.21 words a `when:` failure
# "Task failed: A 'when' expression failed: The filter plugin ..."). A
# bare ArgumentError from a filter used to escape the dispatch entirely:
# the task-param path reported the cause with no plugin name, and the
# `when:`/`failed_when:`/assert paths had no rescue at all, so the whole
# run died with an unhandled exception.
private PROJECT_ROOT_FILTER_WRAPPER = File.expand_path("../..", __DIR__)
private BINARY_FILTER_WRAPPER       = File.join(PROJECT_ROOT_FILTER_WRAPPER, "bin", "krikri-playbook")
private INVENTORY_FILTER_WRAPPER    = File.join(PROJECT_ROOT_FILTER_WRAPPER, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "filter plugin failure wrapper" do
  # password_hash keeps ansible-core's own cause text verbatim, so the whole
  # message can be asserted byte for byte.
  FILTER_HASH_CAUSE = "nosuchalgo is not in the list of supported passlib algorithms: md5, blowfish, sha256, sha512"

  it "wraps a task-param filter failure with the plugin name and the finalization chain" do
    tempdir = File.tempname("filter-plugin-wrapper-param").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Hash with an unknown algorithm
            file:
              path: "/tmp/{{ 'x' | password_hash('nosuchalgo') }}"
              state: touch
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY_FILTER_WRAPPER, ["-i", INVENTORY_FILTER_WRAPPER, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.file' failed: Error while resolving value for 'path': The filter plugin 'ansible.builtin.password_hash' failed: #{FILTER_HASH_CAUSE}")
    text.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.file' failed: Error while resolving value for 'path': The filter plugin 'ansible.builtin.password_hash' failed: #{FILTER_HASH_CAUSE}\"}")
    text.wont_include("Unhandled exception")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "fails a when: on a raising filter instead of crashing the run" do
    tempdir = File.tempname("filter-plugin-wrapper-when").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Cond on a raising filter
            debug:
              msg: hello
            when: "'x' | password_hash('nosuchalgo') == 'y'"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY_FILTER_WRAPPER, ["-i", INVENTORY_FILTER_WRAPPER, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("[ERROR]: Task failed: A 'when' expression failed: The filter plugin 'ansible.builtin.password_hash' failed: #{FILTER_HASH_CAUSE}")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: A 'when' expression failed: The filter plugin 'ansible.builtin.password_hash' failed: #{FILTER_HASH_CAUSE}\"}")
    text.wont_include("Unhandled exception")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end

  it "fails an assert that: on a raising filter instead of crashing the run" do
    tempdir = File.tempname("filter-plugin-wrapper-assert").tap { |dir| Dir.mkdir(dir) }
    playbook = File.join(tempdir, "site.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - assert:
              that: "'x' | password_hash('nosuchalgo') == 'y'"
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY_FILTER_WRAPPER, ["-i", INVENTORY_FILTER_WRAPPER, playbook], output: output, error: output)
    text = output.to_s

    status.exit_code.must_equal(2)
    text.must_include("The filter plugin 'ansible.builtin.password_hash' failed: #{FILTER_HASH_CAUSE}")
    text.wont_include("Unhandled exception")
  ensure
    FileUtils.rm_rf(tempdir) if tempdir
  end
end
