require "../minitest_helper"
require "file_utils"
require "../../src/krikri/krikri_jinja_filters"

# The `version`/`version_compare` test walks distutils LooseVersion's
# component list: digit runs are ints, [a-z]+ runs are strings, dots are
# components, prefix-exhaustion is less, and the first int-vs-str
# mismatch is a task-failing TypeError. Real ansible-core 2.19.11 wraps a
# test plugin failure in the finalization chain as "The test plugin
# 'ansible.builtin.<name>' failed: <cause>", with the cause as its own
# innermost "<<< caused by >>>" stanza (no Origin). Byte-compared via
# scripts/output_parity.sh.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "version test LooseVersion semantics" do
  it "compares alpha components, prefixes, and fails on mixed types" do
    Krikri::KrikriJinjaFilters.compare_versions("1.2.3", "1.2.0") > 0 || raise "expected > 0"
    Krikri::KrikriJinjaFilters.compare_versions("1.2.3", "1.2.3a") < 0 || raise "expected < 0"
    Krikri::KrikriJinjaFilters.compare_versions("8.9p1", "8.9") > 0 || raise "expected > 0"
    Krikri::KrikriJinjaFilters.compare_versions("1.2", "1.10") < 0 || raise "expected < 0"
    error = nil
    begin
      Krikri::KrikriJinjaFilters.compare_versions("hello world", "0.9")
    rescue e : KrikriJinja::TemplateError
      error = e
    end
    error.nil?.must_equal(false)
    assert (error.not_nil!.message || "").includes?("Version comparison failed: '<' not supported between instances of 'str' and 'int'")
  end
end

describe "test plugin failure finalization chain" do
  it "wraps a failing version test in the full three-stanza chain" do
    playbook = File.tempname("test-plugin-fail", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          s: "hello world"
        tasks:
          - debug: msg="{{ s is version_compare('0.9', '>=') }}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    text.must_include("[ERROR]: Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': The test plugin 'ansible.builtin.version_compare' failed: Version comparison failed: '<' not supported between instances of 'str' and 'int'")
    text.must_include("Error while resolving value for 'msg': The test plugin 'ansible.builtin.version_compare' failed.\nOrigin: #{playbook}:6:14")
    text.must_include("<<< caused by >>>\n\nVersion comparison failed: '<' not supported between instances of 'str' and 'int'")
    text.must_include("fatal: [localhost]: FAILED! => {\"msg\": \"Task failed: Finalization of task args for 'ansible.builtin.debug' failed: Error while resolving value for 'msg': The test plugin 'ansible.builtin.version_compare' failed: Version comparison failed: '<' not supported between instances of 'str' and 'int'\"}")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
