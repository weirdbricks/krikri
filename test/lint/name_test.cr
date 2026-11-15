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

    # ansible-lint normalizes a block to a task with the dummy action
    # "block/always/rescue", so the block parent itself must be named.
    it "flags an unnamed block parent" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - block:
                - name: Named child
                  ansible.builtin.debug:
                    msg: hi
              when: true
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("name[missing]")
      v.first.line.must_equal(5)
      v.first.column.must_equal(0)
    end

    it "flags a lowercase block name at the name key" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: lowercase block
              block:
                - name: Named child
                  ansible.builtin.debug:
                    msg: hi
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("name[casing]")
      v.first.line.must_equal(5)
      v.first.column.must_equal(13)
    end

    it "flags every unnamed block parent, nested ones included" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - block:
            - block:
                - name: Named child
                  ansible.builtin.debug:
                    msg: hi
        YAML
      v.map(&.rule_id).must_equal(["name[missing]", "name[missing]"])
      v.map(&.line).must_equal([2, 3])
    end

    it "checks block parents in a tasks file" do
      v = lint_yaml(rule, <<-YAML, FileType::TASKS)
        ---
        - name: rescue block
          block:
            - name: Named child
              ansible.builtin.debug:
                msg: hi
          rescue:
            - name: Named rescue
              ansible.builtin.debug:
                msg: rescue
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("name[casing]")
      v.first.line.must_equal(2)
    end
  end
end
