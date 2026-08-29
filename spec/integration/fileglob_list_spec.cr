require "../spec_helper"
require "file_utils"

# Runs the compiled binary against a real playbook (not --check mode,
# real localhost connection) since this bug is specifically about
# TaskExecutor#resolve_fileglob, a private method not reachable from a
# unit spec without constructing a whole TaskExecutor.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "with_fileglob: templating a list variable" do
  it "treats each list element as its own glob pattern, not the JSON array text as one pattern" do
    # Real bug found benchmarking cloudalchemy.prometheus's own "copy
    # custom alerting rule files" task: `with_fileglob: "{{
    # prometheus_alert_rules_files }}"`, a templated variable whose
    # value is a LIST of patterns (`[prometheus/rules/*.rules]`) - real
    # Ansible's own idiom for this. #resolve_fileglob's plain string
    # substitution had no notion of the underlying value being a real
    # array, so it rendered the whole thing as the JSON-array TEXT
    # (`["prometheus/rules/*.rules"]`, literal brackets/quotes) and
    # handed that straight to Dir.glob as one pattern - its own bracket
    # syntax means "character class", so this always raised
    # Regex::Error ("unterminated character set") instead of matching
    # real files.
    dir = File.tempname("fileglob-list-spec")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "a.rules"), "a")
    File.write(File.join(dir, "b.rules"), "b")

    playbook = File.tempname("fileglob-list-spec-playbook", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        vars:
          my_patterns:
            - #{dir}/*.rules
        tasks:
          - name: glob
            ansible.builtin.debug:
              msg: "{{ item }}"
            with_fileglob: "{{ my_patterns }}"
            register: glob_result
          - name: assert count
            ansible.builtin.assert:
              that:
                - glob_result.results | length == 2
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should_not contain("unterminated character set")
  ensure
    FileUtils.rm_rf(dir) if dir
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
