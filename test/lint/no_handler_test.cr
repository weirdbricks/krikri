require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe NoHandlerRule do
    private def rule
      NoHandlerRule.new
    end

    it "flags a task using when: x.changed" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          tasks:
            - name: Restart service
              command: restart
              when: result.changed
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("no-handler")
      v.first.line.must_equal(4)
      v.first.column.must_equal(13)
    end

    it "flags |changed, [\"changed\"], and is changed forms" do
      ["result | changed", "result[\"changed\"]", "result is changed"].each do |cond|
        v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: X\n      command: restart\n      when: #{cond}\n", FileType::PLAYBOOK)
        v.size.must_equal(1)
      end
    end

    it "ignores compound conditions" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          tasks:
            - name: Restart service
              command: restart
              when: a.changed or b.changed
        YAML
      v.must_be_empty
    end

    it "ignores handlers" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          handlers:
            - name: Restart
              command: restart
              when: result.changed
        YAML
      v.must_be_empty
    end
  end
end
