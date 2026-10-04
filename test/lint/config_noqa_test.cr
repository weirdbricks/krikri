require "../minitest_helper"
require "../../src/krikri_lint/lint"

module Krikri::Lint
  describe Noqa do
    it "parses bare noqa as suppress-all" do
      map = Noqa.build_map("a: 1 # noqa\nb: 2\n")
      map[1].all.must_equal(true)
      map[2]?.must_be_nil
    end

    it "parses noqa with comma-separated rule ids" do
      map = Noqa.build_map("- shell: ls  # noqa: no-changed-when, yaml[line-length]\n")
      map[1].ids.must_equal(["no-changed-when", "yaml[line-length]"])
    end

    it "suppresses on the violation line" do
      map = Noqa.build_map("x  # noqa: some-rule\n")
      Noqa.suppresses?(map, 1, nil, "some-rule").must_equal(true)
      Noqa.suppresses?(map, 1, nil, "other-rule").must_equal(false)
    end

    it "suppresses anywhere in the enclosing task above the violation" do
      map = Noqa.build_map("  - name: task  # noqa: fqcn[action-core]\n    apt: x\n")
      Noqa.suppresses?(map, 2, 1, "fqcn[action-core]").must_equal(true)
      Noqa.suppresses?(map, 2, 1, "name[casing]").must_equal(false)
    end

    it "suppresses on a comment below the violation line, inside the task" do
      # Upstream walks every comment in a task's YAML subtree, so a
      # noqa at the bottom of the body still covers the task.
      map = Noqa.build_map("- name: t\n  command: ls\n  # noqa: no-changed-when\n")
      Noqa.suppresses?(map, 1, 1, "no-changed-when", 3).must_equal(true)
      Noqa.suppresses?(map, 1, 1, "risky-shell-pipe", 3).must_equal(false)
    end

    it "accepts the rule family as well as the full tag" do
      map = Noqa.build_map("x  # noqa: run-once\n")
      Noqa.suppresses?(map, 1, nil, "run-once[task]").must_equal(true)
      Noqa.suppresses?(map, 1, nil, "run-once[play]").must_equal(true)
      Noqa.suppresses?(map, 1, nil, "risky-octal").must_equal(false)
    end
  end

  describe LintConfig do
    it "parses a config file's lists and profile" do
      path = File.tempname("lintcfg", "")
      File.write(path, "---\nskip_list:\n  - fqcn[action-core]\nwarn_list:\n  - yaml[line-length]\nexclude_paths:\n  - vendor/\nprofile: shared\n")
      begin
        config = LintConfig.from_file(path)
        config.skip_list.must_equal(["fqcn[action-core]"])
        config.warn_list.must_equal(["yaml[line-length]"])
        config.exclude_paths.must_equal(["vendor/"])
        config.profile.must_equal("shared")
      ensure
        File.delete(path) if path
      end
    end
  end

  describe "Runner (config_noqa_test.cr)" do
    it "drops rules in the skip_list" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x\n"
      config = LintConfig.new(skip_list: ["fqcn[action-core]"])
      run_fqcn_yaml(yaml, config).must_be_empty
    end

    it "marks warn_list rules as warnings" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x\n"
      config = LintConfig.new(warn_list: ["fqcn[action-core]"])
      v = run_fqcn_yaml(yaml, config)
      v.size.must_equal(1)
      v.first.warning?.must_equal(true)
    end

    it "suppresses noqa'd tasks" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x  # noqa: fqcn[action-core]\n"
      run_fqcn_yaml(yaml).must_be_empty
    end

    it "gates rules by profile" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x\n"
      # fqcn[action-core] first runs in production
      run_fqcn_yaml(yaml, LintConfig.new(profile: "min")).must_be_empty
      run_fqcn_yaml(yaml, LintConfig.new(profile: "production")).size.must_equal(1)
    end

    it "enable_list overrides profile gating" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x\n"
      config = LintConfig.new(profile: "min", enable_list: ["fqcn[action-core]"])
      run_fqcn_yaml(yaml, config).size.must_equal(1)
    end

    it "drops a rule named by family in the skip_list" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x\n"
      config = LintConfig.new(skip_list: ["fqcn"])
      run_fqcn_yaml(yaml, config).must_be_empty
    end

    it "warns a rule named by family in the warn_list" do
      yaml = "---\n- hosts: all\n  tasks:\n    - apt: x\n"
      config = LintConfig.new(warn_list: ["fqcn"])
      v = run_fqcn_yaml(yaml, config)
      v.size.must_equal(1)
      v.first.warning?.must_equal(true)
    end

    it "suppresses a violation from a noqa anywhere in the task body" do
      yaml = "---\n- hosts: all\n  tasks:\n    - name: t\n" \
             "      ansible.builtin.command: echo hi # noqa: no-changed-when\n"
      rules = [NoChangedWhenRule.new] of Rule
      run_rules_yaml(yaml, rules).must_be_empty
    end

    it "still reports a different rule in the same task" do
      yaml = "---\n- hosts: all\n  tasks:\n    - name: t\n" \
             "      ansible.builtin.shell: echo hi | cat # noqa: risky-shell-pipe\n"
      rules = [NoChangedWhenRule.new, RiskyShellPipeRule.new] of Rule
      v = run_rules_yaml(yaml, rules)
      v.map(&.rule_id).must_equal(["no-changed-when"])
    end

    it "does not let a task-scoped noqa silence a file-level rule" do
      # yaml[line-length] is a matchyaml rule upstream: only a comment on
      # the violation's own line counts, not one elsewhere in the file.
      yaml = "---\n- hosts: all\n  tasks:\n    - name: t  # noqa: yaml[line-length]\n" \
             "      ansible.builtin.command: echo " + ("x" * 200) + "\n"
      rules = [YamlLineLengthRule.new] of Rule
      v = run_rules_yaml(yaml, rules)
      v.map(&.rule_id).must_equal(["yaml[line-length]"])
    end
  end
end
