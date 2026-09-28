require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe CommandInsteadOfModuleRule do
    private def rule
      CommandInsteadOfModuleRule.new
    end

    it "flags git via command" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Clone repo
          ansible.builtin.command: git clone https://example.com/r.git
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("git used in place of git module")
    end

    it "flags wget via shell" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Fetch
          shell: wget -O /tmp/x https://example.com
        YAML
      v.size.must_equal(1)
      v.first.message.must_equal("wget used in place of get_url or uri module")
    end

    it "allows git branch (executable option exception)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Branch info
          ansible.builtin.command: git branch -a
        YAML
      v.must_be_empty
    end

    it "allows git rev-parse" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Rev
          command: git rev-parse HEAD
        YAML
      v.must_be_empty
    end

    it "does not flag unrelated executables" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Echo
          command: echo hello
        YAML
      v.must_be_empty
    end

    it "ignores jinja in command words" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Templated
          command: "{{ tool }} --version"
        YAML
      v.must_be_empty
    end
  end
end
