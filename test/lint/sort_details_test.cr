require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe "lint parity: match sort order and Task/Handler enrichment" do
    # Upstream MatchError.__lt__ sorts by _hash_key: filename, lineno,
    # str(rule.id), message, details, column - with a None column mapped
    # to -1 so column-less matches sort first. The rule id is the rule's
    # family, so same-family sub-tags tie on the rule and are ordered by
    # message.
    describe Outcome do
      private def v(line : Int32, column : Int32, rule_id : String, message : String,
                    details : String = "", path : String = "play.yml") : Violation
        Violation.new(path, line, column, rule_id, Severity::MEDIUM, message,
          nil, false, details)
      end

      it "sorts by rule family before column, so a column-less match of a later rule does not jump ahead" do
        # Upstream: name (no column) vs fqcn (column 7) on the same task
        # line - fqcn sorts first because "fqcn" < "name", the columns
        # never get compared across different rules.
        fqcn = v(7, 7, "fqcn[action-core]", "Use FQCN for builtin module actions (ping).",
          "Use `ansible.builtin.ping` or `ansible.legacy.ping` instead.")
        missing = v(7, 0, "name[missing]", "All tasks should be named.")
        Outcome.sort([missing, fqcn]).must_equal([fqcn, missing])
      end

      it "breaks same-family ties by message, like upstream's shared rule id" do
        # Sub-tags of one family share the rule id upstream, so two
        # yaml[*] matches on one line are ordered by their messages, not
        # by the sub-tag names.
        commas = v(7, 5, "yaml[trailing-spaces]", "Trailing spaces...")
        octal = v(7, 3, "yaml[octal-values]", "Forbidden implicit octal value \"0644\"")
        Outcome.sort([commas, octal]).must_equal([octal, commas])
      end

      it "breaks same-message ties by details, then puts the no-column match first" do
        with_details = v(7, 9, "yaml[x]", "Same message", "has details")
        no_details = v(7, 9, "yaml[x]", "Same message", "")
        Outcome.sort([with_details, no_details]).must_equal([no_details, with_details])
        late_column = v(7, 9, "yaml[x]", "Same message")
        early_column = v(7, 2, "yaml[x]", "Same message")
        Outcome.sort([late_column, early_column]).must_equal([early_column, late_column])
      end
    end

    describe Runner do
      it "keeps fqcn's own details instead of adding Task/Handler" do
        # Upstream's fqcn match carries its own details
        # ("Use `...` or `...` instead."), so
        # _enrich_matcherror_with_task_details leaves it alone. Verified
        # against ansible-lint 25.2.1 on a playbook with `- ping:`.
        violations = run_rules_yaml(
          "---\n- hosts: localhost\n  tasks:\n    - ping:\n",
          [FqcnActionCoreRule.new, NameRule.new],
        )
        fqcn = violations.find { |v| v.rule_id == "fqcn[action-core]" }
        raise "no fqcn[action-core] violation" unless fqcn
        fqcn.details.must_equal(
          "Use `ansible.builtin.ping` or `ansible.legacy.ping` instead.")
      end

      it "keeps jinja[spacing]'s rewrite-recommendation details" do
        violations = run_rules_yaml(
          "---\n- hosts: localhost\n  tasks:\n    - name: A\n" \
          "      ansible.builtin.command: echo {{x}}\n",
          [JinjaRule.new, NameRule.new],
        )
        spacing = violations.find { |v| v.rule_id == "jinja[spacing]" }
        raise "no jinja[spacing] violation" unless spacing
        spacing.details.must_equal(
          "Jinja2 template rewrite recommendation: `echo {{ x }}`.")
      end

      it "still enriches detail-less matches with Task/Handler" do
        violations = run_rules_yaml(
          "---\n- hosts: localhost\n  tasks:\n    - ansible.builtin.ping:\n",
          [FqcnActionCoreRule.new, NameRule.new],
        )
        missing = violations.find { |v| v.rule_id == "name[missing]" }
        raise "no name[missing] violation" unless missing
        missing.details.must_equal("Task/Handler: ping ")
      end

      it "lists fqcn before name[missing] on the same task line, like upstream" do
        violations = run_rules_yaml(
          "---\n- hosts: localhost\n  tasks:\n    - ping:\n",
          [FqcnActionCoreRule.new, NameRule.new],
        )
        ordered = violations.select { |v| v.line == 4 }
        ordered.map(&.rule_id).must_equal(["fqcn[action-core]", "name[missing]"])
      end
    end
  end
end
