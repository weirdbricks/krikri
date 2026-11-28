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

    # The [wrong] arm: the loop_var is set but lacks the role prefix, so
    # it is reported at the loop_var value's own position.
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

    it "ignores tasks that do not loop" do
      yaml = <<-YAML
        ---
        - name: No loop
          ansible.builtin.debug:
            msg: hi
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

    # Upstream only reports inside a role (its `file.role` comes from the
    # roles/<name>/ part of the path), so every fixture lives there.
    private def role_violations(yaml : String, config : LintConfig = loop_var_config,
                                subdir : String = "tasks") : Array(Violation)
      dir = File.tempname("loopvarprefixspec")
      Dir.mkdir_p(File.join(dir, "roles", "myrole", subdir))
      path = File.join(dir, "roles", "myrole", subdir, "main.yml")
      File.write(path, yaml)
      file = PositionedFile.load(path)
      violations = [] of Violation
      rule = LoopVarPrefixRule.new
      rule.config = config
      rule.check(file, violations)
      violations
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    private def loop_var_config : LintConfig
      LintConfig.new(loop_var_prefix: "^(__|{role}_)")
    end

    # The [missing] arm: the issue's repro, plus the control task whose
    # prefixed loop_var must stay silent.
    it "flags an implicit item loop at the first loop value" do
      v = role_violations(
        "---\n" \
        "- name: Loop over values without a loop_var\n" \
        "  ansible.builtin.debug:\n" \
        "    msg: \"{{ item }}\"\n" \
        "  loop:\n" \
        "    - one\n" \
        "    - two\n" \
        "\n" \
        "- name: Loop over values with the role's loop_var prefix\n" \
        "  ansible.builtin.debug:\n" \
        "    msg: \"{{ myrole_item }}\"\n" \
        "  loop:\n" \
        "    - one\n" \
        "    - two\n" \
        "  loop_control:\n" \
        "    loop_var: myrole_item\n")
      v.map(&.rule_id).must_equal(["loop-var-prefix[missing]"])
      v.first.line.must_equal(6)
      v.first.column.must_equal(5)
      v.first.task_line.must_equal(2)
      v.first.message.must_equal(
        "Replace unsafe implicit `item` loop variable by adding a `loop_var` " \
        "that is matching /^(__|{role}_)/ regex.")
    end

    it "flags a with_ lookup at the with_ key's own position" do
      v = role_violations(
        "---\n" \
        "- name: With items lookup\n" \
        "  ansible.builtin.debug:\n" \
        "    msg: \"{{ item }}\"\n" \
        "  with_items:\n" \
        "    - a\n")
      v.map(&.rule_id).must_equal(["loop-var-prefix[missing]"])
      v.first.line.must_equal(5)
      v.first.column.must_equal(3)
    end

    it "reports nothing unless the config enables loop_var_prefix" do
      role_violations(
        "---\n- name: Loop\n  ansible.builtin.debug:\n    msg: \"{{ item }}\"\n  loop:\n    - one\n",
        LintConfig.new).must_be_empty
    end

    it "ignores task files outside a roles/ directory" do
      dir = File.tempname("loopvarprefixspec")
      Dir.mkdir_p(File.join(dir, "mytasks"))
      path = File.join(dir, "mytasks", "main.yml")
      File.write(path, "---\n- name: Loop\n  ansible.builtin.debug:\n    msg: \"{{ item }}\"\n  loop:\n    - one\n")
      file = PositionedFile.load(path)
      violations = [] of Violation
      rule = LoopVarPrefixRule.new
      rule.config = loop_var_config
      rule.check(file, violations)
      violations.must_be_empty
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "treats an empty or Python-falsy loop_var as missing" do
      v = role_violations(
        "---\n" \
        "- name: Empty loop var\n" \
        "  ansible.builtin.debug:\n" \
        "    msg: \"{{ item }}\"\n" \
        "  loop:\n" \
        "    - one\n" \
        "  loop_control:\n" \
        "    loop_var: \"\"\n" \
        "\n" \
        "- name: False loop var\n" \
        "  ansible.builtin.debug:\n" \
        "    msg: \"{{ item }}\"\n" \
        "  loop:\n" \
        "    - one\n" \
        "  loop_control:\n" \
        "    loop_var: false\n")
      v.map(&.line).must_equal([6, 14])
    end

    it "leaves a mismatching loop_var to the wrong arm" do
      v = role_violations(
        "---\n- name: Mismatched loop var\n  ansible.builtin.debug:\n" \
        "    msg: \"{{ thing }}\"\n  loop:\n    - one\n  loop_control:\n" \
        "    loop_var: thing\n")
      v.map(&.rule_id).must_equal(["loop-var-prefix[wrong]"])
    end

    it "reaches the config through the Runner" do
      dir = File.tempname("loopvarprefixspec")
      Dir.mkdir_p(File.join(dir, "roles", "myrole", "tasks"))
      path = File.join(dir, "roles", "myrole", "tasks", "main.yml")
      File.write(path, "---\n- name: Loop\n  ansible.builtin.debug:\n    msg: \"{{ item }}\"\n  loop:\n    - one\n")
      registry = RuleRegistry.new([LoopVarPrefixRule.new] of Rule)
      Runner.new(registry, loop_var_config).run([path]).map(&.rule_id).must_equal(["loop-var-prefix[missing]"])
      Runner.new(registry).run([path]).must_be_empty
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "reads loop_var_prefix from the config file" do
      dir = File.tempname("loopvarprefixspec")
      Dir.mkdir(dir)
      config_path = File.join(dir, ".ansible-lint")
      File.write(config_path, "---\nloop_var_prefix: \"^(__|{role}_)\"\n")
      LintConfig.from_file(config_path).loop_var_prefix.must_equal("^(__|{role}_)")
      LintConfig.new.loop_var_prefix.must_be_nil
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "is registered for --list-rules and the production profile" do
      RuleRegistry.default.find("loop-var-prefix").wont_be_nil
      tags = LoopVarPrefixRule.new.tags
      tags.must_equal(["idiom"])
      # Upstream lists the rule in no profile's rules:list, so it is
      # production-only (--profile min stays silent, verified against
      # ansible-lint 25.2.1) and the summary's row reports the walked
      # profile rather than one of its own.
      Profile.of("loop-var-prefix").must_be_nil
      Profile.of("loop-var-prefix[wrong]").must_be_nil
      Profile.of("loop-var-prefix[missing]").must_be_nil
      Profile.includes?("shared", "loop-var-prefix").must_equal(false)
      Profile.includes?("min", "loop-var-prefix[wrong]").must_equal(false)
      Profile.includes?("production", "loop-var-prefix").must_equal(true)
      Profile.includes?("production", "loop-var-prefix[missing]").must_equal(true)
    end
  end
end
