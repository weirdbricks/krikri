require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe GalaxyVersionIncorrectRule do
    private def rule
      GalaxyVersionIncorrectRule.new
    end

    # A fresh unique DIRECTORY, not File.tempname's dirname: with the
    # default tempdir that dirname is /tmp itself, and the rm_rf in the
    # ensure would delete the whole /tmp mid-suite. The file has to carry
    # the galaxy.yml name for FileType to give it the galaxy kind.
    private def galaxy_violations(body : String) : Array(Violation)
      dir = File.tempname("galaxyversionyml")
      Dir.mkdir(dir)
      path = File.join(dir, "galaxy.yml")
      File.write(path, body)
      violations = [] of Violation
      rule.check(PositionedFile.load(path), violations)
      violations
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    private def run_galaxy(body : String, config : LintConfig) : Array(Violation)
      dir = File.tempname("galaxyversionrun")
      Dir.mkdir(dir)
      path = File.join(dir, "galaxy.yml")
      File.write(path, body)
      rules = [rule] of Rule
      Runner.new(RuleRegistry.new(rules), config).run([path])
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "flags a version below 1.0.0 at the version value's position" do
      v = galaxy_violations("namespace: acme\nname: demo\nversion: 0.9.0\n")
      v.size.must_equal(1)
      violation = v.first
      violation.rule_id.must_equal("galaxy-version-incorrect")
      violation.severity.must_equal(Severity::MEDIUM)
      violation.message.must_equal(
        "collection version should be greater than or equal to 1.0.0")
      {violation.line, violation.column}.must_equal({3, 10})
      rule.tags.must_equal(["opt-in", "metadata"])
    end

    it "accepts 1.0.0 and above" do
      %w[1.0.0 1.0.1 1.1.0 2.0.0 10.0.0 1.0.0.1].each do |version|
        galaxy_violations("namespace: acme\nname: demo\nversion: #{version}\n").must_be_empty
      end
    end

    # Upstream's Version compares the dot-split components as a plain
    # list of strings, so "0.10.0" is below "1.0.0" at the first
    # component and a quoted "1.0" is below it as a shorter prefix (an
    # unquoted 1.0 is a float upstream cannot compare at all).
    it "compares the components as strings, not as numbers or semver" do
      %w[0.9.0 0.10.0 0.0.1].each do |version|
        galaxy_violations("namespace: acme\nname: demo\nversion: #{version}\n").size.must_equal(1)
      end
      galaxy_violations("namespace: acme\nname: demo\nversion: \"1.0\"\n").size.must_equal(1)
    end

    it "reports a missing version at the file start with no column" do
      v = galaxy_violations("namespace: acme\nname: demo\n")
      v.size.must_equal(1)
      {v.first.line, v.first.column}.must_equal({1, 0})
    end

    it "reports a null version like a missing one" do
      ["version:\n", "version: null\n", "version: ~\n"].each do |line|
        v = galaxy_violations("namespace: acme\nname: demo\n#{line}")
        v.size.must_equal(1)
        {v.first.line, v.first.column}.must_equal({1, 0})
      end
    end

    # A falsey value matches before the comparison runs, and upstream
    # still positions it at the value itself.
    it "reports a falsy value at the value's position" do
      ["version: 0\n", "version: 0.0\n", "version: \"\"\n", "version: []\n"].each do |line|
        v = galaxy_violations("namespace: acme\nname: demo\n#{line}")
        v.size.must_equal(1)
        {v.first.line, v.first.column}.must_equal({3, 10})
      end
    end

    # Upstream's Version() calls .split on the loaded value, so every
    # non-string it cannot compare raises and the match is lost - a
    # Python bool false even fails earlier, in the position lookup.
    it "reports nothing for the non-string versions upstream cannot compare" do
      ["version: 1\n", "version: 0.9\n", "version: true\n", "version: false\n",
       "version: {}\n", "version: [1]\n"].each do |line|
        galaxy_violations("namespace: acme\nname: demo\n#{line}").must_be_empty
      end
    end

    it "checks each mapping of a top-level sequence" do
      v = galaxy_violations(
        "- namespace: acme\n  name: demo\n  version: 0.9.0\n" \
        "- namespace: acme\n  name: other\n  version: 1.0.0\n")
      v.size.must_equal(1)
      {v.first.line, v.first.column}.must_equal({3, 12})
    end

    it "classifies galaxy.yml as its own kind" do
      FileType.from_path("/collection/acme/demo/galaxy.yml").must_equal(FileType::GALAXY)
      # Upstream's pattern names only the .yml spelling.
      FileType.from_path("/collection/acme/demo/galaxy.yaml").must_equal(FileType::PLAYBOOK)
      # The galaxy pattern precedes upstream's role-subdir ones.
      FileType.from_path("roles/foo/tasks/galaxy.yml").must_equal(FileType::GALAXY)
      rule.applies_to.must_equal([FileType::GALAXY])
    end

    it "honours a project kind naming galaxy, and one overriding it" do
      galaxy = [KindPattern.new("galaxy", "**/meta/galaxy.yml")]
      FileType.from_path("meta/galaxy.yml", galaxy).must_equal(FileType::GALAXY)
      playbook = [KindPattern.new("playbook", "**/galaxy.yml")]
      FileType.from_path("galaxy.yml", playbook).must_equal(FileType::PLAYBOOK)
    end

    it "is off by default and runs only when --enable-list names it" do
      body = "namespace: acme\nname: demo\nversion: 0.9.0\n"
      run_galaxy(body, LintConfig.new).must_be_empty
      run_galaxy(body, LintConfig.new(enable_list: ["galaxy-version-incorrect"])).size.must_equal(1)
      # Upstream's loader keys the opt-in gate on the rule id, never on
      # the tag, and the enable list beats profile gating.
      run_galaxy(body, LintConfig.new(enable_list: ["opt-in"])).must_be_empty
      run_galaxy(body, LintConfig.new(tags: ["opt-in"])).must_be_empty
      run_galaxy(body,
        LintConfig.new(profile: "min", enable_list: ["galaxy-version-incorrect"])).size.must_equal(1)
    end

    it "is registered for --list-rules and the profile lookups" do
      RuleRegistry.default.find("galaxy-version-incorrect").wont_be_nil
      # Upstream lists it in no profile's rules list, so the summary's
      # row reports the profile that was walked rather than one of its
      # own, and production gating is what --profile min drops.
      Profile.of("galaxy-version-incorrect").must_be_nil
      Profile.includes?("production", "galaxy-version-incorrect").must_equal(true)
      Profile.includes?("min", "galaxy-version-incorrect").must_equal(false)
    end
  end
end
