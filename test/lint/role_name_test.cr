require "../minitest_helper"
require "file_utils"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe RoleNameRule do
    private def rule
      RoleNameRule.new
    end

    # A role-shaped directory (tasks/ present, so kind detection calls
    # it a role), optionally with a meta/main.yml.
    private def with_role(dir_name : String, meta : String? = nil, &)
      root = File.tempname("rolenamespec")
      Dir.mkdir(root)
      dir = File.join(root, dir_name)
      Dir.mkdir(dir)
      tasks = File.join(dir, "tasks")
      Dir.mkdir(tasks)
      File.write(File.join(tasks, "main.yml"),
        "---\n- name: Say hi\n  ansible.builtin.debug:\n    msg: hi\n")
      if meta
        meta_dir = File.join(dir, "meta")
        Dir.mkdir(meta_dir)
        File.write(File.join(meta_dir, "main.yml"), meta)
      end
      yield dir
    ensure
      FileUtils.rm_rf(root) if root
    end

    private def violations_for(dir : String) : Array(Violation)
      file = PositionedFile.new(dir, FileType::ROLE, nil, nil)
      violations = [] of Violation
      rule.check(file, violations)
      violations
    end

    it "flags a role directory whose name does not match the pattern" do
      with_role("Bad_Role") do |dir|
        v = violations_for(dir)
        v.size.must_equal(1)
        violation = v.first
        violation.path.must_equal(dir)
        violation.line.must_equal(1)
        violation.column.must_equal(0)
        violation.rule_id.must_equal("role-name")
        violation.message.must_equal(
          "Role name Bad_Role does not match ``^[a-z][a-z0-9_]*$`` pattern.")
      end
    end

    it "declares upstream's severity, tags and lintable kinds" do
      rule.severity.must_equal(Severity::HIGH)
      rule.tags.must_equal(["deprecations", "metadata"])
      rule.applies_to.must_equal(FileType.values)
      rule.role_lintable?.must_equal(true)
    end

    it "accepts lowercase letter, digit and underscore names" do
      with_role("my_role2") do |dir|
        violations_for(dir).must_be_empty
      end
    end

    it "prefers meta/main.yml's galaxy_info.role_name over the directory name" do
      meta = "---\ngalaxy_info:\n  role_name: Bad-Role-Name\n"
      with_role("good_name", meta) do |dir|
        v = violations_for(dir)
        v.size.must_equal(1)
        v.first.message.must_equal(
          "Role name Bad-Role-Name does not match ``^[a-z][a-z0-9_]*$`` pattern.")
      end
    end

    it "accepts a meta-derived name that matches the pattern" do
      meta = "---\ngalaxy_info:\n  role_name: fine_name\n"
      with_role("Bad-Name", meta) do |dir|
        violations_for(dir).must_be_empty
      end
    end

    it "strips a leading ansible-role- repository prefix" do
      with_role("ansible-role-my_role") do |dir|
        violations_for(dir).must_be_empty
      end
    end

    it "lints a role directory only when it is an explicit target" do
      with_role("Bad_Role") do |dir|
        files = FileDiscovery.discover([dir])
        FileDiscovery.role_targets([dir]).must_equal([dir])
        walked = Runner.new(RuleRegistry.default).run(files, [dir])
        walked.none? { |v| v.rule_id == "role-name" }.must_equal(true)
        targeted = Runner.new(RuleRegistry.default)
          .run(files, [dir], FileDiscovery.role_targets([dir]))
        targeted.count { |v| v.rule_id == "role-name" }.must_equal(1)
      end
    end

    it "flags a play's roles: string entry at the play mapping" do
      v = lint_yaml(rule, <<-YAML)
        - name: Role path repro
          hosts: all
          roles:
            - roles/bad_role
        YAML
      v.size.must_equal(1)
      v[0].line.must_equal(1)
      v[0].column.must_equal(3)
      v[0].rule_id.must_equal("role-name[path]")
      v[0].severity.must_equal(Severity::HIGH)
      v[0].message.must_equal("Avoid using paths when importing roles. (roles/bad_role)")
      v[0].task_line.must_be_nil
    end

    it "flags a roles: mapping entry at that mapping" do
      v = lint_yaml(rule, <<-YAML)
        - name: Role path repro
          hosts: all
          roles:
            - role: roles/bad_role
        YAML
      v.size.must_equal(1)
      v[0].line.must_equal(4)
      v[0].column.must_equal(7)
      v[0].message.must_equal("Avoid using paths when importing roles. (roles/bad_role)")
    end

    it "flags include_role and import_role tasks at the task line, without a column" do
      v = lint_yaml(rule, <<-YAML)
        - name: Role path repro
          hosts: all
          tasks:
            - name: Include a role by path
              ansible.builtin.include_role:
                name: roles/bad_role
            - name: Import a role by path
              import_role:
                name: roles/bad_role
        YAML
      v.size.must_equal(2)
      v.map { |violation| {violation.line, violation.column} }.must_equal([{4, 0}, {7, 0}])
      v.each do |violation|
        violation.message.must_equal("Avoid using paths when importing roles. (roles/bad_role)")
        violation.task_line.must_equal(violation.line)
      end
    end

    it "flags meta dependencies at the role value, mapping and string forms" do
      v = lint_yaml(rule, <<-YAML, FileType::META)
        dependencies:
          - role: ../bar
          - ../baz
        YAML
      v.size.must_equal(2)
      v.map { |violation| {violation.line, violation.column} }.must_equal([{2, 11}, {3, 5}])
      v.map(&.message).must_equal([
        "Avoid using paths when importing roles. (../bar)",
        "Avoid using paths when importing roles. (../baz)",
      ])
      v[0].task_line.must_be_nil
    end

    it "ignores role imports by name and modules outside the role-import set" do
      v = lint_yaml(rule, <<-YAML)
        - name: Role path repro
          hosts: all
          roles:
            - bad_role
          tasks:
            - name: Import a role by name
              include_role:
                name: bad_role
            - name: A collection's include_role is not in upstream's set
              community.general.include_role:
                name: roles/bad_role
        YAML
      v.must_be_empty
    end

    it "leaves an unrelated file alone" do
      v = lint_yaml(rule, <<-YAML, FileType::META)
        galaxy_info:
          role_name: roles/bad_role
        dependencies: []
        YAML
      v.must_be_empty
    end

    it "is registered for --list-rules and the profile lookups" do
      RuleRegistry.default.find("role-name").wont_be_nil
    end
  end
end
