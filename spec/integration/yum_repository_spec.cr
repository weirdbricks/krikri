require "../spec_helper"
require "file_utils"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "yum_repository")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

private def repo_path(name : String) : String
  File.join(TMP_DIR, "#{name}.repo")
end

describe "yum_repository plugin" do
  it "writes a .repo file with keys sorted alphabetically and description as the name= field" do
    result = PluginSpecHelper.run("yum_repository", {
      "name"        => "epel",
      "description" => "EPEL YUM repo",
      "baseurl"     => "https://example.com/epel/$releasever/$basearch/",
      "gpgcheck"    => "true",
      "enabled"     => "true",
      "reposdir"    => TMP_DIR,
    })

    result["changed"].as_bool.should be_true
    File.read(repo_path("epel")).should eq(
      "[epel]\n" \
      "baseurl = https://example.com/epel/$releasever/$basearch/\n" \
      "enabled = 1\n" \
      "gpgcheck = 1\n" \
      "name = EPEL YUM repo\n" \
      "\n"
    )
  end

  it "reports changed: false on an idempotent rerun" do
    params = {
      "name"        => "idempotent",
      "description" => "Idempotent Repo",
      "baseurl"     => "https://example.com/repo",
      "reposdir"    => TMP_DIR,
    }
    PluginSpecHelper.run("yum_repository", params)

    result = PluginSpecHelper.run("yum_repository", params)

    result["changed"].as_bool.should be_false
  end

  it "regenerates the section from scratch each run, dropping keys not passed this time (matches real ansible-playbook, not a bug)" do
    PluginSpecHelper.run("yum_repository", {
      "name" => "regen", "description" => "d", "baseurl" => "https://example.com", "gpgcheck" => "true", "reposdir" => TMP_DIR,
    })

    PluginSpecHelper.run("yum_repository", {
      "name" => "regen", "description" => "d", "baseurl" => "https://example.com", "priority" => "10", "reposdir" => TMP_DIR,
    })

    content = File.read(repo_path("regen"))
    content.should contain("priority = 10")
    content.should_not contain("gpgcheck")
  end

  it "writes to file: instead of name: when given" do
    PluginSpecHelper.run("yum_repository", {
      "name" => "myrepo", "description" => "d", "baseurl" => "https://example.com", "file" => "custom-file", "reposdir" => TMP_DIR,
    })

    File.exists?(repo_path("custom-file")).should be_true
    File.exists?(repo_path("myrepo")).should be_false
  end

  it "removes the file on state: absent" do
    PluginSpecHelper.run("yum_repository", {
      "name" => "toremove", "description" => "d", "baseurl" => "https://example.com", "reposdir" => TMP_DIR,
    })

    result = PluginSpecHelper.run("yum_repository", {"name" => "toremove", "state" => "absent", "reposdir" => TMP_DIR})

    result["changed"].as_bool.should be_true
    File.exists?(repo_path("toremove")).should be_false
  end

  it "reports changed: false for state: absent when the file doesn't exist" do
    result = PluginSpecHelper.run("yum_repository", {"name" => "never-existed", "state" => "absent", "reposdir" => TMP_DIR})

    result["changed"].as_bool.should be_false
  end

  it "fails with a clear message when description is missing" do
    result = PluginSpecHelper.run("yum_repository", {"name" => "x", "baseurl" => "https://example.com", "reposdir" => TMP_DIR})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("description")
  end

  it "fails with a clear message when none of baseurl/mirrorlist/metalink is given" do
    result = PluginSpecHelper.run("yum_repository", {"name" => "x", "description" => "d", "reposdir" => TMP_DIR})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("baseurl")
  end

  it "space-joins list parameters like gpgkey on one line" do
    PluginSpecHelper.run("yum_repository", {
      "name"        => "listtest",
      "description" => "d",
      "baseurl"     => "https://example.com",
      "gpgkey"      => "https://example.com/key1,https://example.com/key2",
      "reposdir"    => TMP_DIR,
    })

    File.read(repo_path("listtest")).should contain("gpgkey = https://example.com/key1 https://example.com/key2")
  end
end
