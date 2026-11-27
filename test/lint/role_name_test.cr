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

    it "declares upstream's severity, tags and lintable kind" do
      rule.severity.must_equal(Severity::HIGH)
      rule.tags.must_equal(["deprecations", "metadata"])
      rule.applies_to.must_equal([FileType::ROLE])
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
  end
end
