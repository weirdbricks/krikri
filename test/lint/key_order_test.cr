require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe KeyOrderRule do
    private def rule
      KeyOrderRule.new
    end

    it "flags play keys out of order" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          name: Play
          tasks: []
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("key-order[play]")
      v.first.line.must_equal(2)
      v.first.column.must_equal(3)
      v.first.message.must_equal("You can improve the play key order to: name, hosts, tasks")
    end

    it "flags task keys out of order" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: A
              block:
                - name: B
                  command: ls
              when: x
        YAML
      v.map(&.rule_id).must_equal(["key-order[task]"])
      v.first.line.must_equal(5)
      v.first.column.must_equal(0)
      v.first.message.must_equal("You can improve the task key order to: name, when, block")
    end

    it "accepts canonical order" do
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      command: ls\n      when: x\n", FileType::PLAYBOOK)
      v.must_be_empty
    end

    it "puts block/rescue/always last" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: A
              block:
                - name: B
                  command: ls
              always:
                - name: C
                  debug: msg=x
        YAML
      v.must_be_empty
    end

    it "treats module keys as middle rank" do
      # name, then module (debug), then when - canonical
      v = lint_yaml(rule, "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      ansible.builtin.debug:\n        msg: x\n      when: y\n", FileType::PLAYBOOK)
      v.must_be_empty
    end
  end
end
