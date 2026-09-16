require "../spec_helper"

# All of these specs operate on a throwaway local git repo / config file
# created fresh in spec/tmp for each example - never touching the real
# user/system git config.

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

private def build_repo(path : String)
  `rm -rf #{path}`
  Dir.mkdir_p(path)
  `cd #{path} && git init -q`
end

describe "git_config plugin" do
  it "sets a value with scope: local" do
    repo = tmp_path("git-config-local")
    build_repo(repo)

    result = PluginSpecHelper.run("git_config", {"name" => "user.email", "value" => "test@example.com", "scope" => "local", "repo" => repo})

    result["changed"].as_bool.should be_true
    `cd #{repo} && git config --local --get user.email`.strip.should eq("test@example.com")
  end

  it "is idempotent when the value is already set" do
    repo = tmp_path("git-config-idempotent")
    build_repo(repo)
    PluginSpecHelper.run("git_config", {"name" => "user.email", "value" => "test@example.com", "scope" => "local", "repo" => repo})

    result = PluginSpecHelper.run("git_config", {"name" => "user.email", "value" => "test@example.com", "scope" => "local", "repo" => repo})

    result["changed"].as_bool.should be_false
  end

  it "unsets a value with state: absent" do
    repo = tmp_path("git-config-absent")
    build_repo(repo)
    PluginSpecHelper.run("git_config", {"name" => "user.email", "value" => "test@example.com", "scope" => "local", "repo" => repo})

    result = PluginSpecHelper.run("git_config", {"name" => "user.email", "state" => "absent", "scope" => "local", "repo" => repo})

    result["changed"].as_bool.should be_true
    status = Process.run("git", ["config", "--local", "--get", "user.email"], chdir: repo)
    status.exit_code.should_not eq(0)
  end

  it "reports no change when unsetting a value that is already absent" do
    repo = tmp_path("git-config-absent-noop")
    build_repo(repo)

    result = PluginSpecHelper.run("git_config", {"name" => "user.email", "state" => "absent", "scope" => "local", "repo" => repo})

    result["changed"].as_bool.should be_false
  end

  it "writes to an ad-hoc file with scope: file" do
    file = tmp_path("git-config-adhoc-file")
    File.delete(file) if File.exists?(file)

    result = PluginSpecHelper.run("git_config", {"name" => "alias.st", "value" => "status", "scope" => "file", "file" => file})

    result["changed"].as_bool.should be_true
    File.read(file).should contain("st = status")
  end

  it "does not write in check mode" do
    repo = tmp_path("git-config-check-mode")
    build_repo(repo)

    result = PluginSpecHelper.run("git_config", {"name" => "user.email", "value" => "test@example.com", "scope" => "local", "repo" => repo, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.should be_true
    status = Process.run("git", ["config", "--local", "--get", "user.email"], chdir: repo)
    status.exit_code.should_not eq(0)
  end

  it "fails when scope: local is given without repo" do
    result = PluginSpecHelper.run("git_config", {"name" => "user.email", "value" => "x", "scope" => "local"})
    result["failed"].as_bool.should be_true
  end

  it "fails when state: present is given without a value" do
    repo = tmp_path("git-config-missing-value")
    build_repo(repo)

    result = PluginSpecHelper.run("git_config", {"name" => "user.email", "scope" => "local", "repo" => repo})
    result["failed"].as_bool.should be_true
  end

  it "reports real's missing-required-arguments wording for a missing name" do
    result = PluginSpecHelper.run("git_config", {} of String => String)
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing required arguments: name")
  end

  it "reports real's choices wordings in the spec's declaration order" do
    result = PluginSpecHelper.run("git_config", {"name" => "k", "value" => "v", "add_mode" => "bogus"})
    result["msg"].as_s.should eq("value of add_mode must be one of: add, replace-all, got: bogus")

    result = PluginSpecHelper.run("git_config", {"name" => "k", "value" => "v", "scope" => "bogus"})
    result["msg"].as_s.should eq("value of scope must be one of: file, local, global, system, got: bogus")

    result = PluginSpecHelper.run("git_config", {"name" => "k", "value" => "v", "state" => "bogus"})
    result["msg"].as_s.should eq("value of state must be one of: present, absent, got: bogus")
  end

  it "reports real's required_if wordings in declaration order" do
    result = PluginSpecHelper.run("git_config", {"name" => "k", "value" => "v", "scope" => "local"})
    result["msg"].as_s.should eq("scope is local but all of the following are missing: repo")

    result = PluginSpecHelper.run("git_config", {"name" => "k", "value" => "v", "scope" => "file"})
    result["msg"].as_s.should eq("scope is file but all of the following are missing: file")

    result = PluginSpecHelper.run("git_config", {"name" => "k", "state" => "present", "scope" => "global"})
    result["msg"].as_s.should eq("state is present but all of the following are missing: value")
  end

  it "reports real's unsupported-parameters wording" do
    result = PluginSpecHelper.run("git_config", {"name" => "k", "value" => "v", "scope" => "global", "krikri_param" => "yes"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("Unsupported parameters for (community.general.git_config) module: krikri_param. " \
                                 "Supported parameters include: add_mode, file, name, repo, scope, state, value.")
  end

  it "reports real's post-setup guard for an empty-string value (required_if only fires on a missing key)" do
    result = PluginSpecHelper.run("git_config", {"name" => "k", "value" => "", "scope" => "global"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("If state=present, a value must be specified. " \
                                 "Use the community.general.git_config_info module to read a config value.")
  end
end
