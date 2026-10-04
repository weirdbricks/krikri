require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  SPACING_YAML = "---\n- hosts: all\n  tasks:\n    - name: Spacing\n" \
                 "      ansible.builtin.debug:\n        msg: \"{{x}}\"\n"

  describe "default warn_list (upstream parity)" do
    it "mirrors upstream's DEFAULT_WARN_LIST" do
      LintConfig.new.warn_list.must_equal(["experimental", "jinja[spacing]", "fqcn[deep]"])
    end

    it "renders a default warn_list sub-tag as a warning" do
      v = run_rules_yaml(SPACING_YAML, [JinjaRule.new])
      v.size.must_equal(1)
      v.first.warning?.must_equal(true)
      v.first.level.must_equal("warning")
    end

    it "renders it as a warning via a family entry" do
      config = LintConfig.new(warn_list: ["jinja"])
      run_rules_yaml(SPACING_YAML, [JinjaRule.new], config).first.warning?.must_equal(true)
    end

    it "renders it as a warning via a category tag entry" do
      # Upstream demotes a match whose rule's category tags (here
      # jinja's "formatting") appear in the warn list.
      config = LintConfig.new(warn_list: ["formatting"])
      run_rules_yaml(SPACING_YAML, [JinjaRule.new], config).first.warning?.must_equal(true)
    end

    it "suppresses a violation named by a category tag in the skip_list" do
      config = LintConfig.new(skip_list: ["formatting"])
      run_rules_yaml(SPACING_YAML, [JinjaRule.new], config).must_be_empty
    end

    it "replaces the default warn_list with a config file's own" do
      path = File.tempname("lintcfg", "")
      File.write(path, "warn_list:\n  - experimental\n")
      config = LintConfig.from_file(path)
      config.warn_list.must_equal(["experimental"])
      config.file_warn_list.must_equal(["experimental"])
      v = run_rules_yaml(SPACING_YAML, [JinjaRule.new], config)
      v.first.warning?.must_equal(false)
    ensure
      File.delete(path) if path
    end

    it "keeps the default warn_list when the config file omits warn_list" do
      path = File.tempname("lintcfg", "")
      File.write(path, "profile: shared\n")
      config = LintConfig.from_file(path)
      config.warn_list.must_equal(LintConfig::DEFAULT_WARN_LIST)
      config.file_warn_list.must_be_nil
      run_rules_yaml(SPACING_YAML, [JinjaRule.new], config).first.warning?.must_equal(true)
    ensure
      File.delete(path) if path
    end

    it "treats an empty config-file warn_list as clearing the defaults" do
      path = File.tempname("lintcfg", "")
      File.write(path, "warn_list: []\n")
      config = LintConfig.from_file(path)
      config.warn_list.must_equal([] of String)
      config.file_warn_list.must_equal([] of String)
      run_rules_yaml(SPACING_YAML, [JinjaRule.new], config).first.warning?.must_equal(false)
    ensure
      File.delete(path) if path
    end
  end
end
