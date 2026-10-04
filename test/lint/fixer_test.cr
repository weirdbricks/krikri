require "../minitest_helper"
require "../../src/krikri_lint/lint"

# Writes the "before" content to a temp file, runs the full fixer over
# it with the given rules, and returns the file's content afterwards.
def fix_yaml(yaml : String, rules : Array(Krikri::Lint::Rule), write_list = ["all"]) : String
  path = File.tempname("lintfix", ".yml")
  File.write(path, yaml)
  registry = Krikri::Lint::RuleRegistry.new(rules)
  fixer = Krikri::Lint::Fixer.new(registry, write_list)
  file = Krikri::Lint::PositionedFile.new(path, Krikri::Lint::FileType::PLAYBOOK,
    YAML::Nodes.parse(yaml).nodes.first?, nil)
  violations = [] of Krikri::Lint::Violation
  rules.each { |rule| rule.check(file, violations) }
  fixer.apply(violations)
  File.read(path)
ensure
  File.delete(path) if path
end

def fix_plain_yaml(yaml : String, rule : Krikri::Lint::Rule, write_list = ["all"]) : String
  fix_yaml(yaml, [rule] of Krikri::Lint::Rule, write_list)
end

module Krikri::Lint
  describe FixBuffer do
    it "replaces spans within lines using 1-based columns" do
      buffer = FixBuffer.new("---\nfoo: bar\n")
      buffer.replace_span(2, 6, 3, "baz").must_equal(true)
      buffer.result.must_equal("---\nfoo: baz\n")
    end

    it "rejects out-of-bounds spans" do
      buffer = FixBuffer.new("---\nfoo\n")
      buffer.replace_span(2, 3, 5, "x").must_equal(false)
      buffer.replace_span(9, 1, 1, "x").must_equal(false)
      buffer.result.must_equal("---\nfoo\n")
    end

    it "preserves a missing trailing newline" do
      FixBuffer.new("a: 1").result.must_equal("a: 1")
      FixBuffer.new("a: 1\n").result.must_equal("a: 1\n")
    end

    it "adds a final newline on demand" do
      buffer = FixBuffer.new("a: 1")
      buffer.add_final_newline
      buffer.result.must_equal("a: 1\n")
    end

    it "deletes lines without shifting other coordinates" do
      buffer = FixBuffer.new("a: 1\n\n\n\nb: 2\n")
      buffer.delete_line(3)
      buffer.replace_span(5, 1, 4, "b: 3").must_equal(true)
      buffer.result.must_equal("a: 1\n\n\nb: 3\n")
    end
  end

  describe FixSpan do
    it "spans quoted scalars including the quotes" do
      FixSpan.scalar_span("  when: \"{{ x }}\"", 9).must_equal({8, 17})
      FixSpan.quote_char("  when: \"{{ x }}\"", 9).must_equal('"')
    end

    it "spans plain scalars, excluding trailing whitespace" do
      FixSpan.scalar_span("  name: foo bar  ", 9).must_equal({8, 15})
    end

    it "cuts plain scalars at a trailing comment" do
      FixSpan.scalar_span("  name: foo # hi", 9).must_equal({8, 11})
    end

    it "declines block scalars" do
      FixSpan.scalar_span("  shell: |", 10).must_be_nil
    end
  end

  describe Fixer do
    describe ".effective_write_set" do
      # Named explicitly: minitest names every bare `it { }` test_anonymous,
      # so unnamed examples silently overwrite each other.
      it "keeps all" do
        Fixer.effective_write_set(["all"]).must_equal(Set{"all"})
      end
      it "is empty for an empty list" do
        Fixer.effective_write_set([] of String).must_be_empty
      end
      it "keeps none" do
        Fixer.effective_write_set(["none"]).must_equal(Set{"none"})
      end
      it "resets at none and keeps only the rules after it" do
        Fixer.effective_write_set(["fqcn[action-core]", "none", "name"])
          .must_equal(Set{"name"})
      end
    end

    it "reports no changes when nothing is fixable" do
      source = "---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      apt: name=x\n"
      path = File.tempname("lintfix", ".yml")
      File.write(path, source)
      registry = RuleRegistry.new([FqcnActionCoreRule.new] of Rule)
      file = PositionedFile.new(path, FileType::PLAYBOOK,
        YAML::Nodes.parse(source).nodes.first?, nil)
      violations = [] of Violation
      NoChangedWhenRule.new.check(file, violations)
      fixer = Fixer.new(registry, ["none"])
      fixer.apply(violations).must_be_empty
      File.read(path).must_equal(source)
    ensure
      File.delete(path) if path
    end

    it "skips files the parser rejects, without raising or writing" do
      source = "a: 1   \nb: [unclosed\n"
      path = File.tempname("lintfix", ".yml")
      File.write(path, source)
      registry = RuleRegistry.new([YamlTrailingSpacesRule.new] of Rule)
      violations = [Violation.new(path, 1, 0, "yaml[trailing-spaces]",
        Severity::LOW, "Trailing spaces")]
      fixer = Fixer.new(registry, ["all"])
      fixer.apply(violations).must_be_empty
      File.read(path).must_equal(source)
    ensure
      File.delete(path) if path
    end

    describe "#not_applied" do
      it "flags transformable rules whose transform does not mark the match fixed" do
        registry = RuleRegistry.default
        fixer = Fixer.new(registry, ["all"])
        violations = [
          Violation.new("p.yml", 4, 0, "name[missing]", Severity::MEDIUM,
            "All tasks should be named.", 4),
          Violation.new("p.yml", 5, 8, "name[casing]", Severity::MEDIUM,
            "All names should start with an uppercase letter.", 5),
          Violation.new("f.yml", 1, 0, "yaml[trailing-spaces]", Severity::LOW,
            "Trailing spaces"),
          Violation.new("p.yml", 4, 0, "no-changed-when", Severity::HIGH,
            "Commands should not change things if nothing needs doing.", 4),
          Violation.new("p.yml", 4, 0, "command-instead-of-shell", Severity::HIGH,
            "Use shell only when shell functionality is required.", 4),
        ]
        fixer.not_applied(violations).map(&.rule_id).must_equal([
          "yaml[trailing-spaces]",
          "name[missing]",
        ])
      end

      it "respects the write list" do
        registry = RuleRegistry.default
        fixer = Fixer.new(registry, ["name"])
        violations = [
          Violation.new("p.yml", 4, 0, "name[missing]", Severity::MEDIUM,
            "All tasks should be named.", 4),
          Violation.new("f.yml", 1, 0, "yaml[trailing-spaces]", Severity::LOW,
            "Trailing spaces"),
        ]
        fixer.not_applied(violations).map(&.rule_id).must_equal(["name[missing]"])
      end

      it "reports nothing when the write list is none" do
        registry = RuleRegistry.default
        fixer = Fixer.new(registry, ["none"])
        fixer.not_applied([
          Violation.new("f.yml", 1, 0, "yaml[colons]", Severity::LOW,
            "Too many spaces before colon"),
        ]).must_be_empty
      end
    end

    describe "#marked_fixed?" do
      it "marks the sub-tags upstream's transforms rewrite" do
        registry = RuleRegistry.default
        fixer = Fixer.new(registry, ["all"])
        casing = Violation.new("p.yml", 5, 8, "name[casing]", Severity::MEDIUM, "m", 5)
        missing = Violation.new("p.yml", 4, 0, "name[missing]", Severity::MEDIUM, "m", 4)
        shell = Violation.new("p.yml", 4, 0, "command-instead-of-shell",
          Severity::HIGH, "m", 4)
        spaces = Violation.new("f.yml", 1, 0, "yaml[trailing-spaces]", Severity::LOW, "m")
        fixer.marked_fixed?(casing).must_equal(true)
        fixer.marked_fixed?(missing).must_equal(false)
        fixer.marked_fixed?(shell).must_equal(true)
        fixer.marked_fixed?(spaces).must_equal(false)
      end
    end

    describe ".not_applied_id" do
      it "uses the task match type for task-scoped sub-tags" do
        v = Violation.new("p.yml", 4, 0, "name[missing]", Severity::MEDIUM, "m", 4)
        Fixer.not_applied_id(v).must_equal("name[missing]/task p.yml:4[/]")
      end

      it "uses the yaml match type for yaml sub-tags" do
        v = Violation.new("f.yml", 1, 0, "yaml[trailing-spaces]", Severity::LOW, "m")
        Fixer.not_applied_id(v).must_equal("yaml[trailing-spaces]/yaml f.yml:1")
      end

      it "adds the stray closing tag only for word-only sub-tags" do
        v = Violation.new("f.yml", 2, 0, "yaml[colons]", Severity::LOW, "m")
        Fixer.not_applied_id(v).must_equal("yaml[colons]/yaml f.yml:2[/]")
      end

      it "uses the play match type for play-level matches" do
        v = Violation.new("p.yml", 1, 1, "name[play]", Severity::MEDIUM, "m", 1)
        Fixer.not_applied_id(v).must_equal("name[play]/play p.yml:1[/]")
      end
    end
  end

  describe "rule fixes" do
    it "fqcn[action-core] rewrites the bare module key" do
      fix_plain_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      apt: name=x\n",
        FqcnActionCoreRule.new
      ).must_equal("---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      ansible.builtin.apt: name=x\n")
    end

    it "fqcn[canonical] rewrites to the canonical name" do
      fix_plain_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      community.mysql.mysql_user: name=x\n",
        FqcnCanonicalRule.new
      ).must_equal("---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      ansible.mysql.mysql_user: name=x\n")
    end

    it "command-instead-of-shell renames the key and suppresses the fqcn fix on it" do
      fixed = fix_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      shell: echo hi\n      changed_when: false\n",
        [FqcnActionCoreRule.new, CommandInsteadOfShellRule.new]
      )
      fixed.must_equal("---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      ansible.builtin.command: echo hi\n      changed_when: false\n")
    end

    it "yaml[trailing-spaces] strips trailing whitespace including blank-only lines" do
      fix_plain_yaml(
        "---\n- name: t  \n  hosts: all\n  \n  vars:\n    msg: hello   \n",
        YamlTrailingSpacesRule.new
      ).must_equal("---\n- name: t\n  hosts: all\n\n  vars:\n    msg: hello\n")
    end

    it "yaml[new-line-at-end-of-file] appends the newline" do
      fix_plain_yaml("a: 1", YamlNewLineAtEndOfFileRule.new).must_equal("a: 1\n")
      fix_plain_yaml("a: 1\n", YamlNewLineAtEndOfFileRule.new).must_equal("a: 1\n")
    end

    it "yaml[empty-lines] collapses interior runs to the max and clears EOF runs" do
      fix_plain_yaml(
        "---\n- name: t\n  hosts: all\n\n\n\n\n  tasks: []\n",
        YamlEmptyLinesRule.new
      ).must_equal("---\n- name: t\n  hosts: all\n\n\n  tasks: []\n")

      fix_plain_yaml(
        "---\n- name: t\n  hosts: all\n\n\n\n",
        YamlEmptyLinesRule.new
      ).must_equal("---\n- name: t\n  hosts: all\n")
    end

    it "name[casing] capitalizes the first word and updates notify references" do
      fix_plain_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: do stuff\n      command: /bin/true\n      changed_when: false\n      notify: do stuff\n    - name: other\n      command: /bin/true\n      changed_when: false\n      notify:\n        - do stuff\n        - something else\n",
        NameRule.new
      ).must_equal("---\n- name: P\n  hosts: all\n  tasks:\n    - name: Do stuff\n      command: /bin/true\n      changed_when: false\n      notify: Do stuff\n    - name: Other\n      command: /bin/true\n      changed_when: false\n      notify:\n        - Do stuff\n        - something else\n")
    end

    it "name[casing] keeps an include_tasks prefix intact" do
      fix_plain_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: file | do stuff\n      command: /bin/true\n      changed_when: false\n",
        NameRule.new
      ).must_equal("---\n- name: P\n  hosts: all\n  tasks:\n    - name: file | Do stuff\n      command: /bin/true\n      changed_when: false\n")
    end

    it "no-jinja-when strips braces from string when values, keeping quotes" do
      fix_plain_yaml(
        "---\n- name: t\n  command: /bin/true\n  when: \"{{ x }}\"\n",
        NoJinjaWhenRule.new
      ).must_equal("---\n- name: t\n  command: /bin/true\n  when: \"x\"\n")
    end

    it "no-jinja-when leaves list whens alone" do
      source = "---\n- name: t\n  command: /bin/true\n  when:\n    - \"{{ x }}\"\n"
      fix_plain_yaml(source, NoJinjaWhenRule.new).must_equal(source)
    end

    it "scopes fixes with a write list" do
      fixed = fix_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: lower\n      apt: name=x\n",
        [FqcnActionCoreRule.new, NameRule.new], ["fqcn"]
      )
      fixed.must_equal("---\n- name: p\n  hosts: all\n  tasks:\n    - name: lower\n      ansible.builtin.apt: name=x\n")
    end

    it "does not touch yaml[truthy] values (upstream leaves them too)" do
      fix_plain_yaml("foo: yes\n", YamlTruthyRule.new).must_equal("foo: yes\n")
    end
  end
end
