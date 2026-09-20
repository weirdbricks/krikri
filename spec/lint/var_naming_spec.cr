require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe VarNamingRule do
    rule = VarNamingRule.new

    it "flags bad pattern in play vars" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          vars:
            myBadVar: 1
          tasks:
            - name: Ok
              command: true
        YAML
      v.map(&.rule_id).should eq(["var-naming[pattern]"])
      v.first.line.should eq(4)
    end

    it "flags set_fact keys" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          tasks:
            - name: Set
              set_fact:
                badCamel: 1
        YAML
      v.map(&.rule_id).should eq(["var-naming[pattern]"])
      v.first.message.should contain("(set_fact: badCamel)")
    end

    it "skips private __keys and cacheable in set_fact" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          tasks:
            - name: Set
              set_fact:
                __private: 1
                cacheable: true
                good_var: 2
        YAML
      v.should be_empty
    end

    it "flags reserved names" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          vars:
            environment: production
          tasks:
            - name: Ok
              command: true
        YAML
      v.map(&.rule_id).should eq(["var-naming[no-reserved]"])
    end

    it "allows special ansible_ names" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          vars:
            ansible_host: web1
          tasks:
            - name: Ok
              command: true
        YAML
      v.should be_empty
    end

    it "allows jinja-templated set_fact keys" do
      v = lint_yaml(rule, "---\n- hosts: all\n  tasks:\n    - name: Set\n      set_fact:\n        \"loop_fact_{{ item }}\": 1\n", FileType::PLAYBOOK)
      v.should be_empty
    end

    it "checks vars-file top-level keys" do
      v = lint_yaml(rule, "---\nbadVar: 1\ngood_var: 2\n", FileType::VARS)
      v.size.should eq(1)
      v.first.line.should eq(2)
    end

    it "checks register" do
      v = lint_yaml(rule, <<-YAML, FileType::PLAYBOOK)
        ---
        - hosts: all
          tasks:
            - name: Reg
              command: true
              register: badRegister
        YAML
      v.map(&.rule_id).should eq(["var-naming[pattern]"])
      v.first.message.should contain("(register: badRegister)")
    end
  end
end
