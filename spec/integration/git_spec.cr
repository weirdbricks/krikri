require "../spec_helper"

# All of these specs clone from a throwaway local git repository (created
# fresh in spec/tmp for each example that needs a fixture), never touching
# a network or a real remote - fully safe to run repeatedly.

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp")

Spec.before_suite do
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

private def run!(command : String)
  status = Process.run("/bin/sh", ["-c", command], output: Process::Redirect::Close, error: Process::Redirect::Close)
  raise "command failed: #{command}" unless status.success?
end

# Builds a small local repo with two commits on `main`, a "v1" tag on the
# first commit, and a "feature" branch with a third commit - enough to
# exercise clone, update, and version: (branch/tag/sha) checkout.
private def build_fixture_repo(path : String) : Hash(String, String)
  `rm -rf #{path}`
  Dir.mkdir_p(path)
  run!("cd #{path} && git init -q -b main")
  run!("cd #{path} && git config user.email test@example.com && git config user.name Test")
  run!("cd #{path} && echo one > file.txt && git add file.txt && git commit -q -m 'commit 1'")
  run!("cd #{path} && git tag v1")
  first_sha = `cd #{path} && git rev-parse HEAD`.strip

  run!("cd #{path} && echo two > file.txt && git commit -q -am 'commit 2'")
  second_sha = `cd #{path} && git rev-parse HEAD`.strip

  run!("cd #{path} && git checkout -q -b feature")
  run!("cd #{path} && echo three > file.txt && git commit -q -am 'commit 3 on feature'")
  run!("cd #{path} && git checkout -q main")

  {"first_sha" => first_sha, "second_sha" => second_sha}
end

describe "git plugin" do
  it "clones a fresh repository" do
    repo = tmp_path("git-fixture-clone")
    build_fixture_repo(repo)
    dest = tmp_path("git-clone-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})

    result["changed"].as_bool.should be_true
    Dir.exists?(File.join(dest, ".git")).should be_true
    File.read(File.join(dest, "file.txt")).strip.should eq("two")
  end

  it "checks out a specific tag when version: is given" do
    repo = tmp_path("git-fixture-tag")
    build_fixture_repo(repo)
    dest = tmp_path("git-clone-tag-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1"})

    result["changed"].as_bool.should be_true
    File.read(File.join(dest, "file.txt")).strip.should eq("one")
  end

  it "does not clone in check mode" do
    repo = tmp_path("git-fixture-check-mode")
    build_fixture_repo(repo)
    dest = tmp_path("git-clone-check-mode-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    Dir.exists?(dest).should be_false
  end

  it "reports no change when the repo is already up to date" do
    repo = tmp_path("git-fixture-uptodate")
    build_fixture_repo(repo)
    dest = tmp_path("git-uptodate-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})

    result["changed"].as_bool.should be_false
    result["msg"].as_s.should contain("up to date")
  end

  it "updates to a new commit pushed to the source repo" do
    repo = tmp_path("git-fixture-update")
    shas = build_fixture_repo(repo)
    dest = tmp_path("git-update-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1"})
    File.read(File.join(dest, "file.txt")).strip.should eq("one")

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "main"})

    result["changed"].as_bool.should be_true
    result["after"].as_s.should eq(shas["second_sha"])
    File.read(File.join(dest, "file.txt")).strip.should eq("two")
  end

  it "switches to a different branch on update" do
    repo = tmp_path("git-fixture-branch")
    build_fixture_repo(repo)
    dest = tmp_path("git-branch-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "main"})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "feature"})

    result["changed"].as_bool.should be_true
    File.read(File.join(dest, "file.txt")).strip.should eq("three")
  end

  it "does not update in check mode" do
    repo = tmp_path("git-fixture-update-check-mode")
    build_fixture_repo(repo)
    dest = tmp_path("git-update-check-mode-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1"})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "main", "check_mode" => "true"})

    result["changed"].as_bool.should be_true
    File.read(File.join(dest, "file.txt")).strip.should eq("one")
  end

  it "does not fetch/update when update: no" do
    repo = tmp_path("git-fixture-noupdate")
    build_fixture_repo(repo)
    dest = tmp_path("git-noupdate-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1"})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "main", "update" => "no"})

    result["changed"].as_bool.should be_false
    File.read(File.join(dest, "file.txt")).strip.should eq("one")
  end

  it "fails with a clear message for an unresolvable version" do
    repo = tmp_path("git-fixture-badversion")
    build_fixture_repo(repo)
    dest = tmp_path("git-badversion-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "does-not-exist"})

    result["failed"].as_bool.should be_true
  end

  it "fails with a clear message when repo or dest is missing" do
    result = PluginSpecHelper.run("git", {"dest" => tmp_path("whatever")})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("repo")
  end
end
