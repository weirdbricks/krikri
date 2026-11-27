require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe PlaybookExtensionRule do
    private def rule
      PlaybookExtensionRule.new
    end

    private def check(path : String, file_type : FileType = FileType::PLAYBOOK) : Array(Violation)
      file = PositionedFile.new(path, file_type,
        YAML::Nodes.parse("- name: Play\n  hosts: all\n").nodes.first?, nil)
      violations = [] of Violation
      rule.check(file, violations)
      violations
    end

    it "flags a playbook whose extension is not .yml or .yaml" do
      v = check("/tmp/demo.play")
      v.size.must_equal(1)
      v.first.rule_id.must_equal("playbook-extension")
      v.first.message.must_equal(%(Use ".yml" or ".yaml" playbook extension.))
      v.first.severity.must_equal(Severity::MEDIUM)
      v.first.line.must_equal(1)
      v.first.column.must_equal(0)
      v.first.task_line.must_be_nil
    end

    it "flags a playbook with no extension at all" do
      v = check("/tmp/ansible/playbooks/site")
      v.size.must_equal(1)
      v.first.position.must_equal("1")
    end

    it "accepts .yml and .yaml playbooks" do
      check("/tmp/site.yml").must_be_empty
      check("/tmp/site.yaml").must_be_empty
    end

    it "only applies to files classified as playbooks" do
      tasks = PositionedFile.new("/tmp/roles/foo/tasks/main.play",
        FileType::TASKS, nil, nil)
      rule.applies?(tasks).must_equal(false)
    end

    it "reports the file once through the runner" do
      dir = PluginSpecHelper.tmp_path("playbook-extension")
      Dir.mkdir_p(dir)
      path = File.join(dir, "demo.play")
      File.write(path, "- name: Play\n  hosts: all\n  tasks: []\n")
      registry = RuleRegistry.new([rule] of Rule)
      config = LintConfig.new(kinds: [KindPattern.new("playbook", "**/*.play")])
      v = Runner.new(registry, config).run([path])
      v.size.must_equal(1)
      v.first.rule_id.must_equal("playbook-extension")
      v.first.path.must_equal(path)
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "reports nothing for a non-yaml file no kinds entry calls a playbook" do
      # ansible-lint's default kinds only map *.yml/*.yaml, so such a
      # target has no kind and no rule, this one included, applies.
      dir = PluginSpecHelper.tmp_path("playbook-extension-unknown")
      Dir.mkdir_p(dir)
      path = File.join(dir, "demo.play")
      File.write(path, "- name: Play\n  hosts: all\n  tasks: []\n")
      registry = RuleRegistry.new([rule] of Rule)
      Runner.new(registry).run([path]).must_be_empty
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "is registered for --list-rules and the basic profile" do
      RuleRegistry.default.find("playbook-extension").wont_be_nil
      Profile.of("playbook-extension").must_equal("basic")
      rule.tags.must_equal(["formatting"])
    end
  end
end
