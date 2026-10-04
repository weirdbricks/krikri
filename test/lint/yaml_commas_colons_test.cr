require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe YamlCommasRule do
    private def rule
      YamlCommasRule.new
    end

    it "flags too many and too few spaces after a comma" do
      v = lint_yaml(rule, "---\n- hosts: all\n  vars:\n    a: [1,2,   3]\n")
      v.map(&.message).must_equal([
        "Too few spaces after comma",
        "Too many spaces after comma",
      ])
      v.map(&.line).must_equal([4, 4])
    end

    it "flags too many spaces after a comma in a flow mapping" do
      v = lint_yaml(rule, "---\n- hosts: all\n  vars:\n    a: {x: 1,  y: 2}\n")
      v.map(&.message).must_equal(["Too many spaces after comma"])
      v.first.line.must_equal(4)
    end

    it "flags a space before a comma" do
      v = lint_yaml(rule, "---\n- hosts: all\n  vars:\n    a: {x: 1 , y: 2}\n")
      v.map(&.message).must_equal(["Too many spaces before comma"])
      v.first.line.must_equal(4)
    end

    it "accepts well-spaced flow collections" do
      v = lint_yaml(rule, "---\n- hosts: all\n  vars:\n    a: [1, 2, 3]\n    b: {x: 1, y: 2}\n")
      v.must_be_empty
    end

    it "ignores commas in block context, quoted scalars and block scalars" do
      v = lint_yaml(rule, "---\n" \
                          "- hosts: all\n" \
                          "  vars:\n" \
                          "    plain: a,  b\n" \
                          "    quoted: \"a,  b\"\n" \
                          "    single: 'a,  b'\n" \
                          "    url: http://example.com/a,  b\n" \
                          "    literal: |\n" \
                          "      a,  b\n" \
                          "    folded: >\n" \
                          "      a,  b\n")
      v.must_be_empty
    end

    it "keeps checking multi-line flow collections" do
      v = lint_yaml(rule, "---\n- hosts: all\n  vars:\n    a: [1,\n        2,3]\n")
      v.map(&.message).must_equal(["Too few spaces after comma"])
      v.first.line.must_equal(5)
    end
  end

  describe YamlColonsRule do
    private def rule
      YamlColonsRule.new
    end

    it "flags too many spaces after a block-mapping colon" do
      v = lint_yaml(rule, "---\n- hosts: all\n  vars:\n    a:   1\n")
      v.map(&.message).must_equal(["Too many spaces after colon"])
      v.first.line.must_equal(4)
    end

    it "flags a space before a colon" do
      v = lint_yaml(rule, "---\n- hosts: all\n  vars:\n    a : 1\n")
      v.map(&.message).must_equal(["Too many spaces before colon"])
    end

    it "flags too many spaces after an explicit-key indicator" do
      v = lint_yaml(rule, "---\n- hosts: all\n  vars:\n    ?  key\n    : val\n")
      v.map(&.message).must_equal(["Too many spaces after question mark"])
    end

    it "flags too many spaces after a flow-mapping colon" do
      v = lint_yaml(rule, "---\n- hosts: all\n  vars:\n    a: {x:  1}\n")
      v.map(&.message).must_equal(["Too many spaces after colon"])
    end

    it "accepts well-spaced mappings" do
      v = lint_yaml(rule, "---\n- hosts: all\n  vars:\n    a: 1\n    b:\n      c: 2\n    d: {x: 1, y: 2}\n")
      v.must_be_empty
    end

    it "ignores colons that are not value indicators" do
      v = lint_yaml(rule, "---\n" \
                          "- hosts: all\n" \
                          "  vars:\n" \
                          "    url: http://example.com:8080/x\n" \
                          "    quoted: \"a:  b\"\n" \
                          "    single: 'a:  b'\n" \
                          "    literal: |\n" \
                          "      key:   value\n" \
                          "    folded: >\n" \
                          "      key:   value\n")
      v.must_be_empty
    end

    it "exempts an alias used as a key" do
      v = lint_yaml(rule, "---\n- hosts: all\n  vars:\n    a: &base\n      x: 1\n    b: {*base: 2}\n")
      v.must_be_empty
    end
  end
end
