require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe SanityRule do
    private def ignore_path(name : String, content : String) : String
      dir = PluginSpecHelper.tmp_path("lint_sanity")
      path = File.join(dir, "tests", "sanity", name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
      path
    end

    private def lint_ignores(name : String, content : String) : Array(Violation)
      path = ignore_path(name, content)
      Runner.new(RuleRegistry.new([SanityRule.new] of Rule)).run([path])
    end

    it "flags an ignore entry outside the permitted list at its own line" do
      v = lint_ignores("ignore-2.15.txt",
        "plugins/modules/foo.py validate-modules:missing-gplv3-license\n" \
        "plugins/modules/bar.py validate-modules:invalid-documentation\n")
      v.size.must_equal(1)
      match = v.first
      match.rule_id.must_equal("sanity[cannot-ignore]")
      match.line.must_equal(2)
      match.column.must_equal(0)
      match.severity.must_equal(Severity::MEDIUM)
      match.message.must_equal("Ignore file contains validate-modules:invalid-documentation " \
                               "at line 2, which is not a permitted ignore.")
    end

    it "accepts every entry on the upstream allow list" do
      entries = SanityRule::ALLOWED_IGNORES.map { |ignore| "plugins/modules/foo.py #{ignore}" }
      lint_ignores("ignore-2.15.txt", entries.join('\n') + '\n').must_be_empty
    end

    it "flags an entry not shaped like '<path> <ignore>'" do
      v = lint_ignores("ignore-2.16.txt", "plugins/modules/baz.py\n")
      v.size.must_equal(1)
      v.first.rule_id.must_equal("sanity[bad-ignore]")
      v.first.line.must_equal(1)
      v.first.message.must_equal("Ignore file entry at 1 is formatted incorrectly. Please review.")
    end

    it "strips a trailing comment before reading the ignore name" do
      v = lint_ignores("ignore-2.15.txt",
        "plugins/modules/foo.py validate-modules:missing-gplv3-license  # legacy\n")
      v.must_be_empty
    end

    it "reports an entry whose comment strip leaves a single field" do
      v = lint_ignores("ignore-2.15.txt", "plugins/modules/foo.py # legacy\n")
      v.size.must_equal(1)
      v.first.rule_id.must_equal("sanity[bad-ignore]")
    end

    it "does not inspect entries outside the plugins/ and roles/ trees" do
      v = lint_ignores("ignore-2.15.txt",
        "docs/foo.py validate-modules:invalid-documentation\n")
      v.must_be_empty
    end

    it "inspects roles/ entries" do
      v = lint_ignores("ignore-2.15.txt",
        "roles/foo/tasks/main.yml validate-modules:invalid-documentation\n")
      v.size.must_equal(1)
      v.first.rule_id.must_equal("sanity[cannot-ignore]")
    end

    it "skips the ignore-file generations upstream does not check" do
      SanityRule::NO_CHECK_IGNORE_FILES.each do |generation|
        lint_ignores("#{generation}.txt", "plugins/modules/bar.py validate-modules:nope\n").must_be_empty
      end
    end

    it "is registered with upstream's id, tags and severity" do
      rule = RuleRegistry.default.find("sanity")
      raise "sanity is not registered" unless rule
      rule.tags.must_equal(["idiom"])
      rule.severity.must_equal(Severity::MEDIUM)
      rule.applies_to.must_equal([FileType::SANITY_IGNORE])
      # Upstream lists the family in the production profile's rules.
      Profile.of("sanity").must_equal("production")
    end

    it "classifies a tests/sanity/ignore-*.txt path as a sanity ignore file" do
      FileType.from_path("x/tests/sanity/ignore-2.15.txt").must_equal(FileType::SANITY_IGNORE)
      FileType.from_path("x/tests/sanity/ignore-2.15.yml").must_equal(FileType::PLAYBOOK)
      FileType.from_path("x/tests/other/ignore-2.15.txt").must_equal(FileType::PLAYBOOK)
    end

    it "discovers the ignore files in a directory walk" do
      dir = PluginSpecHelper.tmp_path("lint_sanity_walk")
      path = File.join(dir, "tests", "sanity", "ignore-2.15.txt")
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "plugins/modules/bar.py validate-modules:invalid-documentation\n")
      FileDiscovery.discover([dir]).must_equal([path])
    end

    it "reports only the sanity match on an ignore file, never a load failure" do
      # The file is plain text, so parsing it as YAML would add a
      # load-failure match upstream never reports.
      path = ignore_path("ignore-2.15.txt",
        "plugins/modules/bar.py validate-modules:invalid-documentation\n")
      violations = Runner.new(RuleRegistry.default).run([path])
      violations.map(&.rule_id).must_equal(["sanity[cannot-ignore]"])
    end
  end
end
