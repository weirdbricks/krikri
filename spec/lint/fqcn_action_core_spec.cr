require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe FqcnActionCoreRule do
    rule = FqcnActionCoreRule.new

    it "flags a bare builtin module" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install
          apt:
            name: htop
        YAML
      v.size.should eq(1)
      v.first.rule_id.should eq("fqcn[action-core]")
      v.first.message.should eq("Use FQCN for builtin module actions (apt).")
    end

    it "allows the FQCN form" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install
          ansible.builtin.apt:
            name: htop
        YAML
      v.should be_empty
    end

    it "allows the ansible.legacy form" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install
          ansible.legacy.apt:
            name: htop
        YAML
      v.should be_empty
    end

    it "does not flag unknown community modules" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Community
          community.docker.docker_container:
            name: x
        YAML
      v.should be_empty
    end

    it "checks handlers and task files" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Restart
          service:
            name: nginx
            state: restarted
          listen: restart nginx
        YAML
      v.size.should eq(1)
      v.first.line.should eq(2)
    end
  end
end
