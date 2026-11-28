require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe GalaxyRule do
    private def rule
      GalaxyRule.new
    end

    # A collection directory of its own: upstream resolves the changelog
    # and meta/runtime.yml candidates beside galaxy.yml, so the file must
    # not share /tmp with anything.
    private def galaxy_violations(yaml : String,
                                  files : Array(String) = [] of String) : Array(Violation)
      dir = File.tempname("galaxyrule")
      Dir.mkdir(dir)
      path = File.join(dir, "galaxy.yml")
      File.write(path, yaml)
      files.each do |sibling|
        full = File.join(dir, sibling)
        Dir.mkdir_p(File.dirname(full))
        File.write(full, "")
      end
      file = PositionedFile.load(path)
      violations = [] of Violation
      rule.check(file, violations)
      violations
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    private def collection(tags : Array(String)) : String
      String.build do |yaml|
        yaml << "namespace: acme\nname: demo\nversion: 1.0.0\ntags:\n"
        tags.each { |tag| yaml << "  - \"#{tag}\"\n" }
      end
    end

    # The issue's reproducer: a schema-valid collection tree with no
    # changelogs/ and no meta/runtime.yml.
    it "reports the reproducer's three matches at file scope" do
      yaml = <<-YAML
        namespace: acme
        name: demo
        version: 1.0.0
        readme: README.md
        authors:
          - Acme
        description: Minimal collection
        repository: https://example.invalid/acme/demo
        license:
          - GPL-3.0-or-later
        tags:
          - mytag
        YAML
      violations = galaxy_violations(yaml)
      violations.map(&.rule_id).must_equal(
        ["galaxy[no-changelog]", "galaxy[tags]", "galaxy[no-runtime]"])
      violations.each do |violation|
        violation.severity.must_equal(Severity::MEDIUM)
        {violation.line, violation.column}.must_equal({1, 0})
      end
      violations[1].message.must_equal(
        "galaxy.yaml must have one of the required tags: " \
        "['application', 'cloud', 'database', 'eda', 'infrastructure', 'linux', " \
        "'monitoring', 'networking', 'security', 'storage', 'tools', 'windows']")
      violations[2].message.must_equal("meta/runtime.yml file not found.")
      rule.severity.must_equal(Severity::MEDIUM)
      rule.tags.must_equal(["metadata"])
    end

    it "accepts a collection with a changelog, a required tag and a runtime" do
      galaxy_violations(collection(["tools"]),
        ["changelogs/changelog.yaml", "meta/runtime.yml"]).must_be_empty
    end

    it "accepts each changelog path upstream looks for" do
      ["changelogs/changelog.yaml", "changelogs/changelog.yml",
       "CHANGELOG.rst", "CHANGELOG.md"].each do |changelog|
        galaxy_violations(collection(["tools"]), [changelog, "meta/runtime.yml"])
          .must_be_empty
      end
    end

    # Upstream returns after reporting a missing version, so a galaxy.yml
    # without one never also reports the missing runtime, and the match
    # carries the loaded mapping's own position (its first key).
    it "returns before the runtime check when version is missing" do
      violations = galaxy_violations("---\nnamespace: acme\ntags:\n  - tools\n")
      violations.map(&.rule_id).must_equal(["galaxy[no-changelog]", "galaxy[version-missing]"])
      {violations[1].line, violations[1].column}.must_equal({2, 1})
      violations[1].message.must_equal("galaxy.yaml should have version tag.")
    end

    it "reports badly formatted, over-long and too many tags" do
      violations = galaxy_violations(collection(["Tools", "a__b", "1abc", "with space"]))
      violations.map(&.rule_id).must_equal(
        ["galaxy[no-changelog]", "galaxy[tags]", "galaxy[tags-format]", "galaxy[no-runtime]"])
      violations[2].message.must_equal(
        "galaxy.yaml must have properly formatted tags. " \
        "Invalid tags: Tools,a__b,1abc,with space")

      long_tag = "a" * (GalaxyRule::MAX_LENGTH_TAG + 1)
      violations = galaxy_violations(collection(["tools", long_tag]))
      violations.map(&.rule_id).must_equal(
        ["galaxy[no-changelog]", "galaxy[tags-length]", "galaxy[no-runtime]"])
      violations[1].message.must_equal(
        "galaxy.yaml tags must not exceed 64 characters. Invalid tags: #{long_tag}")

      many = ["tools"] + (1..GalaxyRule::MAX_TAGS_COUNT).map { |index| "t#{index}" }
      violations = galaxy_violations(collection(many))
      violations.map(&.rule_id).must_equal(
        ["galaxy[no-changelog]", "galaxy[tags-count]", "galaxy[no-runtime]"])
      violations[1].message.must_equal(
        "galaxy.yaml exceeds 20 tags. Current count: 21")
    end

    # Upstream iterates whatever `tags` holds, so a scalar string becomes
    # its characters - only the two underscores fail the tag pattern.
    it "treats a scalar tags value as its characters" do
      violations = galaxy_violations(collection_of("tags: not_a_list\n"))
      violations.map(&.rule_id).must_equal(
        ["galaxy[no-changelog]", "galaxy[tags]", "galaxy[tags-format]", "galaxy[no-runtime]"])
      violations[2].message.must_equal(
        "galaxy.yaml must have properly formatted tags. Invalid tags: _,_")
    end

    # A tag or dependency value upstream's iteration/regex cannot handle
    # raises out of the rule, dropping every match - the changelog check
    # included.
    it "reports nothing when a tag is not a string" do
      galaxy_violations(collection_of("tags:\n")).must_be_empty
      galaxy_violations(collection_of("tags:\n  - 123\n  - tools\n")).must_be_empty
    end

    it "reports nothing when dependencies is not a mapping" do
      galaxy_violations(collection_of("tags:\n  - tools\ndependencies:\n  - acme.one\n"))
        .must_be_empty
    end

    # Upstream tests len(str(ver).strip()) == 0, so an empty or
    # whitespace-only version is invalid while a null one prints "None".
    it "reports only dependency entries with a blank version" do
      yaml = collection_of("tags:\n  - tools\ndependencies:\n" \
                           "  community.general: \"\"\n" \
                           "  acme.blank: \"  \"\n" \
                           "  acme.null:\n" \
                           "  acme.pinned: 1.0.0\n")
      violations = galaxy_violations(yaml)
      violations.map(&.rule_id).must_equal([
        "galaxy[invalid-dependency-version]",
        "galaxy[invalid-dependency-version]",
        "galaxy[no-changelog]",
        "galaxy[no-runtime]",
      ])
      violations[0].message.must_equal(
        "Invalid collection metadata. Dependency version spec range is invalid " \
        "for 'community.general'.")
      violations[1].message.must_equal(
        "Invalid collection metadata. Dependency version spec range is invalid " \
        "for 'acme.blank'.")
    end

    # Upstream's runtime check names runtime.yml only, not the .yaml
    # spelling its meta-runtime kind accepts.
    it "only accepts meta/runtime.yml" do
      galaxy_violations(collection(["tools"]), ["meta/runtime.yaml"])
        .map(&.rule_id).must_equal(["galaxy[no-changelog]", "galaxy[no-runtime]"])
    end

    it "classifies galaxy.yml as its own kind" do
      FileType.from_path("galaxy.yml").must_equal(FileType::GALAXY)
      FileType.from_path("/collection/ns/name/galaxy.yml").must_equal(FileType::GALAXY)
      # Upstream's galaxy pattern precedes every role subdirectory
      # pattern, so it also wins inside a role tree.
      FileType.from_path("roles/foo/tasks/galaxy.yml").must_equal(FileType::GALAXY)
      # `**/galaxy.yml` names only the .yml spelling.
      FileType.from_path("galaxy.yaml").must_equal(FileType::PLAYBOOK)
      kinds = [KindPattern.new("galaxy", "**/meta.yml")]
      FileType.from_path("meta.yml", kinds).must_equal(FileType::GALAXY)
      rule.applies_to.must_equal([FileType::GALAXY])
    end

    it "is registered for --list-rules and the profile lookups" do
      RuleRegistry.default.find("galaxy").wont_be_nil
      Profile.of("galaxy[tags]").must_equal("shared")
      Profile.includes?("shared", "galaxy").must_equal(true)
      Profile.includes?("safety", "galaxy").must_equal(false)
    end
  end
end

# A galaxy.yml body whose tags/dependencies lines are appended verbatim.
private def collection_of(body : String) : String
  "namespace: acme\nname: demo\nversion: 1.0.0\n#{body}"
end
