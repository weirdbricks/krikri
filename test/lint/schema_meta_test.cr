require "../minitest_helper"
require "../../src/krikri_lint/lint"
require "json"

module Krikri::Lint
  describe JsonSchema do
    it "validates type and required" do
      schema = JSON.parse(%({"type": "object", "required": ["a"], "properties": {"a": {"type": "string"}}}))
      JsonSchema.validate(JSON.parse(%({"a": "x"})), schema).valid?.must_equal(true)
      r = JsonSchema.validate(JSON.parse(%({"a": 1})), schema)
      r.valid?.must_equal(false)
      err = r.error || raise "expected error"
      err.keyword.must_equal("type")
      r2 = JsonSchema.validate(JSON.parse(%({})), schema)
      err2 = r2.error || raise "expected error"
      err2.keyword.must_equal("required")
      err2.message.must_equal("'a' is a required property")
    end

    it "skips required for non-objects (jsonschema semantics)" do
      schema = JSON.parse(%({"required": ["a"]}))
      JsonSchema.validate(JSON.parse(%(5)), schema).valid?.must_equal(true)
      JsonSchema.validate(JSON.parse(%({"a": 1})), schema).valid?.must_equal(true)
      JsonSchema.validate(JSON.parse(%({"b": 1})), schema).valid?.must_equal(false)
    end

    it "resolves local $refs" do
      schema = JSON.parse(%({"$defs": {"X": {"type": "string"}}, "properties": {"a": {"$ref": "#/$defs/X"}}}))
      JsonSchema.validate(JSON.parse(%({"a": "x"})), schema).valid?.must_equal(true)
      JsonSchema.validate(JSON.parse(%({"a": 3})), schema).valid?.must_equal(false)
    end

    it "handles if/then/else" do
      schema = JSON.parse(%({"if": {"properties": {"t": {"const": true}}}, "then": {"required": ["a"]}, "else": {"required": ["b"]}}))
      JsonSchema.validate(JSON.parse(%({"t": true, "a": 1})), schema).valid?.must_equal(true)
      JsonSchema.validate(JSON.parse(%({"t": true})), schema).valid?.must_equal(false)
      JsonSchema.validate(JSON.parse(%({"t": false, "b": 1})), schema).valid?.must_equal(true)
      # without "t", the if-schema matches vacuously and then: applies
      JsonSchema.validate(JSON.parse(%({"b": 1})), schema).valid?.must_equal(false)
      JsonSchema.validate(JSON.parse(%({"a": 1})), schema).valid?.must_equal(true)
    end

    it "formats clauses as python repr" do
      err = JsonSchema.validate(JSON.parse(%(5)), JSON.parse(%({"not": {"required": ["a"]}}))).error || raise "expected error"
      err.formatted_clause.must_equal("{'required': ['a']}")
    end

    it "supports enum/const/pattern/minLength" do
      JsonSchema.validate(JSON.parse(%("x")), JSON.parse(%({"enum": ["x"]}))).valid?.must_equal(true)
      JsonSchema.validate(JSON.parse(%("y")), JSON.parse(%({"enum": ["x"]}))).valid?.must_equal(false)
      JsonSchema.validate(JSON.parse(%("ab")), JSON.parse(%({"pattern": "^a"}))).valid?.must_equal(true)
      JsonSchema.validate(JSON.parse(%("")), JSON.parse(%({"minLength": 1}))).valid?.must_equal(false)
      JsonSchema.validate(JSON.parse(%("x")), JSON.parse(%({"const": "x"}))).valid?.must_equal(true)
    end
  end

  describe SchemaMetaRule do
    private def meta_violations(yaml : String) : Array(Violation)
      # A fresh unique DIRECTORY, not File.tempname's dirname: with the
      # default tempdir that dirname is /tmp itself, and the rm_rf in the
      # ensure would delete the whole /tmp mid-suite (every later spec that
      # touches /tmp then fails with ENOENT - this is what broke CI across
      # 17 unrelated commits).
      dir = File.tempname("metaspec")
      Dir.mkdir(dir)
      meta_dir = File.join(dir, "meta")
      Dir.mkdir(meta_dir)
      meta_path = File.join(meta_dir, "main.yml")
      File.write(meta_path, yaml)
      file = PositionedFile.new(meta_path, FileType::META,
        YAML::Nodes.parse(yaml).nodes.first?, nil)
      violations = [] of Violation
      SchemaMetaRule.new.check(file, violations)
      violations
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    private def rule
      SchemaMetaRule.new
    end

    it "flags a non-object galaxy_info like upstream" do
      v = meta_violations("---\ngalaxy_info: 5\n")
      v.size.must_equal(1)
      v.first.rule_id.must_equal("schema[meta]")
      v.first.line.must_equal(1)
      v.first.message.must_equal("$.galaxy_info 5 should not be valid under {'required': ['cloud_platforms', 'galaxy_tags', 'min_ansible_version', 'namespace', 'platforms', 'role_name', 'video_links']}. See https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html#using-role-dependencies")
    end

    it "flags a missing required galaxy field" do
      v = meta_violations("---\ngalaxy_info:\n  author: me\n")
      v.size.must_equal(1)
      v.first.message.must_equal("$.galaxy_info 'description' is a required property. See https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html#using-role-dependencies")
    end

    it "accepts a complete standalone galaxy_info" do
      v = meta_violations("---\ngalaxy_info:\n  author: me\n  description: d\n  license: MIT\n  min_ansible_version: '2.9'\n")
      v.must_be_empty
    end

    # Without `standalone`, both allOf branches apply vacuously and
    # upstream also still demands license/min_ansible_version here.
    it "flags missing license on non-standalone galaxy_info like upstream" do
      v = meta_violations("---\ngalaxy_info:\n  author: me\n  description: d\n")
      v.size.must_equal(1)
      v.first.message.must_include("'license' is a required property")
    end

    it "accepts a role dependencies list" do
      v = meta_violations("---\ndependencies:\n  - role: x\n")
      v.must_be_empty
    end

    it "skips non-role meta files" do
      path = File.tempname("metastandalone", ".yml")
      File.write(path, "---\ngalaxy_info: 5\n")
      file = PositionedFile.load(path)
      violations = [] of Violation
      rule.check(file, violations)
      violations.must_be_empty
    ensure
      File.delete(path) if path
    end
  end
end
