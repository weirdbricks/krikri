require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe FqcnActionCoreRule do
    private def rule
      FqcnActionCoreRule.new
    end

    it "flags a bare builtin module" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install
          apt:
            name: htop
        YAML
      v.size.must_equal(1)
      v.first.rule_id.must_equal("fqcn[action-core]")
      v.first.message.must_equal("Use FQCN for builtin module actions (apt).")
    end

    it "allows the FQCN form" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install
          ansible.builtin.apt:
            name: htop
        YAML
      v.must_be_empty
    end

    it "allows the ansible.legacy form" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Install
          ansible.legacy.apt:
            name: htop
        YAML
      v.must_be_empty
    end

    it "does not flag unknown community modules" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - name: Community
          community.docker.docker_container:
            name: x
        YAML
      v.must_be_empty
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
      v.size.must_equal(1)
      v.first.line.must_equal(3)
    end

    # Ansible's ModuleArgsParser resolves action:/local_action: to the
    # module they name, and ansible-lint reports fqcn at the alias value
    # that names it (the mapping's `module:` value, the string value's
    # own column).
    it "reports a mapping-form alias's module value" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - hosts: localhost
          gather_facts: false
          tasks:
            - name: say hi via dict local_action
              local_action:
                module: debug
                msg: hi
        YAML
      v.size.must_equal(1)
      v.first.line.must_equal(7)
      v.first.column.must_equal(17)
      v.first.message.must_equal("Use FQCN for builtin module actions (debug).")
    end

    it "reports a string-form alias's first token" do
      v = lint_yaml(rule, <<-YAML)
        ---
        - hosts: localhost
          gather_facts: false
          tasks:
            - name: say hi via string local_action
              local_action: debug msg=hi
            - name: say hi via action
              action: debug msg=hi
        YAML
      v.map { |x| {x.line, x.column} }.must_equal([{6, 21}, {8, 15}])
      v.map(&.message).must_equal([
        "Use FQCN for builtin module actions (debug).",
        "Use FQCN for builtin module actions (debug).",
      ])
    end
  end
end
