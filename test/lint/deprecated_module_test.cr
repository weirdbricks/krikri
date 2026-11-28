require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe DeprecatedModuleRule do
    private def rule
      DeprecatedModuleRule.new
    end

    private def playbook(module_name : String) : String
      "---\n- name: Play\n  hosts: all\n  tasks:\n    - name: A\n      #{module_name}:\n        name: web\n"
    end

    it "flags a deprecated module at the task line with no column" do
      v = lint_yaml(rule, playbook("docker"))
      v.size.must_equal(1)
      violation = v.first
      violation.rule_id.must_equal("deprecated-module")
      violation.line.must_equal(5)
      violation.column.must_equal(0)
      violation.message.must_equal("Deprecated module. docker")
      violation.task_line.must_equal(5)
    end

    it "flags every name upstream's hand-kept list carries" do
      # Upstream does not read ansible's deprecation metadata here, so the
      # list is data, not something a module's own docs can derive.
      DeprecatedModuleRule::MODULES.size.must_equal(39)
      %w[accelerate docker include win_msi vsphere_guest].each do |name|
        lint_yaml(rule, playbook(name)).size.must_equal(1)
      end
    end

    it "leaves non-deprecated modules alone" do
      %w[command copy community.general.docker].each do |name|
        lint_yaml(rule, playbook(name)).must_be_empty
      end
    end

    it "does not match a prefixed deprecated name, like upstream" do
      # Upstream matches the name as written, so ansible-lint 25.2.1 stays
      # silent for both forms even though the module resolves.
      %w[ansible.builtin.docker ansible.legacy.docker].each do |name|
        lint_yaml(rule, playbook(name)).must_be_empty
      end
    end

    it "is registered for --list-rules and the basic profile" do
      found = RuleRegistry.default.find("deprecated-module")
      found.wont_be_nil
      if found
        found.severity.must_equal(Severity::HIGH)
        found.tags.must_equal(["deprecations"])
      end
      Profile.includes?("basic", "deprecated-module").must_equal(true)
      Profile.includes?("min", "deprecated-module").must_equal(false)
    end
  end
end
