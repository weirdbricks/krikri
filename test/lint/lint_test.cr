require "../minitest_helper"
require "file_utils"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe PositionedFile do
    it "parses a valid file and exposes position data" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- name: x\n  apt:\n    state: present\n")
      begin
        file = PositionedFile.load(path)
        file.parse_error.must_be_nil
        root = file.root.as(YAML::Nodes::Node)
        root.must_be_instance_of(YAML::Nodes::Sequence)
        first = root.as(YAML::Nodes::Sequence).nodes.first
        NodeUtil.line(first).must_equal(2)
        NodeUtil.column(first).must_equal(3)
      ensure
        File.delete(path)
      end
    end

    it "captures parse errors with line/column" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "tasks:\n  - name: bad\n  [oops\n")
      begin
        file = PositionedFile.load(path)
        file.root.must_be_nil
        err = file.parse_error.as(PositionedFile::ParseErrorInfo)
        expect((err.line) > (0)).must_equal(true)
      ensure
        File.delete(path)
      end
    end

    it "classifies role file types from path" do
      FileType.from_path("roles/foo/tasks/main.yml").must_equal(FileType::TASKS)
      FileType.from_path("roles/foo/handlers/main.yml").must_equal(FileType::HANDLERS)
      FileType.from_path("roles/foo/meta/main.yml").must_equal(FileType::META)
      FileType.from_path("site.yml").must_equal(FileType::PLAYBOOK)
    end
  end

  describe NodeUtil do
    it "iterates mapping entries from the flat node list" do
      parsed = YAML::Nodes.parse("a: 1\nb: two\n")
      mapping = parsed.nodes.first.as(YAML::Nodes::Mapping)
      keys = [] of String
      NodeUtil.each_entry(mapping) do |k, v|
        keys << "#{NodeUtil.scalar_value(k)}=#{NodeUtil.scalar_value(v)}"
      end
      keys.must_equal(["a=1", "b=two"])
    end

    it "finds an entry by key" do
      parsed = YAML::Nodes.parse("name: hello\napt: {}\n")
      mapping = parsed.nodes.first.as(YAML::Nodes::Mapping)
      found = NodeUtil.entry(mapping, "name").as({YAML::Nodes::Node, YAML::Nodes::Node})
      NodeUtil.scalar_value(found[1]).must_equal("hello")
      NodeUtil.entry(mapping, "missing").must_be_nil
    end
  end

  describe FileDiscovery do
    it "finds yaml files recursively, skipping non-lintable dirs" do
      dir = File.tempname("lintdisc")
      Dir.mkdir(dir)
      Dir.mkdir(File.join(dir, "tasks"))
      Dir.mkdir(File.join(dir, "files"))
      File.write(File.join(dir, "play.yml"), "---\n")
      File.write(File.join(dir, "tasks", "main.yaml"), "---\n")
      File.write(File.join(dir, "files", "skip.yml"), "---\n")
      File.write(File.join(dir, "ignored.txt"), "x")
      begin
        FileDiscovery.discover([dir]).sort.must_equal([
          File.join(dir, "play.yml"),
          File.join(dir, "tasks", "main.yaml"),
        ])
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "accepts a single file target as-is" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n")
      begin
        FileDiscovery.discover([path]).must_equal([path])
      ensure
        File.delete(path)
      end
    end

    it "reports a missing target instead of exiting" do
      dir = File.tempname("lintdisc")
      Dir.mkdir(dir)
      begin
        missing = FileDiscovery.missing_targets([File.join(dir, "gone.yml")])
        missing.must_equal([File.join(dir, "gone.yml")])
        FileDiscovery.discover([File.join(dir, "gone.yml")]).must_be_empty
        FileDiscovery.missing_targets([dir]).must_be_empty
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end

  describe LoadFailureRule do
    private def rule
      LoadFailureRule.new
    end

    it "reports a parse failure as a warning-level load-failure on line 1" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "tasks:\n  - name: bad\n  [oops\n")
      begin
        file = PositionedFile.load(path)
        violations = [] of Violation
        rule.check(file, violations)
        violations.size.must_equal(1)
        v = violations.first
        v.rule_id.must_equal("load-failure[runtimeerror]")
        v.line.must_equal(1)
        v.column.must_equal(0)
        v.level.must_equal("warning")
        v.warning?.must_equal(false) # still counts as a failure
        v.message.must_equal("Failed to load YAML file: #{File.expand_path(path)}")
      ensure
        File.delete(path)
      end
    end

    it "stays silent on a clean or empty file" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "")
      begin
        file = PositionedFile.load(path)
        violations = [] of Violation
        rule.check(file, violations)
        violations.must_be_empty
      ensure
        File.delete(path)
      end
    end
  end

  describe Outcome do
    it "breaks same-position ties by rule id, like upstream" do
      a = Violation.new("p.yml", 9, 0, "no-changed-when", Severity::HIGH, "m")
      b = Violation.new("p.yml", 9, 0, "name[missing]", Severity::MEDIUM, "m")
      c = Violation.new("p.yml", 9, 0, "command-instead-of-shell", Severity::HIGH, "m")
      Outcome.sort([a, b, c]).map(&.rule_id).must_equal([
        "command-instead-of-shell", "name[missing]", "no-changed-when",
      ])
    end

    it "keeps a missing target's load-failure pair in upstream order" do
      a = Violation.new("gone.yml", 1, 0, "load-failure[filenotfounderror]", Severity::VERY_HIGH, "m", nil, false, "None", "warning")
      b = Violation.new("gone.yml", 1, 0, "load-failure[not-found]", Severity::VERY_HIGH, "m", nil, false, "", "warning")
      Outcome.sort([a, b]).map(&.rule_id).must_equal([
        "load-failure[not-found]", "load-failure[filenotfounderror]",
      ])
    end

    it "only reports skippable rules as printable ignore-docs targets" do
      registry = RuleRegistry.default
      load_failure = [Violation.new("gone.yml", 1, 0, "load-failure[not-found]",
        Severity::VERY_HIGH, "m", nil, false, "", "warning")]
      Outcome.skippable?(load_failure, registry).must_equal(false)
      yaml = [Violation.new("a.yml", 1, 0, "yaml[colons]", Severity::LOW, "m")]
      Outcome.skippable?(yaml, registry).must_equal(true)
    end
  end

  describe RuleRegistry do
    it "lists rules with ids" do
      registry = RuleRegistry.default
      registry.find("load-failure").wont_be_nil
      registry.find("nope").must_be_nil
    end
  end

  describe Runner do
    it "collects violations across targets" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "  [broken\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([path])
        violations.size.must_equal(1)
      ensure
        File.delete(path)
      end
    end

    it "describes a task-scoped match with its task, like upstream" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- name: Play\n  hosts: localhost\n  tasks:\n" \
                        + "    - name: Install pkg\n      ansible.builtin.apt:\n" \
                           + "        name: nginx\n        state: latest\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([path])
        latest = violations.find { |v| v.rule_id == "package-latest" }
        raise "no package-latest violation" unless latest
        latest.details.must_equal("Task/Handler: Install pkg")
      ensure
        File.delete(path)
      end
    end

    it "leaves file-level matches without a task detail" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- name:  Play\n  hosts: localhost\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([path])
        yaml_match = violations.find { |v| v.rule_id == "yaml[colons]" }
        raise "no yaml[colons] violation" unless yaml_match
        yaml_match.details.must_equal("")
      ensure
        File.delete(path)
      end
    end

    it "falls back to the module and free-form args for an unnamed task" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- hosts: localhost\n  tasks:\n    - import_tasks: tasks/x.yml\n")
      begin
        file = PositionedFile.load(path)
        task = TaskWalker.collect_tasks(file).first
        raise "no task found" unless task
        task.display_name.must_equal("import_tasks tasks/x.yml")
      ensure
        File.delete(path)
      end
    end

    it "renders an argumentless unnamed task with upstream's trailing space" do
      # Upstream joins f"{module} {' '.join(args)}", so the space after
      # the module stays even with no arguments. Verified against
      # ansible-lint 25.2.1: "Task/Handler: ping ".
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- hosts: localhost\n  tasks:\n    - ping:\n")
      begin
        file = PositionedFile.load(path)
        task = TaskWalker.collect_tasks(file).first
        raise "no task found" unless task
        task.display_name.must_equal("ping ")
      ensure
        File.delete(path)
      end
    end

    it "attaches the trailing-space detail to an unnamed task's matches" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- hosts: localhost\n  tasks:\n    - ansible.builtin.ping:\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([path])
        missing = violations.find { |v| v.rule_id == "name[missing]" }
        raise "no name[missing] violation" unless missing
        missing.details.must_equal("Task/Handler: ping ")
      ensure
        File.delete(path)
      end
    end
  end
end
