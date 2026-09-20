require "../spec_helper"
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
      buffer.replace_span(2, 6, 3, "baz").should be_true
      buffer.result.should eq("---\nfoo: baz\n")
    end

    it "rejects out-of-bounds spans" do
      buffer = FixBuffer.new("---\nfoo\n")
      buffer.replace_span(2, 3, 5, "x").should be_false
      buffer.replace_span(9, 1, 1, "x").should be_false
      buffer.result.should eq("---\nfoo\n")
    end

    it "preserves a missing trailing newline" do
      FixBuffer.new("a: 1").result.should eq("a: 1")
      FixBuffer.new("a: 1\n").result.should eq("a: 1\n")
    end

    it "adds a final newline on demand" do
      buffer = FixBuffer.new("a: 1")
      buffer.add_final_newline
      buffer.result.should eq("a: 1\n")
    end

    it "deletes lines without shifting other coordinates" do
      buffer = FixBuffer.new("a: 1\n\n\n\nb: 2\n")
      buffer.delete_line(3)
      buffer.replace_span(5, 1, 4, "b: 3").should be_true
      buffer.result.should eq("a: 1\n\n\nb: 3\n")
    end
  end

  describe FixSpan do
    it "spans quoted scalars including the quotes" do
      FixSpan.scalar_span("  when: \"{{ x }}\"", 9).should eq({8, 17})
      FixSpan.quote_char("  when: \"{{ x }}\"", 9).should eq('"')
    end

    it "spans plain scalars, excluding trailing whitespace" do
      FixSpan.scalar_span("  name: foo bar  ", 9).should eq({8, 15})
    end

    it "cuts plain scalars at a trailing comment" do
      FixSpan.scalar_span("  name: foo # hi", 9).should eq({8, 11})
    end

    it "declines block scalars" do
      FixSpan.scalar_span("  shell: |", 10).should be_nil
    end
  end

  describe Fixer do
    describe ".effective_write_set" do
      it { Fixer.effective_write_set(["all"]).should eq(Set{"all"}) }
      it { Fixer.effective_write_set([] of String).should be_empty }
      it { Fixer.effective_write_set(["none"]).should eq(Set{"none"}) }
      it do
        Fixer.effective_write_set(["fqcn[action-core]", "none", "name"])
          .should eq(Set{"name"})
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
      fixer.apply(violations).should be_empty
      File.read(path).should eq(source)
    ensure
      File.delete(path) if path
    end
  end

  describe "rule fixes" do
    it "fqcn[action-core] rewrites the bare module key" do
      fix_plain_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      apt: name=x\n",
        FqcnActionCoreRule.new
      ).should eq("---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      ansible.builtin.apt: name=x\n")
    end

    it "fqcn[canonical] rewrites to the canonical name" do
      fix_plain_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      community.mysql.mysql_user: name=x\n",
        FqcnCanonicalRule.new
      ).should eq("---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      ansible.mysql.mysql_user: name=x\n")
    end

    it "command-instead-of-shell renames the key and suppresses the fqcn fix on it" do
      fixed = fix_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      shell: echo hi\n      changed_when: false\n",
        [FqcnActionCoreRule.new, CommandInsteadOfShellRule.new]
      )
      fixed.should eq("---\n- name: p\n  hosts: all\n  tasks:\n    - name: t\n      ansible.builtin.command: echo hi\n      changed_when: false\n")
    end

    it "yaml[trailing-spaces] strips trailing whitespace including blank-only lines" do
      fix_plain_yaml(
        "---\n- name: t  \n  hosts: all\n  \n  vars:\n    msg: hello   \n",
        YamlTrailingSpacesRule.new
      ).should eq("---\n- name: t\n  hosts: all\n\n  vars:\n    msg: hello\n")
    end

    it "yaml[new-line-at-end-of-file] appends the newline" do
      fix_plain_yaml("a: 1", YamlNewLineAtEndOfFileRule.new).should eq("a: 1\n")
      fix_plain_yaml("a: 1\n", YamlNewLineAtEndOfFileRule.new).should eq("a: 1\n")
    end

    it "yaml[empty-lines] collapses interior runs to the max and clears EOF runs" do
      fix_plain_yaml(
        "---\n- name: t\n  hosts: all\n\n\n\n\n  tasks: []\n",
        YamlEmptyLinesRule.new
      ).should eq("---\n- name: t\n  hosts: all\n\n\n  tasks: []\n")

      fix_plain_yaml(
        "---\n- name: t\n  hosts: all\n\n\n\n",
        YamlEmptyLinesRule.new
      ).should eq("---\n- name: t\n  hosts: all\n")
    end

    it "name[casing] capitalizes the first word and updates notify references" do
      fix_plain_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: do stuff\n      command: /bin/true\n      changed_when: false\n      notify: do stuff\n    - name: other\n      command: /bin/true\n      changed_when: false\n      notify:\n        - do stuff\n        - something else\n",
        NameRule.new
      ).should eq("---\n- name: P\n  hosts: all\n  tasks:\n    - name: Do stuff\n      command: /bin/true\n      changed_when: false\n      notify: Do stuff\n    - name: Other\n      command: /bin/true\n      changed_when: false\n      notify:\n        - Do stuff\n        - something else\n")
    end

    it "name[casing] keeps an include_tasks prefix intact" do
      fix_plain_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: file | do stuff\n      command: /bin/true\n      changed_when: false\n",
        NameRule.new
      ).should eq("---\n- name: P\n  hosts: all\n  tasks:\n    - name: file | Do stuff\n      command: /bin/true\n      changed_when: false\n")
    end

    it "no-jinja-when strips braces from string when values, keeping quotes" do
      fix_plain_yaml(
        "---\n- name: t\n  command: /bin/true\n  when: \"{{ x }}\"\n",
        NoJinjaWhenRule.new
      ).should eq("---\n- name: t\n  command: /bin/true\n  when: \"x\"\n")
    end

    it "no-jinja-when leaves list whens alone" do
      source = "---\n- name: t\n  command: /bin/true\n  when:\n    - \"{{ x }}\"\n"
      fix_plain_yaml(source, NoJinjaWhenRule.new).should eq(source)
    end

    it "scopes fixes with a write list" do
      fixed = fix_yaml(
        "---\n- name: p\n  hosts: all\n  tasks:\n    - name: lower\n      apt: name=x\n",
        [FqcnActionCoreRule.new, NameRule.new], ["fqcn"]
      )
      fixed.should eq("---\n- name: p\n  hosts: all\n  tasks:\n    - name: lower\n      ansible.builtin.apt: name=x\n")
    end

    it "does not touch yaml[truthy] values (upstream leaves them too)" do
      fix_plain_yaml("foo: yes\n", YamlTruthyRule.new).should eq("foo: yes\n")
    end
  end
end
