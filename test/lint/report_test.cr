require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  # The exact escape sequences matter: these assertions are the byte-level
  # contract with ansible-lint's default, parseable and quiet output.
  describe Formatter do
    private def violation(**kwargs)
      Violation.new(
        kwargs[:path]? || "test-node.yml",
        kwargs[:line]? || 64,
        kwargs[:column]? || 0,
        kwargs[:rule_id]? || "yaml[commas]",
        Severity::LOW,
        kwargs[:message]? || "Too many spaces after comma",
        nil,
        kwargs[:warning]? || false,
        kwargs[:details]? || ""
      )
    end

    it "renders a colored error block like upstream" do
      Formatter.brief(violation, true).must_equal(
        "\e[31m\e[34m\e]8;;https://ansible.readthedocs.io/projects/lint/rules/yaml/" \
        "\e\\yaml[commas]\e]8;;\e\\\e[0m\e[2m:\e[0m \e[31mToo many spaces after comma\e[0m\n" \
        "\e[35mtest-node.yml\e[0m:64\n\e[0m"
      )
    end

    it "renders a plain error block like upstream" do
      Formatter.brief(violation, false).must_equal(
        "yaml[commas]: Too many spaces after comma\ntest-node.yml:64\n"
      )
    end

    it "appends the task description dimmed" do
      Formatter.brief(violation(rule_id: "package-latest", line: 336,
        message: "Package installs should not use latest.",
        details: "Task/Handler: Install dirless-syncer"), true).must_equal(
        "\e[31m\e[34m\e]8;;https://ansible.readthedocs.io/projects/lint/rules/package-latest/" \
        "\e\\package-latest\e]8;;\e\\\e[0m\e[2m:\e[0m \e[31mPackage installs should not use latest.\e[0m\n" \
        "\e[35mtest-node.yml\e[0m:336 \e[2mTask/Handler: Install dirless-syncer\e[0m\n\e[0m"
      )
    end

    it "marks warnings yellow and closes two tags at the end" do
      Formatter.brief(violation(warning: true), true).must_equal(
        "\e[33m\e[34m\e]8;;https://ansible.readthedocs.io/projects/lint/rules/yaml/" \
        "\e\\yaml[commas]\e]8;;\e\\\e[0m\e[2m:\e[0m \e[33mToo many spaces after comma\e[0m " \
        "\e[2m\e[33m(warning)\e[0m\n\e[35mtest-node.yml\e[0m:64\n\e[0m\e[0m"
      )
      Formatter.brief(violation(warning: true), false).must_equal(
        "yaml[commas]: Too many spaces after comma (warning)\ntest-node.yml:64\n"
      )
    end

    it "renders the parseable layout" do
      # Upstream parses the rule id as markup, so a word-only sub-tag
      # swallows the `[/]` that would have closed the bold tag.
      Formatter.parseable(violation(column: 3), true).must_equal(
        "\e[35mtest-node.yml\e[0m\e[2m:64:3:\e[0m \e[31m\e[1myaml[commas][/]" \
        ": Too many spaces after comma\e[0m\e[0m"
      )
      Formatter.parseable(violation, false).must_equal(
        "test-node.yml:64: yaml[commas][/]: Too many spaces after comma"
      )
    end

    it "appends (warning) to parseable warning lines like upstream" do
      Formatter.parseable(violation(rule_id: "no-changed-when", warning: true), true).must_equal(
        "\e[35mtest-node.yml\e[0m\e[2m:64:\e[0m \e[33m\e[1mno-changed-when\e[0m" \
        ": Too many spaces after comma\e[0m \e[2m\e[33m(warning)\e[0m\e[0m"
      )
      Formatter.parseable(violation(rule_id: "no-changed-when", warning: true), false).must_equal(
        "test-node.yml:64: no-changed-when: Too many spaces after comma (warning)"
      )
    end

    it "adds a third reset for sub-tagged parseable warnings like upstream" do
      Formatter.parseable(violation(warning: true), true).must_equal(
        "\e[35mtest-node.yml\e[0m\e[2m:64:\e[0m \e[33m\e[1myaml[commas][/]" \
        ": Too many spaces after comma\e[0m\e[0m \e[2m\e[33m(warning)\e[0m\e[0m\e[0m"
      )
    end

    it "leaves a hyphenated sub-tag alone, as upstream's parser does" do
      v = violation(rule_id: "yaml[new-line-at-end-of-file]",
        message: "No new line character at the end of file")
      Formatter.parseable(v, true).must_equal(
        "\e[35mtest-node.yml\e[0m\e[2m:64:\e[0m \e[31m\e[1myaml[new-line-at-end-of-file]\e[0m" \
        ": No new line character at the end of file\e[0m"
      )
      Formatter.parseable(v, false).must_equal(
        "test-node.yml:64: yaml[new-line-at-end-of-file]: No new line character at the end of file"
      )
    end

    it "renders the schema blurb's quoted sub-tags like upstream" do
      v = violation(rule_id: "schema[meta]", message: "$.x is a required property.",
        details: "see ``schema[playbook]``\nfor details.\n")
      Formatter.brief(v, true).must_equal(
        "\e[31m\e[34m\e]8;;https://ansible.readthedocs.io/projects/lint/rules/schema/" \
        "\e\\schema[meta]\e]8;;\e\\\e[0m\e[2m:\e[0m \e[31m$.x is a required property.\e[0m\n" \
        "\e[35mtest-node.yml\e[0m:64 \e[2msee ``schema[playbook]``\nfor details.\n[/]\n" \
        "\e[0m\e[0m"
      )
    end

    it "renders the quiet layout off the rule family" do
      Formatter.quiet(violation, false).must_equal("yaml test-node.yml:64")
      Formatter.quiet(violation, true).must_equal(
        "\e[31myaml\e[0m \e[35mtest-node.yml\e[0m:64"
      )
    end
  end

  describe Report do
    private def report(violations, files_count = 1, profile = nil, modified_files = 0)
      Report.new(violations, RuleRegistry.default, files_count, profile, modified_files)
    end

    private def pkg_violation(warning = false)
      Violation.new("warn.yml", 5, 0, "package-latest", Severity::VERY_LOW,
        "Package installs should not use latest.", 4, warning)
    end

    it "builds the table and the outcome line like upstream" do
      report([pkg_violation]).lines(false).must_equal([
        "",
        "# Rule Violation Summary",
        "",
        "  1 package-latest profile:safety tags:idempotency",
        "",
        "Failed: 1 failure(s), 0 warning(s) on 1 files. " \
        "Last profile that met the validation criteria was 'moderate'. Rating: 2/5 star",
      ])
    end

    it "hyperlinks and dims the colored table" do
      report([pkg_violation]).lines(true).must_equal([
        "",
        "# Rule Violation Summary",
        "",
        "  1 \e[34m\e]8;;https://ansible.readthedocs.io/projects/lint/rules/" \
        "\e\\package-latest\e]8;;\e\\\e[0m \e[2mprofile:safety tags:idempotency\e[0m",
        "",
        "\e[31m\e[1mFailed\e[0m\e[0m: 1 failure(s), 0 warning(s) on 1 files. " \
        "Last profile that met the validation criteria was 'moderate'. Rating: 2/5 star",
      ])
    end

    it "reports the first failing profile on every row, as upstream does" do
      lines = report([pkg_violation, Violation.new("t.yml", 1, 0, "yaml[colons]",
        Severity::LOW, "Too many spaces after colon", nil)]
      ).lines(false)
      lines[3].must_include("profile:basic")
      lines[4].must_include("profile:basic")
    end

    it "passes when every violation is a warning" do
      summary = report([pkg_violation(true)], 1)
      summary.failures.must_equal(0)
      summary.warnings.must_equal(1)
      summary.lines(false).last.starts_with?("Passed: 0 failure(s), 1 warning(s)").must_equal(true)
    end

    it "reports the required profile when one was asked for" do
      report([pkg_violation], 1, "production").lines(false).last.must_equal(
        "Failed: 1 failure(s), 0 warning(s) on 1 files. Profile 'production' was required, " \
        "but 'moderate' profile passed. Rating: 2/5 star"
      )
    end

    it "reports a clean run without a table or a rating" do
      report([] of Violation, 2).lines(false).must_equal([
        "",
        "Passed: 0 failure(s), 0 warning(s) on 2 files. " \
        "Last profile that met the validation criteria was 'production'.",
      ])
    end

    it "prints a plain Modified line after the leading blank, before the table" do
      report([pkg_violation], 1, nil, 1).lines(false).must_equal([
        "",
        "Modified 1 files.",
        "# Rule Violation Summary",
        "",
        "  1 package-latest profile:safety tags:idempotency",
        "",
        "Failed: 1 failure(s), 0 warning(s) on 1 files. " \
        "Last profile that met the validation criteria was 'moderate'. Rating: 2/5 star",
      ])
    end

    it "never appends the fixed-issues clause, like upstream's CLI" do
      # Upstream's app.py has an `if summary.fixed` branch, but its fix()
      # pops fixed matches from the result before count_results runs, so
      # the ", and fixed N issue(s)" clause can never be reached (verified
      # against ansible-lint 25.2.1 with --fix). krikri drops fixed
      # matches the same way and must not print the clause either.
      lines = report([pkg_violation], 1, nil, 1).lines(false)
      lines.join("\n").wont_match(/and fixed/)
      lines.last.must_equal(
        "Failed: 1 failure(s), 0 warning(s) on 1 files. " \
        "Last profile that met the validation criteria was 'moderate'. Rating: 2/5 star"
      )
    end

    it "prints the Modified line in colored mode without markup of its own" do
      lines = report([pkg_violation], 1, nil, 2).lines(true)
      lines[1].must_equal("Modified 2 files.")
    end

    it "omits the Modified line when no file was rewritten" do
      report([pkg_violation], 1, nil, 0).lines(false)[1].must_equal("# Rule Violation Summary")
    end

    it "counts yaml sub-tags separately, ordered by profile position" do
      lines = report([
        Violation.new("t.yml", 1, 0, "no-changed-when", Severity::HIGH, "m", nil),
        Violation.new("t.yml", 2, 0, "yaml[colons]", Severity::LOW, "m", nil),
        Violation.new("t.yml", 3, 0, "yaml[commas]", Severity::LOW, "m", nil),
      ]).lines(false)
      lines[3].must_equal("  1 yaml profile:basic tags:formatting,yaml")
      lines[4].must_equal("  1 yaml profile:basic tags:formatting,yaml")
      lines[5].must_include("no-changed-when")
    end
  end

  describe Profile do
    it "mirrors upstream's profile rule ordering" do
      Profile.order("yaml").must_equal(22)
      Profile.order("package-latest").must_equal(29)
      Profile.order("no-changed-when").must_equal(41)
      Profile.order("yaml[commas]").must_equal(22)
      Profile.order("nope").must_equal(Profile::RULE_ORDER.size)
    end

    it "resolves a rule's first profile, by sub-tag or by family" do
      Profile.of("yaml[commas]").must_equal("basic")
      Profile.of("package-latest").must_equal("safety")
      Profile.of("no-changed-when").must_equal("shared")
      Profile.of("name[template]").must_equal("moderate")
      Profile.of("args[module]").must_be_nil
    end

    it "groups RULE_ORDER into the summary profiles without gaps" do
      Profile::PROFILE_GROUP_SIZES.sum.must_equal(Profile::RULE_ORDER.size)
      Profile::SUMMARY_PROFILES.size.must_equal(Profile::PROFILE_GROUP_SIZES.size)
    end

    it "selects rules by profile the way upstream does" do
      Profile.includes?("safety", "package-latest").must_equal(true)
      Profile.includes?("moderate", "package-latest").must_equal(false)
      Profile.includes?("basic", "yaml[commas]").must_equal(true)
      Profile.includes?("min", "yaml[commas]").must_equal(false)
    end
  end
end
