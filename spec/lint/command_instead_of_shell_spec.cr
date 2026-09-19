require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  # Shared helper for task-oriented rule specs: write YAML, load it,
  # run one rule, return violations.
  def self.lint_yaml(rule : Rule, yaml : String, file_type : FileType = FileType::PLAYBOOK) : Array(Violation)
    path = File.tempname("lintrule", ".yml")
    File.write(path, yaml)
    file = PositionedFile.new(path, file_type, YAML::Nodes.parse(yaml).nodes.first?, nil)
    violations = [] of Violation
    rule.check(file, violations)
    violations
  ensure
    File.delete(path) if path
  end

  describe CommandInsteadOfShellRule do
    rule = CommandInsteadOfShellRule.new

    it "flags a plain shell command with no shell features" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Bad shell
          ansible.builtin.shell: echo hello
        YAML
      v.size.should eq(1)
      v.first.rule_id.should eq("command-instead-of-shell")
      v.first.line.should eq(2)
    end

    it "allows shell when piping is used" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Piped shell
          shell: cat /etc/passwd | grep root
        YAML
      v.should be_empty
    end

    it "allows shell with executable" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Custom shell
          shell: echo hi
          args:
            executable: /bin/zsh
        YAML
      v.should be_empty
    end

    it "does not fire on command module" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Command module
          ansible.builtin.command: echo hello
        YAML
      v.should be_empty
    end

    it "does not mistake jinja filters for pipes" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Jinja shell
          shell: echo {{ "x" | upper }}
        YAML
      v.size.should eq(1)
    end

    it "checks tasks inside blocks" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          tasks:
            - name: Block parent
              block:
                - name: Inner shell
                  shell: echo plain
        YAML
      v.size.should eq(1)
      v.first.line.should eq(6)
    end
  end
end
