require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe NoJinjaWhenRule do
    private def rule
      NoJinjaWhenRule.new
    end

    it "flags when with redundant jinja braces" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          tasks:
            - name: Check
              command: ls
              when: "{{ x }}"
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("no-jinja-when")
      v.first.line.must_equal(4)
    end

    # Upstream's matchtask only triggers on `when`; changed_when/
    # failed_when are transform-only there.
    it "does not flag changed_when (installed-version parity)" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: ls\n      changed_when: \"{{ x }}\"\n", FileType::PLAYBOOK)
      v.must_be_empty
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
      v.must_be_empty
    end
  end

  describe JinjaRule do
    private def rule
      JinjaRule.new
    end

    it "flags missing inner padding" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: echo {{x}}\n", FileType::PLAYBOOK)
      v.size.must_equal(1)
      v.first.rule_id.must_equal("jinja[spacing]")
      v.first.column.must_equal(16)
      v.first.message.must_include("echo {{x}} -> echo {{ x }}")
    end

    it "allows well-spaced templates" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: echo {{ x }}\n", FileType::PLAYBOOK)
      v.must_be_empty
    end

    it "flags genuinely broken jinja syntax" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: echo {{ x + }}\n", FileType::PLAYBOOK)
      v.map(&.rule_id).must_equal(["jinja[invalid]"])
    end

    it "ignores undefined-variable render errors" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: echo {{ some_undefined_var }}\n", FileType::PLAYBOOK)
      v.must_be_empty
    end

    # ansible-lint treats {% raw %} text as literal: the `{{x}}` there is
    # what the target command actually receives (e.g. docker's --format),
    # so respacing it would change behavior, not just formatting.
    it "does not flag spacing inside raw blocks" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: echo '{% raw %}{{.Names}}{% endraw %}'\n", FileType::PLAYBOOK)
      v.must_be_empty
    end

    it "fixes spacing outside raw blocks while leaving raw text verbatim" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: echo {{x}} '{% raw %}{{.Names}}{% endraw %}'\n", FileType::PLAYBOOK)
      v.size.must_equal(1)
      v.first.rule_id.must_equal("jinja[spacing]")
      v.first.message.must_include("echo {{x}} '{% raw %}{{.Names}}{% endraw %}' -> echo {{ x }} '{% raw %}{{.Names}}{% endraw %}'")
    end

    it "does not flag spacing inside raw blocks with whitespace-control tags" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: A\n      command: echo '{%- raw -%}{{.Names}}{%- endraw -%}'\n", FileType::PLAYBOOK)
      v.must_be_empty
    end
  end
end
