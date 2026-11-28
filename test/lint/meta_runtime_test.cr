require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe MetaRuntimeRule do
    private def rule
      MetaRuntimeRule.new
    end

    # A fresh unique DIRECTORY, not File.tempname's dirname: with the
    # default tempdir that dirname is /tmp itself, and the rm_rf in the
    # ensure would delete the whole /tmp mid-suite.
    private def runtime_violations(yaml : String) : Array(Violation)
      dir = File.tempname("metaruntimeyml")
      Dir.mkdir(dir)
      meta_dir = File.join(dir, "meta")
      Dir.mkdir(meta_dir)
      runtime_path = File.join(meta_dir, "runtime.yml")
      File.write(runtime_path, yaml)
      file = PositionedFile.new(runtime_path, FileType.from_path(runtime_path),
        YAML::Nodes.parse(yaml).nodes.first?, nil)
      violations = [] of Violation
      rule.check(file, violations)
      violations
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "flags a requires_ansible naming no supported core version" do
      v = runtime_violations("---\nrequires_ansible: \">=2.9.10\"\n")
      v.size.must_equal(1)
      violation = v.first
      violation.rule_id.must_equal("meta-runtime[unsupported-version]")
      violation.severity.must_equal(Severity::VERY_HIGH)
      violation.message.must_equal(
        "'requires_ansible' key must refer to a currently supported " \
        "version such as: >=2.15.0, >=2.16.0, >=2.17.0, >=2.18.0")
      violation.line.must_equal(1)
      violation.column.must_equal(0)
      rule.tags.must_equal(["metadata"])
    end

    it "accepts each supported core version prefix" do
      %w[>=2.15.0 >=2.16.0 >=2.17.0 >=2.18.0].each do |requirement|
        runtime_violations("---\nrequires_ansible: \"#{requirement}\"\n").must_be_empty
      end
    end

    # Upstream tests `version in requires_ansible`, a substring search,
    # so a supported version only bounding the range also passes.
    it "accepts a supported prefix anywhere in the specifier" do
      runtime_violations("---\nrequires_ansible: \">=2.9.10,<2.17.0\"\n").must_be_empty
    end

    it "flags a requires_ansible value that is not a valid requirement" do
      v = lint_yaml(rule, "requires_ansible: \"~2.15.0\"\n", FileType::META_RUNTIME)
      v.size.must_equal(1)
      violation = v.first
      violation.rule_id.must_equal("meta-runtime[invalid-version]")
      violation.message.must_equal("'requires_ansible' is not a valid requirement specification")
      {violation.line, violation.column}.must_equal({1, 0})
    end

    it "flags a bare version with no operator at all" do
      lint_yaml(rule, "requires_ansible: 2.15.0\n", FileType::META_RUNTIME)
        .map(&.rule_id).must_equal(["meta-runtime[invalid-version]"])
    end

    it "accepts valid requirement specifiers, trailing comma included" do
      [
        "requires_ansible: \">=2.15.0\"\n",
        "requires_ansible: \">=2.15.0,<2.17.0\"\n",
        "requires_ansible: \">=2.15.0,\"\n",
        "requires_ansible: \">= 2.15.0\"\n",
        "requires_ansible: \"==2.15.*\"\n",
        "requires_ansible: \"~=2.15.0\"\n",
        "requires_ansible: \"!=2.15.0\"\n",
      ].each do |yaml|
        lint_yaml(rule, yaml, FileType::META_RUNTIME).must_be_empty
      end
    end

    # Upstream runs the supported-prefix check before the specifier parse,
    # so a value failing both reports both, unsupported first.
    it "reports both sub-rules for an unsupported, unparsable value" do
      runtime_violations("---\nrequires_ansible: \"bad\"\n")
        .map(&.rule_id).must_equal([
        "meta-runtime[unsupported-version]",
        "meta-runtime[invalid-version]",
      ])
    end

    it "ignores a missing or empty requires_ansible" do
      runtime_violations("---\nplugin_routing: {}\n").must_be_empty
      runtime_violations("---\nrequires_ansible: \"\"\n").must_be_empty
    end

    it "ignores a non-string requires_ansible" do
      ["requires_ansible: true\n", "requires_ansible: 2.15\n",
       "requires_ansible: [2.15]\n"].each do |yaml|
        lint_yaml(rule, yaml, FileType::META_RUNTIME).must_be_empty
      end
    end

    it "classifies meta/runtime.yml as its own kind" do
      # Upstream's meta-runtime kind pattern matches a meta dir anywhere,
      # which is how a collection's own meta/runtime.yml is reached.
      FileType.from_path("/collection/ns/name/meta/runtime.yml").must_equal(FileType::META_RUNTIME)
      FileType.from_path("roles/foo/meta/runtime.yaml").must_equal(FileType::META_RUNTIME)
      # A role's other meta files keep the plain meta kind, so this rule
      # never sees them.
      FileType.from_path("roles/foo/meta/main.yml").must_equal(FileType::META)
      FileType.from_path("roles/foo/meta/other.yml").must_equal(FileType::META)
      rule.applies_to.must_equal([FileType::META_RUNTIME])
    end

    it "is registered for --list-rules and the profile lookups" do
      RuleRegistry.default.find("meta-runtime").wont_be_nil
      Profile.of("meta-runtime[unsupported-version]").must_equal("shared")
      Profile.of("meta-runtime[invalid-version]").must_equal("shared")
    end
  end
end
