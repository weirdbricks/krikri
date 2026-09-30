require "../minitest_helper"
require "file_utils"

# groupby's result shape and its variable-storage warning. Real Jinja2
# 3.x do_groupby yields _GroupTuple namedtuples: json.dumps (debug:) shows
# each group as a [grouper, list] ARRAY, item.0/item.1 indexing works, and
# .grouper/.list attribute access works (namedtuple fields). Real
# ansible-core 2.19.11 also warns "Type 'GroupTuple' is unsupported in
# variable storage, converting to 'list'." whenever the pairs land in
# storage (task-arg finalization, set_fact) - but NOT when a | map(...)
# converted them all away. Byte-compared via scripts/output_parity.sh.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "groupby pair shape and GroupTuple storage warning" do
  it "renders [grouper, list] pairs, keeps .grouper access, warns on storage only" do
    playbook = File.tempname("groupby-pairs", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          items:
            - {color: "red", n: 1}
            - {color: "blue", n: 2}
            - {color: "red", n: 3}
        tasks:
          - debug: msg="{{ items | groupby('color') | map('first') | list }}"
          - debug: msg="{{ items | groupby('color') }}"
            ignore_errors: true
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    text = output.to_s

    # map('first') extracts the groupers (converted pairs: no warning)
    text.must_include("msg\": [\n        \"blue\",\n        \"red\"\n    ]")
    # the bare groupby result renders as an array of [grouper, list] pairs
    text.must_include("[\n        [\n            \"blue\",")
    # and warns exactly once, at the second debug's msg param
    text.scan("Type 'GroupTuple' is unsupported in variable storage").size.must_equal(1)
    text.must_include("Origin: #{playbook}:10:14")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
