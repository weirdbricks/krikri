require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe LoopVarPrefixRule do
    # A real roles/<role>/tasks/main.yml tree, so file classification and
    # role detection run exactly as they do for a linted role.
    private def role_file(yaml : String, role : String = "myrole") : {String, String}
      root = File.tempname("loopvarprefix")
      tasks_dir = File.join(root, "roles", role, "tasks")
      Dir.mkdir_p(tasks_dir)
      path = File.join(tasks_dir, "main.yml")
      File.write(path, yaml)
      {root, path}
    end

    private def rule(prefix : String? = "^(__|{role}_)") : LoopVarPrefixRule
      instance = LoopVarPrefixRule.new
      instance.config = LintConfig.new(loop_var_prefix: prefix)
      instance
    end

    private def violations(yaml : String, role : String = "myrole",
                           prefix : String? = "^(__|{role}_)") : Array(Violation)
      root, path = role_file(yaml, role)
      result = [] of Violation
      begin
        rule(prefix).check(PositionedFile.load(path), result)
      ensure
        FileUtils.rm_rf(root)
      end
      result
    end

    # The issue's repro: the unprefixed loop_var is reported, the
    # control task using myrole_item stays silent.
    it "flags a loop_var without the role prefix at the value's position" do
      yaml = <<-YAML
        ---
        - name: Loop over values with a loop_var that lacks the role prefix
          ansible.builtin.debug:
            msg: "{{ my_item }}"
          loop:
            - one
            - two
          loop_control:
            loop_var: my_item

        - name: Loop over values with the role's loop_var prefix
          ansible.builtin.debug:
            msg: "{{ myrole_item }}"
          loop:
            - one
            - two
          loop_control:
            loop_var: myrole_item
        YAML
      found = violations(yaml)
      found.size.must_equal(1)
      violation = found.first
      violation.rule_id.must_equal("loop-var-prefix[wrong]")
      violation.severity.must_equal(Severity::MEDIUM)
      violation.line.must_equal(9)
      violation.column.must_equal(15)
      violation.task_line.must_equal(2)
      violation.message.must_equal(
        "Loop variable name does not match /^(__|{role}_)/ regex, where role=myrole.")
    end

    it "accepts a double-underscore loop_var" do
      yaml = <<-YAML
        ---
        - name: Loop
          ansible.builtin.debug:
            msg: "{{ __item }}"
          loop: [one]
          loop_control:
            loop_var: __item
        YAML
      violations(yaml).must_be_empty
    end

    it "checks with_* loops too" do
      yaml = <<-YAML
        ---
        - name: Loop
          ansible.builtin.debug:
            msg: "{{ other }}"
          with_items: [one]
          loop_control:
            loop_var: other
        YAML
      found = violations(yaml)
      found.size.must_equal(1)
      found.first.rule_id.must_equal("loop-var-prefix[wrong]")
    end

    it "ignores loop_var-free tasks and loop_control without loop_var" do
      yaml = <<-YAML
        ---
        - name: No loop
          ansible.builtin.debug:
            msg: hi

        - name: Implicit item
          ansible.builtin.debug:
            msg: "{{ item }}"
          loop: [one]
        YAML
      violations(yaml).must_be_empty
    end

    it "stays disabled without a loop_var_prefix config" do
      yaml = <<-YAML
        ---
        - name: Loop
          ansible.builtin.debug:
            msg: "{{ other }}"
          loop: [one]
          loop_control:
            loop_var: other
        YAML
      violations(yaml, prefix: nil).must_be_empty
      violations(yaml, prefix: "").must_be_empty
    end

    it "ignores files outside any roles/ directory" do
      yaml = <<-YAML
        ---
        - name: Loop
          ansible.builtin.debug:
            msg: "{{ other }}"
          loop: [one]
          loop_control:
            loop_var: other
        YAML
      path = File.tempname("loopvarprefix", ".yml")
      File.write(path, yaml)
      begin
        result = [] of Violation
        rule.check(PositionedFile.load(path), result)
        result.must_be_empty
      ensure
        File.delete(path)
      end
    end

    # ansiblelint.text.toidentifier turns the role's directory name into
    # the identifier both the regex and the message use.
    it "converts whitespace and hyphens in the role name" do
      yaml = <<-YAML
        ---
        - name: Loop
          ansible.builtin.debug:
            msg: "{{ other }}"
          loop: [one]
          loop_control:
            loop_var: other
        YAML
      found = violations(yaml, role: "my-role")
      found.size.must_equal(1)
      found.first.message.must_equal(
        "Loop variable name does not match /^(__|{role}_)/ regex, where role=my_role.")

      prefixed = <<-YAML
        ---
        - name: Loop
          ansible.builtin.debug:
            msg: "{{ my_role_item }}"
          loop: [one]
          loop_control:
            loop_var: my_role_item
        YAML
      violations(prefixed, role: "my-role").must_be_empty
    end

    # The rule reads the run's config, which only the Runner hands it.
    it "gets the config from the Runner" do
      root, path = role_file(<<-YAML)
        ---
        - name: Loop
          ansible.builtin.debug:
            msg: "{{ other }}"
          loop: [one]
          loop_control:
            loop_var: other
        YAML
      registry = RuleRegistry.new([LoopVarPrefixRule.new] of Rule)
      config = LintConfig.new(loop_var_prefix: "^(__|{role}_)")
      begin
        Runner.new(registry, config).run([path]).size.must_equal(1)
        Runner.new(registry, LintConfig.new).run([path]).must_be_empty
      ensure
        FileUtils.rm_rf(root)
      end
    end

    it "resolves the role's directory name from the path" do
      FileType.role_name("x/roles/myrole/tasks/main.yml").must_equal("myrole")
      # Upstream walks up to the innermost enclosing roles/ dir.
      FileType.role_name("x/roles/outer/roles/inner/tasks/main.yml").must_equal("inner")
      FileType.role_name("x/tasks/main.yml").must_be_nil
    end

    it "is registered for --list-rules and the production profile" do
      RuleRegistry.default.find("loop-var-prefix").wont_be_nil
      LoopVarPrefixRule.new.tags.must_equal(["idiom"])
      # Upstream lists the rule in no profile's rules:list, so it is
      # production-only (--profile min stays silent, verified against
      # ansible-lint 25.2.1) and the summary's row reports the walked
      # profile rather than one of its own.
      Profile.of("loop-var-prefix[wrong]").must_be_nil
      Profile.includes?("production", "loop-var-prefix[wrong]").must_equal(true)
      Profile.includes?("min", "loop-var-prefix[wrong]").must_equal(false)
    end
  end
end
