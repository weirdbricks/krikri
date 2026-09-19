require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe NameRule do
    rule = NameRule.new

    it "flags a task with no name" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - ansible.builtin.apt:
            name: htop
        YAML
      v.size.should eq(1)
      v.first.rule_id.should eq("name[missing]")
      v.first.line.should eq(2)
    end

    it "flags a lowercase name" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: install htop
          ansible.builtin.apt:
            name: htop
        YAML
      v.size.should eq(1)
      v.first.rule_id.should eq("name[casing]")
    end

    it "allows a proper name" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install htop
          ansible.builtin.apt:
            name: htop
        YAML
      v.should be_empty
    end

    it "allows a jinja template at the end of the name" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install {{ package }}
          ansible.builtin.apt:
            name: "{{ package }}"
        YAML
      v.should be_empty
    end

    it "flags a jinja template in the middle of the name" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install {{ package }} now
          ansible.builtin.apt:
            name: "{{ package }}"
        YAML
      v.size.should eq(1)
      v.first.rule_id.should eq("name[template]")
    end

    it "can flag both casing and template on the same task" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: install {{ package }} now
          ansible.builtin.apt:
            name: "{{ package }}"
        YAML
      v.map(&.rule_id).sort.should eq(["name[casing]", "name[template]"])
    end

    it "does not flag non-alpha leading characters" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: (Debug) show vars
          ansible.builtin.debug:
            msg: hi
        YAML
      v.should be_empty
    end

    it "checks tasks inside blocks" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - hosts: all
          tasks:
            - name: Block parent
              block:
                - ansible.builtin.debug:
                    msg: unnamed inside block
        YAML
      v.size.should eq(1)
      v.first.rule_id.should eq("name[missing]")
    end
  end
end
