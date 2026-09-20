require "../spec_helper"
require "../../src/krikri_lint/lint"
require "json"

module Krikri::Lint
  describe JsonSchema do
    it "validates type and required" do
      schema = JSON.parse(%({"type": "object", "required": ["a"], "properties": {"a": {"type": "string"}}}))
      JsonSchema.validate(JSON.parse(%({"a": "x"})), schema).valid?.should be_true
      r = JsonSchema.validate(JSON.parse(%({"a": 1})), schema)
      r.valid?.should be_false
      err = r.error || raise "expected error"
      err.keyword.should eq("type")
      r2 = JsonSchema.validate(JSON.parse(%({})), schema)
      err2 = r2.error || raise "expected error"
      err2.keyword.should eq("required")
      err2.message.should eq("'a' is a required property")
    end

    it "skips required for non-objects (jsonschema semantics)" do
      schema = JSON.parse(%({"required": ["a"]}))
      JsonSchema.validate(JSON.parse(%(5)), schema).valid?.should be_true
      JsonSchema.validate(JSON.parse(%({"a": 1})), schema).valid?.should be_true
      JsonSchema.validate(JSON.parse(%({"b": 1})), schema).valid?.should be_false
    end

    it "resolves local $refs" do
      schema = JSON.parse(%({"$defs": {"X": {"type": "string"}}, "properties": {"a": {"$ref": "#/$defs/X"}}}))
      JsonSchema.validate(JSON.parse(%({"a": "x"})), schema).valid?.should be_true
      JsonSchema.validate(JSON.parse(%({"a": 3})), schema).valid?.should be_false
    end

    it "handles if/then/else" do
      schema = JSON.parse(%({"if": {"properties": {"t": {"const": true}}}, "then": {"required": ["a"]}, "else": {"required": ["b"]}}))
      JsonSchema.validate(JSON.parse(%({"t": true, "a": 1})), schema).valid?.should be_true
      JsonSchema.validate(JSON.parse(%({"t": true})), schema).valid?.should be_false
      JsonSchema.validate(JSON.parse(%({"t": false, "b": 1})), schema).valid?.should be_true
      # without "t", the if-schema matches vacuously and then: applies
      JsonSchema.validate(JSON.parse(%({"b": 1})), schema).valid?.should be_false
      JsonSchema.validate(JSON.parse(%({"a": 1})), schema).valid?.should be_true
    end

    it "formats clauses as python repr" do
      err = JsonSchema.validate(JSON.parse(%(5)), JSON.parse(%({"not": {"required": ["a"]}}))).error || raise "expected error"
      err.formatted_clause.should eq("{'required': ['a']}")
    end

    it "supports enum/const/pattern/minLength" do
      JsonSchema.validate(JSON.parse(%("x")), JSON.parse(%({"enum": ["x"]}))).valid?.should be_true
      JsonSchema.validate(JSON.parse(%("y")), JSON.parse(%({"enum": ["x"]}))).valid?.should be_false
      JsonSchema.validate(JSON.parse(%("ab")), JSON.parse(%({"pattern": "^a"}))).valid?.should be_true
      JsonSchema.validate(JSON.parse(%("")), JSON.parse(%({"minLength": 1}))).valid?.should be_false
      JsonSchema.validate(JSON.parse(%("x")), JSON.parse(%({"const": "x"}))).valid?.should be_true
    end
  end

  def self.meta_violations(yaml : String) : Array(Violation)
    path = File.tempname("metaspec", ".yml")
    dir = File.dirname(path)
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

  describe SchemaMetaRule do
    rule = SchemaMetaRule.new

    it "flags a non-object galaxy_info like upstream" do
      v = meta_violations("---\ngalaxy_info: 5\n")
      v.size.should eq(1)
      v.first.rule_id.should eq("schema[meta]")
      v.first.line.should eq(1)
      v.first.message.should eq("$.galaxy_info 5 should not be valid under {'required': ['cloud_platforms', 'galaxy_tags', 'min_ansible_version', 'namespace', 'platforms', 'role_name', 'video_links']}. See https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html#using-role-dependencies")
    end

    it "flags a missing required galaxy field" do
      v = meta_violations("---\ngalaxy_info:\n  author: me\n")
      v.size.should eq(1)
      v.first.message.should eq("$.galaxy_info 'description' is a required property. See https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html#using-role-dependencies")
    end

    it "accepts a complete standalone galaxy_info" do
      v = meta_violations("---\ngalaxy_info:\n  author: me\n  description: d\n  license: MIT\n  min_ansible_version: '2.9'\n")
      v.should be_empty
    end

    # Without `standalone`, both allOf branches apply vacuously and
    # upstream also still demands license/min_ansible_version here.
    it "flags missing license on non-standalone galaxy_info like upstream" do
      v = meta_violations("---\ngalaxy_info:\n  author: me\n  description: d\n")
      v.size.should eq(1)
      v.first.message.should contain("'license' is a required property")
    end

    it "accepts a role dependencies list" do
      v = meta_violations("---\ndependencies:\n  - role: x\n")
      v.should be_empty
    end

    it "skips non-role meta files" do
      path = File.tempname("metastandalone", ".yml")
      File.write(path, "---\ngalaxy_info: 5\n")
      file = PositionedFile.load(path)
      violations = [] of Violation
      rule.check(file, violations)
      violations.should be_empty
    ensure
      File.delete(path) if path
    end
  end
end
