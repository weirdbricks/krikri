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
    private def runtime_violations(yaml : String, path : String? = nil) : Array(Violation)
      dir = File.tempname("metaruntimeyml")
      Dir.mkdir(dir)
      meta_dir = File.join(dir, "meta")
      Dir.mkdir(meta_dir)
      runtime_path = File.join(meta_dir, "runtime.yml")
      File.write(runtime_path, yaml)
      target = path || runtime_path
      file = PositionedFile.new(target, FileType::META,
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

    it "ignores a missing or empty requires_ansible" do
      runtime_violations("---\nplugin_routing: {}\n").must_be_empty
      runtime_violations("---\nrequires_ansible: \"\"\n").must_be_empty
    end

    it "ignores meta files that are not runtime.yml" do
      runtime_violations("---\nrequires_ansible: \">=2.9.10\"\n",
        path: "/tmp/role/meta/main.yml").must_be_empty
    end

    # Upstream's meta-runtime kind pattern matches a meta dir anywhere,
    # which is how a collection's own meta/runtime.yml is reached.
    it "classifies a meta/runtime.yml outside roles as meta" do
      FileType.from_path("/collection/ns/name/meta/runtime.yml").must_equal(FileType::META)
      FileType.from_path("/collection/ns/name/meta/runtime.yaml").must_equal(FileType::META)
    end

    it "is registered for --list-rules and the profile lookups" do
      RuleRegistry.default.find("meta-runtime").wont_be_nil
      Profile.of("meta-runtime[unsupported-version]").must_equal("shared")
    end
  end
end
