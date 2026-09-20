require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe NoJinjaWhenRule do
    rule = NoJinjaWhenRule.new

    it "flags when with redundant jinja braces" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          tasks:
            - name: Check
              command: ls
              when: "{{ x }}"
        YAML
      v.size.should eq(1)
      v.first.rule_id.should eq("no-jinja-when")
      v.first.line.should eq(4)
    end

    # Upstream's matchtask only triggers on `when`; changed_when/
    # failed_when are transform-only there.
    it "does not flag changed_when (installed-version parity)" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: ls\n      changed_when: \"{{ x }}\"\n", FileType::PLAYBOOK)
      v.should be_empty
    end

    it "allows plain expressions" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          tasks:
            - name: Check
              command: ls
              when: x is defined
        YAML
      v.should be_empty
    end
  end

  describe JinjaRule do
    rule = JinjaRule.new

    it "flags missing inner padding" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: echo {{x}}\n", FileType::PLAYBOOK)
      v.size.should eq(1)
      v.first.rule_id.should eq("jinja[spacing]")
      v.first.column.should eq(16)
      v.first.message.should contain("echo {{x}} -> echo {{ x }}")
    end

    it "allows well-spaced templates" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: echo {{ x }}\n", FileType::PLAYBOOK)
      v.should be_empty
    end

    it "flags genuinely broken jinja syntax" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: echo {{ x + }}\n", FileType::PLAYBOOK)
      v.map(&.rule_id).should eq(["jinja[invalid]"])
    end

    it "ignores undefined-variable render errors" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: echo {{ some_undefined_var }}\n", FileType::PLAYBOOK)
      v.should be_empty
    end
  end
end
