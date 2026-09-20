require "../spec_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe Noqa do
    it "parses bare noqa as suppress-all" do
      map = Noqa.build_map("a: 1 # noqa\nb: 2\n")
      map[1].all.should be_true
      map[2]?.should be_nil
    end

    it "parses noqa with comma-separated rule ids" do
      map = Noqa.build_map("- shell: ls  # noqa: no-changed-when, yaml[line-length]\n")
      map[1].ids.should eq(["no-changed-when", "yaml[line-length]"])
    end

    it "suppresses on the violation line" do
      map = Noqa.build_map("x  # noqa: some-rule\n")
      Noqa.suppresses?(map, 1, nil, "some-rule").should be_true
      Noqa.suppresses?(map, 1, nil, "other-rule").should be_false
    end

    it "suppresses anywhere in the enclosing task above the violation" do
      map = Noqa.build_map("  - name: task  # noqa: fqcn[action-core]\n    apt: x\n")
      Noqa.suppresses?(map, 2, 1, "fqcn[action-core]").should be_true
      Noqa.suppresses?(map, 2, 1, "name[casing]").should be_false
    end
  end

  describe LintConfig do
    it "parses a config file's lists and profile" do
      path = File.tempname("lintcfg", "")
      File.write(path, "---\nskip_list:\n  - fqcn[action-core]\nwarn_list:\n  - yaml[line-length]\nexclude_paths:\n  - vendor/\nprofile: shared\n")
      begin
        config = LintConfig.from_file(path)
        config.skip_list.should eq(["fqcn[action-core]"])
        config.warn_list.should eq(["yaml[line-length]"])
        config.exclude_paths.should eq(["vendor/"])
        config.profile.should eq("shared")
      ensure
        File.delete(path) if path
      end
    end
  end

  describe Runner do
    it "drops rules in the skip_list" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x\n"
      config = LintConfig.new(skip_list: ["fqcn[action-core]"])
      run_fqcn_yaml(yaml, config).should be_empty
    end

    it "marks warn_list rules as warnings" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x\n"
      config = LintConfig.new(warn_list: ["fqcn[action-core]"])
      v = run_fqcn_yaml(yaml, config)
      v.size.should eq(1)
      v.first.warning?.should be_true
    end

    it "suppresses noqa'd tasks" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x  # noqa: fqcn[action-core]\n"
      run_fqcn_yaml(yaml).should be_empty
    end

    it "gates rules by profile" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x\n"
      # fqcn[action-core] first runs in production
      run_fqcn_yaml(yaml, LintConfig.new(profile: "min")).should be_empty
      run_fqcn_yaml(yaml, LintConfig.new(profile: "production")).size.should eq(1)
    end

    it "enable_list overrides profile gating" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x\n"
      config = LintConfig.new(profile: "min", enable_list: ["fqcn[action-core]"])
      run_fqcn_yaml(yaml, config).size.should eq(1)
    end
  end
end
