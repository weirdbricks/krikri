require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe DeprecatedBareVarsRule do
    private def rule
      DeprecatedBareVarsRule.new
    end

    private def playbook(tasks : String) : String
      "---\n- name: Play\n  hosts: all\n  tasks:\n#{tasks}"
    end

    private def message(term : String, loop_type : String) : String
      "Possible bare variable '#{term}' used in a '#{loop_type}' loop. " \
      "You should use the full variable syntax ('{{ #{term} }}') or " \
      "convert it to a list if that is not really a variable."
    end

    it "flags a bare name in a with_items loop at the task's first line" do
      v = lint_yaml(rule, playbook(
        "    - name: Loop with a bare variable\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_items: my_list\n"))
      v.size.must_equal(1)
      violation = v.first
      violation.line.must_equal(5)
      violation.column.must_equal(0)
      violation.rule_id.must_equal("deprecated-bare-vars")
      violation.message.must_equal(message("my_list", "with_items"))
      violation.task_line.must_equal(5)
    end

    it "flags every other with_* loop through the same arm" do
      v = lint_yaml(rule, playbook(
        "    - name: Dict\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_dict: my_dict\n" \
        "    - name: Random choice\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_random_choice: my_list\n"))
      v.map(&.message).must_equal([
        message("my_dict", "with_dict"),
        message("my_list", "with_random_choice"),
      ])
    end

    it "checks only the first term of a per-element loop" do
      v = lint_yaml(rule, playbook(
        "    - name: Nested list\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_nested:\n" \
        "        - my_list\n" \
        "        - other_list\n"))
      v.size.must_equal(1)
      v.first.message.must_equal(message("['my_list', 'other_list']", "with_nested"))
      # Upstream returns on the first term, so a templated first term
      # hides a bare second one.
      lint_yaml(rule, playbook(
        "    - name: Templated first term\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_together:\n" \
        "        - \"{{ my_list }}\"\n" \
        "        - other_list\n")).must_be_empty
    end

    it "reports with_subelements with the whole term list" do
      v = lint_yaml(rule, playbook(
        "    - name: Subelements\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_subelements: [my_list, keys]\n"))
      v.size.must_equal(1)
      v.first.message.must_equal(message("['my_list', 'keys']", "with_subelements"))
    end

    it "leaves the loops upstream skips alone" do
      lint_yaml(rule, playbook(
        "    - name: Sequence\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_sequence: start=1 end=3\n" \
        "    - name: Ini\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_ini: my_section\n" \
        "    - name: Inventory hostnames\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_inventory_hostnames: all\n")).must_be_empty
    end

    it "exempts a glob fileglob and a directory filetree term" do
      lint_yaml(rule, playbook(
        "    - name: Glob fileglob\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_fileglob: \"*.conf\"\n" \
        "    - name: Directory filetree\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_filetree: files/\n")).must_be_empty
      v = lint_yaml(rule, playbook(
        "    - name: Bare fileglob\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_fileglob: my_glob\n" \
        "    - name: Bare filetree\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_filetree: files\n" \
        "    - name: Collection filetree\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_community.general.filetree: files\n"))
      v.map(&.rule_id).must_equal(["deprecated-bare-vars"] * 3)
    end

    it "ignores loop and when, which are expressions" do
      lint_yaml(rule, playbook(
        "    - name: Loop keyword\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      loop: my_list\n" \
        "    - name: Bare condition\n" \
        "      ansible.builtin.debug:\n" \
        "        msg: skipped\n" \
        "      when: my_flag\n")).must_be_empty
    end

    it "ignores terms that are not plain names" do
      lint_yaml(rule, playbook(
        "    - name: Full variable syntax\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_items: \"{{ my_list }}\"\n" \
        "    - name: Integer\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_items: 42\n" \
        "    - name: Bool\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_items: true\n" \
        "    - name: Null\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_items: null\n" \
        "    - name: Spaced words\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_items: my list\n" \
        "    - name: Path\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_items: /path/to/file\n")).must_be_empty
    end

    it "is suppressed by a task-level noqa" do
      yaml = playbook(
        "    - name: Loop\n" \
        "      ansible.builtin.debug:\n" \
        "        var: item\n" \
        "      with_items: my_list  # noqa: deprecated-bare-vars\n")
      run_rules_yaml(yaml, [rule] of Rule).must_be_empty
    end

    it "declares upstream's severity and tags" do
      rule.severity.must_equal(Severity::VERY_HIGH)
      rule.tags.must_equal(["deprecations"])
      rule.task_scoped?.must_equal(true)
      rule.opt_in?.must_equal(false)
    end

    it "is registered for --list-rules and the basic profile" do
      RuleRegistry.default.find("deprecated-bare-vars").wont_be_nil
      Profile.of("deprecated-bare-vars").must_equal("basic")
      Profile.includes?("basic", "deprecated-bare-vars").must_equal(true)
      Profile.includes?("min", "deprecated-bare-vars").must_equal(false)
    end
  end
end
