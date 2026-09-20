require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe FqcnCanonicalRule do
    rule = FqcnCanonicalRule.new

    it "flags a redirected builtin FQCN to its canonical collection" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: A
              ansible.builtin.acl:
                path: /tmp/x
        YAML
      v.size.should eq(1)
      v.first.rule_id.should eq("fqcn[canonical]")
      v.first.message.should eq(
        "You should use canonical module name `ansible.posix.acl` instead of `ansible.builtin.acl`."
      )
      v.first.line.should eq(6)
      v.first.column.should eq(7)
    end

    it "flags a redirected community FQCN (mysql -> ansible.mysql)" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: A
              community.mysql.mysql_user:
                name: x
                state: present
        YAML
      v.size.should eq(1)
      v.first.message.should eq(
        "You should use canonical module name `ansible.mysql.mysql_user` instead of `community.mysql.mysql_user`."
      )
    end

    it "allows already-canonical names" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: A
              community.general.cronvar:
                name: x
                value: y
        YAML
      v.should be_empty
    end

    it "ignores bare and unknown names" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Play
          hosts: all
          tasks:
            - name: A
              acl:
                path: /tmp/x
            - name: B
              community.docker.docker_container:
                name: x
        YAML
      v.should be_empty
    end
  end
end
