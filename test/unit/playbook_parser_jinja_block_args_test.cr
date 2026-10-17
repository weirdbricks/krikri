require "../minitest_helper"
require "../../src/krikri/playbook_parser"

# Issue #149: a free-form (non-command) args string containing an unquoted,
# whitespace-separated token that BEGINS with `{%` is one whole Jinja
# template for ansible-core - krikri flags it with the `_jinja_block_args`
# marker so the executor can fail finalization like Ansible's finalizer.
# Quoted `{%` text, glued tokens and raw command modules must NOT flag.
describe "Krikri::PlaybookParser (playbook_parser_jinja_block_args_test.cr)" do
  it "marks the issue repro shape (block token on a later line)" do
    pb = Krikri::PlaybookParser.parse_string(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.pip: >-
              name=supervisor version={{ v }} virtualenv={{ p }} use_mirrors=no
              {% if pip_args %} extra_args={{ pip_args }} {% endif %}
      YAML
    pb.plays[0].tasks[0].params["_jinja_block_args"]?.must_equal(
      "name=supervisor version={{ v }} virtualenv={{ p }} use_mirrors=no {% if pip_args %} extra_args={{ pip_args }} {% endif %}"
    )
  end

  it "does not mark a quoted {% block" do
    pb = Krikri::PlaybookParser.parse_string(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - debug: msg="hi {% if true %}x{% endif %}"
      YAML
    pb.plays[0].tasks[0].params["_jinja_block_args"]?.must_be_nil
  end

  it "does not mark a glued token that merely contains a block" do
    pb = Krikri::PlaybookParser.parse_string(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - debug: msg=x{% if true %}y{% endif %}
      YAML
    pb.plays[0].tasks[0].params["_jinja_block_args"]?.must_be_nil
  end

  it "does not mark a string that starts AND ends with a Jinja delimiter" do
    pb = Krikri::PlaybookParser.parse_string(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - ansible.builtin.debug: "{% if true %}{{ d }}{% endif %}"
      YAML
    pb.plays[0].tasks[0].params["_jinja_block_args"]?.must_be_nil
    pb.plays[0].tasks[0].params["_argsplat_block_marker"]?.must_equal("1")
  end

  it "does not mark raw command modules" do
    pb = Krikri::PlaybookParser.parse_string(<<-YAML)
      - hosts: all
        gather_facts: false
        tasks:
          - command: echo {% if true %}hi{% endif %}
      YAML
    pb.plays[0].tasks[0].params["_jinja_block_args"]?.must_be_nil
    pb.plays[0].tasks[0].params["cmd"].must_equal("echo {% if true %}hi{% endif %}")
  end

  it "extracts top-level block constructs, skipping nested and self-contained tags" do
    constructs = Krikri::PlaybookParser.jinja_block_constructs(
      "pre {% if a %}A{% if b %}B{% endif %}C{% endif %} mid {% set x = 1 %} {% if d %}D{% endif %} post"
    )
    constructs.size.must_equal(2)
    constructs[0].must_equal("{% if a %}A{% if b %}B{% endif %}C{% endif %}")
    constructs[1].must_equal("{% if d %}D{% endif %}")
  end
end
