require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe MetaNoTagsRule do
    private def rule
      MetaNoTagsRule.new
    end

    # Upstream only classifies `<role>/meta/main.yml` as kind meta, so
    # the rule's early return is driven by the path as well as FileType.
    private def meta_violations(yaml : String, path : String? = nil) : Array(Violation)
      # A fresh unique DIRECTORY, not File.tempname's dirname: with the
      # default tempdir that dirname is /tmp itself, and the rm_rf in the
      # ensure would delete the whole /tmp mid-suite.
      dir = File.tempname("metanotagsspec")
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

    it "flags uppercase, dashed and spaced tags at file scope" do
      v = meta_violations("---\ngalaxy_info:\n  author: me\n  description: d\n" \
                          "  license: MIT\n  min_ansible_version: '2.9'\n" \
                          "  galaxy_tags:\n    - Web\n    - my-sql\n    - my s q l\n")
      v.size.must_equal(3)
      v.map(&.message).sort!.must_equal([
        "Tags must contain lowercase letters and digits only., invalid: 'Web'",
        "Tags must contain lowercase letters and digits only., invalid: 'my s q l'",
        "Tags must contain lowercase letters and digits only., invalid: 'my-sql'",
      ])
      v.each do |violation|
        violation.rule_id.must_equal("meta-no-tags")
        violation.line.must_equal(1)
        violation.column.must_equal(0)
      end
      rule.severity.must_equal(Severity::HIGH)
      rule.tags.must_equal(["metadata"])
    end

    it "accepts lowercase letter and digit tags" do
      meta_violations("---\ngalaxy_info:\n  author: me\n  description: d\n" \
                      "  license: MIT\n  min_ansible_version: '2.9'\n" \
                      "  galaxy_tags:\n    - web\n    - mysql8\n").must_be_empty
    end

    it "flags a non-list galaxy_tags" do
      v = meta_violations("---\ngalaxy_info:\n  author: me\n  description: d\n" \
                          "  license: MIT\n  min_ansible_version: '2.9'\n" \
                          "  galaxy_tags: web\n")
      v.map(&.message).must_equal(["Expected 'galaxy_tags' to be a list"])
    end

    it "flags categories and still checks the tags it lists" do
      v = meta_violations("---\ngalaxy_info:\n  author: me\n  description: d\n" \
                          "  license: MIT\n  min_ansible_version: '2.9'\n" \
                          "  categories:\n    - Web\n")
      v.map(&.message).sort!.must_equal([
        "Tags must contain lowercase letters and digits only., invalid: 'Web'",
        "Use 'galaxy_tags' rather than 'categories'",
      ])
    end

    it "flags a non-list categories" do
      v = meta_violations("---\ngalaxy_info:\n  author: me\n  description: d\n" \
                          "  license: MIT\n  min_ansible_version: '2.9'\n" \
                          "  categories: web\n")
      v.map(&.message).sort!.must_equal([
        "Expected 'categories' to be a list",
        "Use 'galaxy_tags' rather than 'categories'",
      ])
    end

    it "flags non-string tags with python's repr" do
      v = meta_violations("---\ngalaxy_info:\n  author: me\n  description: d\n" \
                          "  license: MIT\n  min_ansible_version: '2.9'\n" \
                          "  galaxy_tags:\n    - 123\n    - true\n")
      v.map(&.message).sort!.must_equal([
        "Tags must be strings: '123'",
        "Tags must be strings: 'True'",
      ])
    end

    it "ignores an empty galaxy_info like upstream" do
      meta_violations("---\ngalaxy_info: {}\n").must_be_empty
    end

    it "ignores files that are not meta/main.yml" do
      meta_violations("---\ngalaxy_info:\n  galaxy_tags:\n    - Web\n",
        path: "/tmp/role/meta/other.yml").must_be_empty
    end

    it "is registered for --list-rules and the profile lookups" do
      RuleRegistry.default.find("meta-no-tags").wont_be_nil
      Profile.of("meta-no-tags").must_equal("shared")
    end
  end
end
