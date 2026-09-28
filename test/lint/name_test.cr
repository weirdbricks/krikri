require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe NameRule do
    private def rule
      NameRule.new
    end

    it "flags a task with no name" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - ansible.builtin.apt:
            name: htop
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("name[missing]")
      v.first.line.must_equal(2)
    end

    it "flags a lowercase name" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: install htop
          ansible.builtin.apt:
            name: htop
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("name[casing]")
    end

    it "allows a proper name" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install htop
          ansible.builtin.apt:
            name: htop
        YAML
      v.must_be_empty
    end

    it "allows a jinja template at the end of the name" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install {{ package }}
          ansible.builtin.apt:
            name: "{{ package }}"
        YAML
      v.must_be_empty
    end

    it "flags a jinja template in the middle of the name" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install {{ package }} now
          ansible.builtin.apt:
            name: "{{ package }}"
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("name[template]")
    end

    it "can flag both casing and template on the same task" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: install {{ package }} now
          ansible.builtin.apt:
            name: "{{ package }}"
        YAML
      v.map(&.rule_id).sort!.must_equal(["name[casing]", "name[template]"])
    end

    it "does not flag non-alpha leading characters" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: (Debug) show vars
          ansible.builtin.debug:
            msg: hi
        YAML
      v.must_be_empty
    end

    it "checks tasks inside blocks" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: Block parent
              block:
                - ansible.builtin.debug:
                    msg: unnamed inside block
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("name[missing]")
    end
  end
end
