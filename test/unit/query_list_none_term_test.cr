require "../minitest_helper"
require "../../src/krikri/variable_substitutor"
require "../../src/krikri/krikri_jinja_filters"

# `query('list', none_var)` must yield [None], not [""] - live-verified
# against ansible-core: the engine passes a native call's None argument
# through unstringified, while the hand-rolled lookup term used to render
# None to text ("" - Ansible's own None stringification) and re-type it,
# turning the item into an empty string. andrewrothstein.docker-cleanup
# (issue #414) loops `query('list', docker_cleanup_label_filters)` over
# its None default with `when: item is not none`: the "" item made the
# guard true, the body ran, and `"".name` failed the play (exit 2) where
# ansible skipped (exit 0).
describe "Krikri::VariableSubstitutor::ExpressionEvaluator list lookup None terms (query_list_none_term_test.cr)" do
  it "keeps a None bare-variable term as null in query('list', ...)" do
    v = Hash(String, JSON::Any).new
    v["label_filters"] = JSON::Any.new(nil)
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    result = JSON.parse(evaluator.evaluate("query('list', label_filters)")).as_a
    result.size.must_equal(1)
    result[0].raw.nil?.must_equal(true)
  end

  it "keeps a genuine empty-string variable term an empty string" do
    v = Hash(String, JSON::Any).new
    v["label_filters"] = JSON::Any.new("")
    evaluator = Krikri::VariableSubstitutor::ExpressionEvaluator.new(v)

    evaluator.evaluate("query('list', label_filters)").must_equal(%([""]))
  end
end

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "loop over query('list', a None default) skips like ansible" do
  it "skips with (item=None) instead of failing on the string item's attribute" do
    playbook = File.tempname("query-list-none", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          label_filters:
          flags: []
        tasks:
          - name: compute prune command label filters
            when: item is not none
            ansible.builtin.set_fact:
              flags: '{{ flags + [item.name] }}'
            loop: '{{ query("list", label_filters) }}'
          - name: sentinel
            ansible.builtin.debug:
              msg: SENTINEL
      YAML
    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    output = output.to_s
    File.delete(playbook) if File.exists?(playbook)

    status.exit_code.must_equal(0)
    output.must_include("(item=None)")
    output.must_include("skipped=1")
    output.wont_include("has no attribute 'name'")
    output.must_include("SENTINEL")
  end
end
