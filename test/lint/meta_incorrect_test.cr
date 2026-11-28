require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe MetaIncorrectRule do
    private def rule
      MetaIncorrectRule.new
    end

    # Upstream only classifies `<role>/meta/main.yml` as kind meta, so
    # the rule's early return is driven by the path as well as FileType.
    private def meta_violations(yaml : String, path : String? = nil) : Array(Violation)
      # A fresh unique DIRECTORY, not File.tempname's dirname: with the
      # default tempdir that dirname is /tmp itself, and the rm_rf in the
      # ensure would delete the whole /tmp mid-suite.
      dir = File.tempname("metaincorrectspec")
      Dir.mkdir(dir)
      meta_dir = File.join(dir, "meta")
      Dir.mkdir(meta_dir)
      meta_path = File.join(meta_dir, "main.yml")
      File.write(meta_path, yaml)
      target = path || meta_path
      file = PositionedFile.new(target, FileType::META,
        YAML::Nodes.parse(yaml).nodes.first?, nil)
      violations = [] of Violation
      rule.check(file, violations)
      violations
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "flags the scaffolded author, description, company and license" do
      v = meta_violations("galaxy_info:\n  author: your name\n" \
                          "  description: your description\n" \
                          "  company: your company (optional)\n" \
                          "  license: license (GPL-2.0-or-later, MIT, etc)\n" \
                          "  min_ansible_version: \"2.1\"\ndependencies: []\n")
      v.map(&.message).sort!.must_equal([
        "Should change default metadata: author",
        "Should change default metadata: company",
        "Should change default metadata: description",
        "Should change default metadata: license",
      ])
      v.each do |violation|
        violation.rule_id.must_equal("meta-incorrect")
        violation.line.must_equal(1)
        violation.column.must_equal(1)
      end
      rule.severity.must_equal(Severity::HIGH)
      rule.tags.must_equal(["metadata"])
      rule.applies_to.must_equal([FileType::META])
    end

    it "reports at the root mapping's line and column" do
      v = meta_violations("---\ngalaxy_info:\n  author: your name\n")
      v.map(&.line).must_equal([2])
      v.map(&.column).must_equal([1])
    end

    it "flags the older scaffold license spelling too" do
      v = meta_violations("galaxy_info:\n  license: license (GPLv2, CC-BY, etc)\n")
      v.map(&.message).must_equal(["Should change default metadata: license"])
    end

    it "flags one violation per field even when license has two defaults" do
      meta_violations("galaxy_info:\n  license: license (GPLv2, CC-BY, etc)\n")
        .size.must_equal(1)
    end

    it "accepts changed metadata" do
      meta_violations("galaxy_info:\n  author: krikri\n  description: A role.\n" \
                      "  company: Weirdbricks\n  license: MIT\n" \
                      "  min_ansible_version: \"2.9\"\n").must_be_empty
    end

    # Upstream's docs show `your role description`, which is not one of
    # the values in its field_defaults table, so it does not match.
    it "does not flag a near-miss description" do
      meta_violations("galaxy_info:\n  description: your role description\n")
        .must_be_empty
    end

    it "ignores an empty galaxy_info like upstream" do
      meta_violations("galaxy_info: {}\n").must_be_empty
    end

    it "ignores a galaxy_info that is not a mapping" do
      meta_violations("galaxy_info: your name\n").must_be_empty
    end

    it "ignores a non-scalar field value" do
      meta_violations("galaxy_info:\n  author:\n    - your name\n").must_be_empty
    end

    it "ignores files that are not meta/main.yml" do
      meta_violations("galaxy_info:\n  author: your name\n",
        path: "/tmp/role/meta/other.yml").must_be_empty
    end

    it "is registered for --list-rules and the profile lookups" do
      RuleRegistry.default.find("meta-incorrect").wont_be_nil
      Profile.of("meta-incorrect").must_equal("shared")
    end
  end
end
