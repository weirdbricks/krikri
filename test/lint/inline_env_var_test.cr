require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe InlineEnvVarRule do
    private def rule
      InlineEnvVarRule.new
    end

    it "flags a command with an inline environment variable" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Var before command
          ansible.builtin.command: FOO=bar /usr/bin/printenv FOO
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("inline-env-var")
      v.first.line.must_equal(2)
      v.first.column.must_equal(0)
      v.first.severity.must_equal(Severity::VERY_HIGH)
      v.first.message.must_equal(
        "Command module does not accept setting environment variables inline.")
    end

    it "does not flag the shell module, which accepts inline env" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Shell var before command
          ansible.builtin.shell: FOO=bar /usr/bin/printenv FOO
        YAML
      v.must_be_empty
    end

    it "does not flag the environment keyword form" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Env keyword form
          ansible.builtin.command: /usr/bin/printenv FOO
          environment:
            FOO: bar
        YAML
      v.must_be_empty
    end

    it "flags the cmd mapping form" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Mapping cmd form
          ansible.builtin.command:
            cmd: A=1 B=2 /usr/bin/printenv A
        YAML
      v.size.must_equal(1)
    end

    it "flags a lone variable assignment" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Var only
          ansible.builtin.command: FOO=bar
        YAML
      v.size.must_equal(1)
    end

    it "does not flag an assignment after the command word" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Var after command
          ansible.builtin.command: /usr/bin/printenv FOO=bar
        YAML
      v.must_be_empty
    end

    it "does not flag the argv form" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Argv form
          ansible.builtin.command:
            argv:
              - /usr/bin/printenv
              - FOO
        YAML
      v.must_be_empty
    end

    it "still flags when args carry an accepted parameter" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Args chdir form
          ansible.builtin.command: FOO=bar /usr/bin/printenv FOO
          args:
            chdir: /tmp
        YAML
      v.size.must_equal(1)
    end

    # Upstream also fires on any module argument outside command's
    # accepted parameter set, even without an inline assignment.
    it "flags an unexpected module argument" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Unknown module arg
          ansible.builtin.command: /bin/true
          args:
            foo: bar
        YAML
      v.size.must_equal(1)
    end

    it "does not flag accepted arguments alone" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Accepted args
          ansible.builtin.command: /bin/cat
          args:
            stdin: hello
            stdin_add_newline: false
            strip_empty_ends: true
            chdir: /tmp
            creates: /tmp/thing
            removes: /tmp/other
        YAML
      v.must_be_empty
    end

    it "does not flag the legacy fqcn, which upstream leaves unnormalized" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Legacy fqcn
          ansible.legacy.command: FOO=bar /usr/bin/printenv FOO
        YAML
      v.must_be_empty
    end

    it "does not flag other modules" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install
          ansible.builtin.apt:
            name: htop
            state: present
        YAML
      v.must_be_empty
    end
  end
end
