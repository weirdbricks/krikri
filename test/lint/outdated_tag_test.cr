require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  LEGACY_NOQA_TASK = "---\n- name: Say hi  # noqa: 301\n" \
                     "  ansible.builtin.debug:\n    msg: hi\n"

  describe OutdatedTagRule do
    private def rule
      OutdatedTagRule.new
    end

    private def lint_tasks(yaml : String, r = rule) : Array(Violation)
      lint_yaml(r, yaml, FileType::TASKS)
    end

    it "flags a legacy noqa tag at the comment's own line" do
      v = lint_tasks(LEGACY_NOQA_TASK)
      v.size.must_equal(1)
      v.first.rule_id.must_equal("warning[outdated-tag]")
      v.first.line.must_equal(2)
      v.first.column.must_equal(0)
      v.first.message.must_equal("Replaced outdated tag '301' with " \
                                 "'no-changed-when', replace it to avoid future errors")
    end

    it "is the warning family upstream's internal rule reports" do
      rule.id.must_equal("warning")
      rule.severity.must_equal(Severity::LOW)
      rule.tags.must_equal(["core", "experimental"])
      rule.unloadable?.must_equal(true)
      rule.suppressible?.must_equal(false)
    end

    it "keeps only the tags ansible-lint 25.2.1 renamed" do
      OutdatedTagRule::RENAMED_TAGS["301"].must_equal("no-changed-when")
      # The bracketed target names are why the match's message carries a
      # literal [/] in both formatters (upstream reads it as markup).
      OutdatedTagRule::RENAMED_TAGS["401"].must_equal("latest[git]")
      OutdatedTagRule::RENAMED_TAGS["unnamed-task"].must_equal("name[missing]")
    end

    it "reports a standalone noqa comment at the file's default line" do
      # Upstream finds a whole-line comment only in the pass that reports
      # line 1, so the comment's real position is not what it prints.
      v = lint_tasks(<<-YAML)
        ---
        - name: Say hi
          ansible.builtin.debug:
            msg: hi

        # noqa: 102
        - name: Say bye
          ansible.builtin.debug:
            msg: bye
        YAML
      v.size.must_equal(1)
      v.first.line.must_equal(1)
      v.first.message.includes?("'no-jinja-when'").must_equal(true)
    end

    it "reports a noqa inside a block scalar at the file's default line" do
      # A block scalar's content is not a comment, so upstream's comment
      # scans never see this one; the per-line pass over the raw file does,
      # and it carries no position: the match lands on the default line 1.
      v = lint_tasks(<<-YAML)
        ---
        - name: Say hi
          ansible.builtin.debug:
            msg: |
              hello # noqa: 301
              world
        YAML
      v.size.must_equal(1)
      v.first.line.must_equal(1)
    end

    it "reports a noqa inside a multi-line quoted scalar at the default line" do
      v = lint_tasks(<<-YAML)
        ---
        - name: Say hi
          ansible.builtin.debug:
            msg: "multi
              line # noqa: 301
              end"
        YAML
      v.size.must_equal(1)
      v.first.line.must_equal(1)
    end

    it "ignores a noqa inside a single-line quoted scalar" do
      # The raw-line pass reads the tag as `301"` - the closing quote is
      # part of the token - which names no rule upstream either.
      lint_tasks(<<-YAML).must_be_empty
        ---
        - name: Say hi
          ansible.builtin.debug:
            msg: "hello # noqa: 301"
        YAML
    end

    it "ignores a noqa comment above the file's first task" do
      # ruamel keeps a document-leading comment out of the comment maps
      # upstream scans, so such a tag is never reported (nor honoured).
      lint_tasks(<<-YAML).must_be_empty
        ---
        # noqa: 305
        - name: Say hi
          ansible.builtin.debug:
            msg: hi
        YAML
    end

    it "reports each legacy tag once per run" do
      v = lint_tasks(<<-YAML)
        ---
        - name: Say hi  # noqa: 301
          ansible.builtin.debug:
            msg: hi
        - name: Say bye  # noqa: 301
          ansible.builtin.debug:
            msg: bye
        YAML
      v.size.must_equal(1)
      v.first.line.must_equal(2)
    end

    it "reads a comma-separated list as one unmapped tag" do
      lint_tasks(<<-YAML).must_be_empty
        ---
        - name: Say hi  # noqa: 301,302
          ansible.builtin.debug:
            msg: hi
        YAML
    end

    it "ignores current tag names and the plain noqa marker" do
      lint_tasks(<<-YAML).must_be_empty
        ---
        - name: Say hi  # noqa: no-changed-when
          ansible.builtin.debug:
            msg: hi
        - name: Say bye  # noqa
          ansible.builtin.debug:
            msg: bye
        YAML
    end

    it "ignores a noqa marker that is not a comment word" do
      lint_tasks(<<-YAML).must_be_empty
        ---
        - name: Say hi  # noqafoo: 301
          ansible.builtin.debug:
            msg: hi
        YAML
    end

    it "renders as a warning through the default warn_list" do
      v = run_rules_yaml(LEGACY_NOQA_TASK, [OutdatedTagRule.new] of Rule)
      v.size.must_equal(1)
      v.first.level.must_equal("warning")
      v.first.warning?.must_equal(true)
    end

    it "stays at the warning level when the warn_list is replaced" do
      # Upstream's unloadable rule has no rule config, so its matches are
      # always drawn as warnings; the warn_list only decides whether they
      # count as failures.
      config = LintConfig.new(warn_list: ["nope"])
      v = run_rules_yaml(LEGACY_NOQA_TASK, [OutdatedTagRule.new] of Rule, config)
      v.first.level.must_equal("warning")
      v.first.warning?.must_equal(false)
    end

    it "is not dropped by a skip_list entry naming its family or tag" do
      ["warning", "experimental"].each do |entry|
        config = LintConfig.new(skip_list: [entry])
        run_rules_yaml(LEGACY_NOQA_TASK, [OutdatedTagRule.new] of Rule, config).size.must_equal(1)
      end
    end

    it "is dropped by a skip_list entry naming its exact tag" do
      # Upstream's last filter drops any match whose own tag is listed,
      # even for the unloadable rule the earlier filters leave alone.
      config = LintConfig.new(skip_list: ["warning[outdated-tag]"])
      run_rules_yaml(LEGACY_NOQA_TASK, [OutdatedTagRule.new] of Rule, config).must_be_empty
    end

    it "is not dropped by a noqa naming its own family" do
      yaml = "---\n- name: Say hi  # noqa: warning 301\n" \
             "  ansible.builtin.debug:\n    msg: hi\n"
      run_rules_yaml(yaml, [OutdatedTagRule.new] of Rule).size.must_equal(1)
    end

    it "runs under the strictest profile too" do
      config = LintConfig.new(profile: "min")
      run_rules_yaml(LEGACY_NOQA_TASK, [OutdatedTagRule.new] of Rule, config).size.must_equal(1)
    end

    it "reports the default line for a file reached as a child" do
      tasks = File.tempname("linttasks", ".yml")
      File.write(tasks, LEGACY_NOQA_TASK)
      registry = RuleRegistry.new([OutdatedTagRule.new] of Rule)
      v = Runner.new(registry).run([tasks], [tasks], Array(String).new, Set(String).new)
      v.size.must_equal(1)
      v.first.line.must_equal(1)
    ensure
      File.delete(tasks) if tasks && File.exists?(tasks)
    end

    it "keeps the comment's line for a file the run was pointed at" do
      tasks = File.tempname("linttasks", ".yml")
      File.write(tasks, LEGACY_NOQA_TASK)
      registry = RuleRegistry.new([OutdatedTagRule.new] of Rule)
      v = Runner.new(registry).run([tasks], [tasks], Array(String).new, Set{tasks})
      v.size.must_equal(1)
      v.first.line.must_equal(2)
    ensure
      File.delete(tasks) if tasks && File.exists?(tasks)
    end

    it "prints a renamed tag's brackets the way upstream's markup does" do
      v = lint_tasks("---\n- name: Say hi  # noqa: 402\n" \
                     "  ansible.builtin.debug:\n    msg: hi\n").first
      message = "Replaced outdated tag '402' with 'latest[hg]', " \
                "replace it to avoid future errors"
      Formatter.brief(v, false).must_equal(
        "warning[outdated-tag]: #{message}[/] (warning)\n#{v.path}:2\n")
      Formatter.parseable(v, false).must_equal(
        "#{v.path}:2: warning[outdated-tag]: #{message}[/] (warning)")
      Formatter.parseable(v, true).must_equal(
        String.build do |io|
          io << Console::MAGENTA << v.path << Console::RESET
          io << Console::DIM << ":2:" << Console::RESET
          io << ' ' << Console::YELLOW << Console::BOLD
          io << "warning[outdated-tag]" << Console::RESET
          io << ": #{message}[/]"
          io << ' ' << Console::DIM << Console::YELLOW << "(warning)"
          io << Console::RESET * 3
        end)
    end
  end
end
