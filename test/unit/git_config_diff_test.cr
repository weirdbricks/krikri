require "../minitest_helper"

# Pins plugins/git_config.cr's write-path `diff` key against real
# community.general git_config (live-verified vs ansible-core 2.19.11):
# every exit that reports changed: true carries
# diff={before_header, before, after_header, after}, where both headers
# are " ".join(set_args) and before/after run through real's
# build_diff_value - empty -> "\n", single -> "value\n", several -> the
# list itself. The check-mode path carries the same diff (real only
# skips the run_command).

describe "git_config diff" do
  it "carries real's diff dict on a setting change" do
    file = PluginSpecHelper.tmp_path("gitcfg-diff-set.gitconfig")

    result = PluginSpecHelper.run("git_config", {
      "name"  => "user.name",
      "value" => "Test User",
      "scope" => "file",
      "file"  => file,
    })

    result["changed"].as_bool.must_equal(true)
    diff = result["diff"].as_h
    diff["before"].as_s.must_equal("\n")
    diff["after"].as_s.must_equal("Test User\n")
    diff["before_header"].as_s.must_equal(diff["after_header"].as_s)
    diff["before_header"].as_s.includes?("--replace-all user.name Test User").must_equal(true)
  end

  it "reports the prior value as before and the new one as after on a change" do
    file = PluginSpecHelper.tmp_path("gitcfg-diff-change.gitconfig")
    PluginSpecHelper.run("git_config", {"name" => "user.name", "value" => "First", "scope" => "file", "file" => file})

    result = PluginSpecHelper.run("git_config", {"name" => "user.name", "value" => "Second", "scope" => "file", "file" => file})

    result["changed"].as_bool.must_equal(true)
    diff = result["diff"].as_h
    diff["before"].as_s.must_equal("First\n")
    diff["after"].as_s.must_equal("Second\n")
  end

  it "emits after as a list when add_mode: add stacks a second value" do
    file = PluginSpecHelper.tmp_path("gitcfg-diff-add.gitconfig")
    PluginSpecHelper.run("git_config", {"name" => "user.mail", "value" => "v1", "scope" => "file", "file" => file})

    result = PluginSpecHelper.run("git_config", {"name" => "user.mail", "value" => "v2", "scope" => "file", "file" => file, "add_mode" => "add"})

    result["changed"].as_bool.must_equal(true)
    diff = result["diff"].as_h
    diff["before"].as_s.must_equal("v1\n")
    diff["after"].as_a.map(&.as_s).must_equal(["v1", "v2"])
  end

  it "carries the diff on the unset path with after wiped" do
    file = PluginSpecHelper.tmp_path("gitcfg-diff-unset.gitconfig")
    PluginSpecHelper.run("git_config", {"name" => "user.name", "value" => "Test User", "scope" => "file", "file" => file})

    result = PluginSpecHelper.run("git_config", {"name" => "user.name", "state" => "absent", "scope" => "file", "file" => file})

    result["changed"].as_bool.must_equal(true)
    diff = result["diff"].as_h
    diff["before"].as_s.must_equal("Test User\n")
    diff["after"].as_s.must_equal("\n")
  end

  it "carries the diff in check mode too, without writing" do
    file = PluginSpecHelper.tmp_path("gitcfg-diff-check.gitconfig")

    result = PluginSpecHelper.run("git_config", {
      "name"                => "user.name",
      "value"               => "Test User",
      "scope"               => "file",
      "file"                => file,
      "_ansible_check_mode" => "true",
    })

    result["changed"].as_bool.must_equal(true)
    result["diff"].as_h["before"].as_s.must_equal("\n")
    result["diff"].as_h["after"].as_s.must_equal("Test User\n")
    File.exists?(file).must_equal(false)
  end

  it "keeps the converged no-op path diff-free" do
    file = PluginSpecHelper.tmp_path("gitcfg-diff-noop.gitconfig")
    params = {"name" => "user.name", "value" => "Same", "scope" => "file", "file" => file}
    PluginSpecHelper.run("git_config", params)
    result = PluginSpecHelper.run("git_config", params)

    result["changed"].as_bool.must_equal(false)
    result.as_h.has_key?("diff").must_equal(false)
  end
end
