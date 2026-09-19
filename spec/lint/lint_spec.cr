require "../spec_helper"
require "file_utils"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe PositionedFile do
    it "parses a valid file and exposes position data" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- name: x\n  apt:\n    state: present\n")
      begin
        file = PositionedFile.load(path)
        file.parse_error.should be_nil
        root = file.root.should_not be_nil
        root.should be_a(YAML::Nodes::Sequence)
        first = root.as(YAML::Nodes::Sequence).nodes.first
        NodeUtil.line(first).should eq(2)
        NodeUtil.column(first).should eq(3)
      ensure
        File.delete(path)
      end
    end

    it "captures parse errors with line/column" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "tasks:\n  - name: bad\n  [oops\n")
      begin
        file = PositionedFile.load(path)
        file.root.should be_nil
        err = file.parse_error.should_not be_nil
        err.line.should be > 0
      ensure
        File.delete(path)
      end
    end

    it "classifies role file types from path" do
      FileType.from_path("roles/foo/tasks/main.yml").should eq(FileType::TASKS)
      FileType.from_path("roles/foo/handlers/main.yml").should eq(FileType::HANDLERS)
      FileType.from_path("roles/foo/meta/main.yml").should eq(FileType::META)
      FileType.from_path("site.yml").should eq(FileType::PLAYBOOK)
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
      keys.should eq(["a=1", "b=two"])
    end

    it "finds an entry by key" do
      parsed = YAML::Nodes.parse("name: hello\napt: {}\n")
      mapping = parsed.nodes.first.as(YAML::Nodes::Mapping)
      found = NodeUtil.entry(mapping, "name").should_not be_nil
      NodeUtil.scalar_value(found[1]).should eq("hello")
      NodeUtil.entry(mapping, "missing").should be_nil
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
        FileDiscovery.discover([dir]).sort.should eq([
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
        FileDiscovery.discover([path]).should eq([path])
      ensure
        File.delete(path)
      end
    end
  end

  describe SyntaxCheckRule do
    rule = SyntaxCheckRule.new

    it "reports a syntax error at the failing line" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "tasks:\n  - name: bad\n  [oops\n")
      begin
        file = PositionedFile.load(path)
        violations = [] of Violation
        rule.check(file, violations)
        violations.size.should eq(1)
        v = violations.first
        v.rule_id.should eq("syntax-check")
        v.path.should eq(path)
        v.line.should eq(4)
      ensure
        File.delete(path)
      end
    end

    it "reports an empty file" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "")
      begin
        file = PositionedFile.load(path)
        violations = [] of Violation
        rule.check(file, violations)
        violations.size.should eq(1)
        violations.first.line.should eq(1)
      ensure
        File.delete(path)
      end
    end

    it "stays silent on a clean file" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "---\n- name: ok\n")
      begin
        file = PositionedFile.load(path)
        violations = [] of Violation
        rule.check(file, violations)
        violations.should be_empty
      ensure
        File.delete(path)
      end
    end
  end

  describe RuleRegistry do
    it "lists rules with ids" do
      registry = RuleRegistry.default
      registry.find("syntax-check").should_not be_nil
      registry.find("nope").should be_nil
    end
  end

  describe Runner do
    it "collects violations across targets" do
      path = File.tempname("lintspec", ".yml")
      File.write(path, "  [broken\n")
      begin
        violations = Runner.new(RuleRegistry.default).run([path])
        violations.size.should eq(1)
      ensure
        File.delete(path)
      end
    end
  end
end
