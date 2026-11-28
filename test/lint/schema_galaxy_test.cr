require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe SchemaGalaxyRule do
    # A fresh unique DIRECTORY, not File.tempname's dirname: with the
    # default tempdir that dirname is /tmp itself, and the rm_rf in the
    # ensure would delete the whole /tmp mid-suite.
    private def galaxy_violations(yaml : String) : Array(Violation)
      dir = File.tempname("galaxyspec")
      Dir.mkdir(dir)
      path = File.join(dir, "galaxy.yml")
      File.write(path, yaml)
      file = PositionedFile.load(path)
      violations = [] of Violation
      SchemaGalaxyRule.new.check(file, violations)
      violations
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    it "flags a galaxy.yml missing its required collection fields" do
      v = galaxy_violations("namespace: acme\nname: demo\nversion: 1.0.0\n")
      v.size.must_equal(1)
      violation = v.first
      violation.rule_id.must_equal("schema[galaxy]")
      violation.line.must_equal(1)
      violation.column.must_equal(0)
      violation.message.must_equal(
        "$ 'readme' is a required property. " \
        "See https://docs.ansible.com/ansible/latest/dev_guide/collections_galaxy_meta.html")
    end

    it "accepts a galaxy.yml holding every required field" do
      galaxy_violations(<<-YAML).must_be_empty
        namespace: acme
        name: demo
        version: 1.0.0
        readme: README.md
        authors:
          - Acme
        description: A demo collection
        repository: https://example.com/acme/demo
        YAML
    end
  end

  describe FileType do
    it "detects a galaxy.yml as a collection's Galaxy metadata" do
      FileType.from_path("galaxy.yml").must_equal(FileType::GALAXY)
      FileType.from_path(
        "collections/ansible_collections/acme/demo/galaxy.yml").must_equal(FileType::GALAXY)
      # Upstream's kind pattern names galaxy.yml only, so galaxy.yaml
      # keeps the generic yaml assignment.
      FileType.from_path("galaxy.yaml").must_equal(FileType::PLAYBOOK)
    end
  end
end
