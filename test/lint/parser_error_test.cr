require "../minitest_helper"
require "file_utils"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe ParserErrorRule do
    private def rule
      ParserErrorRule.new
    end

    # A path ansible-lint loads as a task list (its kind detection reads
    # the `tasks/` directory), so the rule and the runner's gate both
    # see FileType::TASKS the way they do for a role.
    private def lint_tasks(yaml : String) : PositionedFile
      dir = PluginSpecHelper.tmp_path("lint_parser_error") + "/roles/r/tasks"
      FileUtils.mkdir_p(dir)
      path = dir + "/main.yml"
      File.write(path, yaml)
      PositionedFile.load(path)
    end

    it "reports a task with no action at the task mapping's start" do
      # ansible-lint 25.2.1 on this file: 1:3 parser-error
      # "no module/action detected in task." - the task mapping's first
      # key, so `- ` puts the column at 3.
      file = lint_tasks("- name: no action at all\n  become: true\n")
      violations = [] of Violation
      rule.check(file, violations)
      violations.size.must_equal(1)
      v = violations.first
      v.rule_id.must_equal("parser-error")
      {v.line, v.column}.must_equal({1, 3})
      v.message.must_equal("no module/action detected in task.")
      v.level.must_equal("warning")
      v.warning?.must_equal(false) # still counts as a failure
    end

    it "reports a second action key as Ansible's conflicting-action error" do
      # ansible-lint 25.2.1: "conflicting action statements:
      # ansible.builtin.command, ansible.builtin.shell".
      file = lint_tasks("---\n- name: two actions\n  ansible.builtin.command: echo one\n" \
                         + "  ansible.builtin.shell: echo two\n")
      violations = [] of Violation
      rule.check(file, violations)
      violations.size.must_equal(1)
      violations.first.message.must_equal(
        "conflicting action statements: ansible.builtin.command, ansible.builtin.shell")
    end

    it "reports action and local_action as mutually exclusive" do
      file = lint_tasks("---\n- name: both\n  action: command echo one\n" \
                         + "  local_action: command echo two\n")
      violations = [] of Violation
      rule.check(file, violations)
      violations.size.must_equal(1)
      violations.first.message.must_equal("action and local_action are mutually exclusive")
    end

    it "reports an action value ModuleArgsParser cannot normalize" do
      # A lone action whose value is a list is neither a string nor a
      # mapping, so the load aborts naming the value's tagged class
      # (verified against ansible-lint 25.2.1: 2:3 here, because the
      # document marker puts the task mapping on line 2).
      file = lint_tasks("---\n- name: list action value\n  ansible.builtin.command:\n" \
                         + "    - echo one\n")
      violations = [] of Violation
      rule.check(file, violations)
      violations.size.must_equal(1)
      v = violations.first
      {v.line, v.column}.must_equal({2, 3})
      v.message.must_equal("unexpected parameter type in action: " \
                           "<class 'ansible.module_utils._internal._datatag._AnsibleTaggedList'>")
    end

    it "names the action statement's own module first when a module conflicts with it" do
      # `action: copy` names the module, so the conflict reads "copy,
      # ansible.builtin.command" (ansible-lint 25.2.1).
      file = lint_tasks("---\n- name: mixed\n  action: copy\n" \
                         + "  ansible.builtin.command: echo one\n")
      violations = [] of Violation
      rule.check(file, violations)
      violations.first.message.must_equal(
        "conflicting action statements: copy, ansible.builtin.command")
    end

    it "leaves a task parsed through action:/local_action: alone" do
      file = lint_tasks("---\n- name: old style\n  action: command echo hi\n")
      violations = [] of Violation
      rule.check(file, violations)
      violations.must_be_empty
    end

    it "reports only the first offending task" do
      # Ansible stops at the first ModuleArgsParser failure, so a file
      # never reports more than one (ansible-lint 25.2.1).
      file = lint_tasks("---\n- name: one\n  become: true\n- name: two\n  become: false\n")
      violations = [] of Violation
      rule.check(file, violations)
      violations.size.must_equal(1)
      violations.first.line.must_equal(2)
    end

    it "ignores tasks an Ansible load never reads as a task list" do
      # A loose yaml file is not a task lintable upstream, so its task
      # shapes are never parsed.
      path = File.tempname("lintrule", ".yml")
      File.write(path, "---\n- name: no action at all\n  become: true\n")
      begin
        file = PositionedFile.new(path, FileType::PLAYBOOK,
          YAML::Nodes.parse(File.read(path)).nodes.first?, nil)
        violations = [] of Violation
        rule.check(file, violations)
        violations.must_be_empty
      ensure
        File.delete(path)
      end
    end

    it "lets no task-level rule report on the file" do
      # Upstream abandons the task pipeline on the first parse failure:
      # no name[casing] for the offending task and no no-changed-when for
      # a good one in the same file (verified against ansible-lint
      # 25.2.1).
      file = lint_tasks("---\n- name: lowercase name\n  ansible.builtin.command: echo hi\n" \
                         + "- name: no action at all\n  become: true\n")
      violations = Runner.new(RuleRegistry.default).run([file.path])
      violations.map(&.rule_id).must_equal(["parser-error"])
    end

    it "keeps the YAML-level matches a parser failure leaves standing" do
      # Upstream raises the match out of the task pipeline only, so the
      # file's yamllint rules still report what they find (verified
      # against ansible-lint 25.2.1).
      file = lint_tasks("- name: no action at all   \n  become: true\n")
      violations = Runner.new(RuleRegistry.default).run([file.path])
      violations.map(&.rule_id).must_equal(["parser-error", "yaml[trailing-spaces]"])
    end

    it "reports nothing when --tags loads no rule to raise it" do
      # The match comes from whichever rule the run loaded, and opt-in
      # rules need --enable-list, so this filter runs nothing but the
      # internal warning family; upstream prints nothing for that run
      # (verified against ansible-lint 25.2.1).
      file = lint_tasks("- name: no action at all\n  become: true\n")
      config = LintConfig.new(tags: ["opt-in"])
      Runner.new(RuleRegistry.default, config).run([file.path]).must_be_empty
    end

    it "still reports the match when --tags filtered the rule itself out" do
      # `-t yaml` skips the parser-error rule but loads the yaml rules,
      # which raise the match on their way through the task pipeline
      # (verified against ansible-lint 25.2.1).
      file = lint_tasks("- name: no action at all\n  become: true\n")
      config = LintConfig.new(tags: ["yaml"])
      Runner.new(RuleRegistry.default, config).run([file.path]).map(&.rule_id)
        .must_equal(["parser-error"])
    end

    it "is not suppressible with a # noqa comment" do
      # Upstream builds `# noqa` skips from a task's normalized form, and
      # the rejected task never gets one, so the match always shows
      # (verified against ansible-lint 25.2.1).
      file = lint_tasks("- name: no action at all  # noqa: parser-error\n  become: true\n")
      violations = Runner.new(RuleRegistry.default).run([file.path])
      violations.map(&.rule_id).must_equal(["parser-error"])
    end

    it "ignores a skip_list entry naming the rule's category" do
      # Only an entry naming the rule itself reaches the match; the core
      # tag does not (verified against ansible-lint 25.2.1).
      file = lint_tasks("- name: no action at all\n  become: true\n")
      Runner.new(RuleRegistry.default, LintConfig.new(skip_list: ["core"]))
        .run([file.path]).map(&.rule_id).must_equal(["parser-error"])
      Runner.new(RuleRegistry.default, LintConfig.new(skip_list: ["parser-error"]))
        .run([file.path]).must_be_empty
    end

    it "is registered for --list-rules and the profile lookups" do
      rule = RuleRegistry.default.find("parser-error")
      raise "parser-error is not registered" unless rule
      rule.tags.must_equal(["core"])
      rule.severity.must_equal(Severity::VERY_HIGH)
    end
  end
end
