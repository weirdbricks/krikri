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
  # An ANNOTATED tag (-a/-m) is a real, distinct git object from the
  # commit it points to - `git rev-parse v1-annotated` returns the tag
  # OBJECT's own SHA, not the commit's, unlike a lightweight tag like
  # v1 above (where rev-parse already returns the commit SHA directly).
  run!("cd #{path} && git tag -a v1-annotated -m 'annotated tag'")
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

  it "is idempotent (changed: false on a second identical run) when version: is an ANNOTATED tag" do
    # Real bug: resolve_ref's `git rev-parse <ref>` returned an
    # ANNOTATED tag's own object SHA rather than the commit it points
    # to, which never equaled #current_commit's `rev-parse HEAD` (always
    # a real commit SHA) - #update_repo's `target == before` idempotency
    # check never matched, so a second run always re-checked-out the
    # same commit and reported changed: true, never converging. Found
    # benchmarking robertdebock.earlyoom's own `version: v1.6` (an
    # annotated tag upstream).
    repo = tmp_path("git-fixture-annotated-tag")
    build_fixture_repo(repo)
    dest = tmp_path("git-clone-annotated-tag-dest")
    `rm -rf #{dest}`

    first = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1-annotated"})
    first["changed"].as_bool.should be_true

    second = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1-annotated"})
    second["changed"].as_bool.should be_false
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

  it "checks out a tag correctly when depth: is also given (shallow clone)" do
    # Real bug found benchmarking buluma.netdata (round 156): `clone`
    # shallow-cloned only the default branch's tip (`git clone --depth
    # N <repo>`) and then tried `git checkout <version>` against that
    # limited history - a tag/branch other than the default branch's
    # current tip was never fetched at all, failing with "pathspec
    # '<version>' did not match any file(s) known to git", while real
    # ansible-playbook succeeded (its own git module fetches a targeted
    # refspec for the requested ref at the given depth instead of just
    # shallow-cloning the default branch). v1 here is NOT on main's
    # current tip (main has since moved to "commit 2") - exactly the
    # shape that reproduces the bug.
    repo = tmp_path("git-fixture-tag-depth")
    build_fixture_repo(repo)
    dest = tmp_path("git-clone-tag-depth-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1", "depth" => "1"})

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
    File.read(File.join(dest, "file.txt")).strip.should eq("one")
  end

  it "falls back to a full clone + checkout when depth: is given but version: is a commit sha (not directly fetchable)" do
    repo = tmp_path("git-fixture-sha-depth")
    shas = build_fixture_repo(repo)
    dest = tmp_path("git-clone-sha-depth-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => shas["first_sha"], "depth" => "1"})

    result["changed"].as_bool.should be_true
    result["failed"].as_bool.should be_false
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
