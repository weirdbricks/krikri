require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlCommentsRule do
    rule = YamlCommentsRule.new

    it "flags comments without starting space" do
      v = lint_yaml(rule, "---\n#nospace\n- name: t\n  hosts: all\n")
      v.map(&.rule_id).should eq(["yaml[comments]"])
      v.first.line.should eq(2)
      v.first.message.should eq("Missing starting space in comment")
    end

    it "flags run-of-hash comments without starting space" do
      v = lint_yaml(rule, "---\n- name: t\n####banner\n  hosts: all\n")
      v.map(&.line).should eq([3])
    end

    it "flags inline comments with too few spaces before them" do
      v = lint_yaml(rule, "---\n- name: t\n  vars:\n    a: \"x\"# c\n    b: 2  # ok\n    c: 3 # ok\n")
      v.map(&.rule_id).should eq(["yaml[comments]"])
      v.first.line.should eq(4)
      v.first.message.should eq("Too few spaces before comment: expected 1")
    end

    it "accepts spaced comments and ignores shebang" do
      v = lint_yaml(rule, "---\n# ok\n- name: t\n  hosts: all  # ok\n")
      v.should be_empty
    end

    it "exempts a shebang on line 1" do
      v = lint_yaml(rule, "#!/usr/bin/env ansible-playbook\n---\n- name: t\n  hosts: all\n")
      v.should be_empty
    end

    it "ignores hash runs inside block scalars" do
      v = lint_yaml(rule, "---\n- name: t\n  shell: |\n    # not a comment\n    ls\n  hosts: all\n")
      v.should be_empty
    end
  end
end
