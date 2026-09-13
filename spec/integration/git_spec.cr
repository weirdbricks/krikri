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

# Newer git blocks the file:// protocol for submodule operations by default
# (CVE-2022-39253 hardening); these per-invocation config env vars re-enable
# it for the plugin's own git calls without touching any global git config.
private FILE_PROTOCOL_ENV = %({"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "protocol.file.allow", "GIT_CONFIG_VALUE_0": "always"})

# Builds the fixture repo plus a separate sub repo added to it as a
# submodule (pinned at sub's current tip). The sub repo uses branch
# `master` so track_submodules:'s hardcoded <remote>/master comparison
# (mirroring real Ansible) resolves.
private def build_submodule_fixture(main_path : String, sub_path : String) : Nil
  build_fixture_repo(main_path)
  `rm -rf #{sub_path}`
  Dir.mkdir_p(sub_path)
  run!("cd #{sub_path} && git init -q -b master")
  run!("cd #{sub_path} && git config user.email test@example.com && git config user.name Test")
  run!("cd #{sub_path} && echo one > sub.txt && git add sub.txt && git commit -q -m 'sub commit 1'")
  run!("cd #{main_path} && git -c protocol.file.allow=always submodule add file://#{sub_path} sub")
  run!("cd #{main_path} && git commit -q -m 'add submodule'")
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
    result["failed"]?.try(&.as_bool).should be_falsey
    File.read(File.join(dest, "file.txt")).strip.should eq("one")
  end

  it "falls back to a full clone + checkout when depth: is given but version: is a commit sha (not directly fetchable)" do
    repo = tmp_path("git-fixture-sha-depth")
    shas = build_fixture_repo(repo)
    dest = tmp_path("git-clone-sha-depth-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => shas["first_sha"], "depth" => "1"})

    result["changed"].as_bool.should be_true
    result["failed"]?.try(&.as_bool).should be_falsey
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

private def write_exec_shim(path : String, log : String, accept_version_probe : Bool = false) : Nil
  probe_guard = accept_version_probe ? %([ "$2" = "-V" ] && exit 0 || true\n) : ""
  # A -V probe (accept_newhostkey's ssh support check) exits 0 without
  # logging; a real transport invocation is logged and then fails, since a
  # fake ssh can never complete a real clone.
  File.write(path, "#!/bin/sh\n#{probe_guard}echo \"$@\" >> #{log}\nexit 1\n")
  File.chmod(path, 0o755)
end

describe "git plugin param coverage" do
  it "fails when dest is missing but clone is allowed" do
    repo = tmp_path("git-fixture-nodest")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {"repo" => repo})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("destination directory")
  end

  it "supports clone: no by reporting the remote head without touching dest" do
    repo = tmp_path("git-fixture-cloneno")
    shas = build_fixture_repo(repo)
    dest = tmp_path("git-cloneno-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "clone" => "no", "update" => "no"})

    result["changed"].as_bool.should be_true
    Dir.exists?(dest).should be_false
    result["after"].as_s.should eq(shas["second_sha"])
  end

  it "uses remote: for the clone remote and for update fetches" do
    repo = tmp_path("git-fixture-remote")
    build_fixture_repo(repo)
    dest = tmp_path("git-remote-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "remote" => "upstream"})

    result["failed"]?.try(&.as_bool).should be_falsey
    remotes = `git -C #{dest} remote`.strip
    remotes.should eq("upstream")
    `git -C #{dest} config --get remote.upstream.url`.strip.should_not be_empty

    second = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "remote" => "upstream"})
    second["changed"].as_bool.should be_false
    second["msg"].as_s.should contain("up to date")
  end

  it "clones with --single-branch when single_branch: is set" do
    repo = tmp_path("git-fixture-singlebranch")
    build_fixture_repo(repo)
    dest = tmp_path("git-singlebranch-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "feature", "single_branch" => "yes"})

    result["failed"]?.try(&.as_bool).should be_falsey
    branches = `git -C #{dest} branch`.lines.map(&.strip).reject(&.empty?)
    branches.should eq(["* feature"])
    File.read(File.join(dest, "file.txt")).strip.should eq("three")
  end

  it "clones a bare repository with bare: yes" do
    repo = tmp_path("git-fixture-bare")
    build_fixture_repo(repo)
    dest = tmp_path("git-bare-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "bare" => "yes"})

    result["failed"]?.try(&.as_bool).should be_falsey
    File.exists?(File.join(dest, "HEAD")).should be_true
    Dir.exists?(File.join(dest, ".git")).should be_false
  end

  it "places the git dir at separate_git_dir: and leaves a gitdir pointer" do
    repo = tmp_path("git-fixture-sepdir")
    build_fixture_repo(repo)
    dest = tmp_path("git-sepdir-dest")
    sep = tmp_path("git-sepdir-gitdir")
    `rm -rf #{dest} #{sep}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "separate_git_dir" => sep})

    result["failed"]?.try(&.as_bool).should be_falsey
    File.file?(File.join(dest, ".git")).should be_true
    File.read(File.join(dest, ".git")).strip.should eq("gitdir: #{sep}")
    File.exists?(File.join(sep, "config")).should be_true
  end

  it "applies umask: to files created by the checkout" do
    repo = tmp_path("git-fixture-umask")
    build_fixture_repo(repo)
    dest = tmp_path("git-umask-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "umask" => "077"})

    result["failed"]?.try(&.as_bool).should be_falsey
    perms = File.info(File.join(dest, "file.txt")).permissions.value
    (perms & 0o077).should eq(0)
  end

  it "fails for a non-octal umask" do
    repo = tmp_path("git-fixture-umask-bad")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => tmp_path("git-umask-bad-dest"), "umask" => "abc"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("umask must be an octal integer")
  end

  it "fails verify_commit: on an unsigned commit" do
    repo = tmp_path("git-fixture-verify")
    build_fixture_repo(repo)
    dest = tmp_path("git-verify-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "verify_commit" => "yes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Failed to verify GPG signature")
  end

  it "uses executable: instead of the plain git binary" do
    repo = tmp_path("git-fixture-executable")
    build_fixture_repo(repo)
    dest = tmp_path("git-executable-dest")
    `rm -rf #{dest}`
    shim = tmp_path("git-shim")
    log = tmp_path("git-shim.log")
    File.delete(log) if File.exists?(log)
    File.write(shim, "#!/bin/sh\necho \"$@\" >> #{log}\nexec git \"$@\"\n")
    File.chmod(shim, 0o755)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "executable" => shim})

    result["failed"]?.try(&.as_bool).should be_falsey
    File.read(File.join(dest, "file.txt")).strip.should eq("two")
    File.exists?(log).should be_true
    File.read(log).should contain("clone")
  end

  it "builds GIT_SSH_COMMAND from ssh_opts:, key_file: and accept_hostkey:" do
    repo = tmp_path("git-fixture-ssh")
    build_fixture_repo(repo)
    dest = tmp_path("git-ssh-dest")
    `rm -rf #{dest}`
    shim_dir = tmp_path("ssh-shim-dir")
    Dir.mkdir_p(shim_dir)
    log = tmp_path("ssh-shim.log")
    File.delete(log) if File.exists?(log)
    write_exec_shim(File.join(shim_dir, "ssh"), log)
    env = %({"PATH": "#{shim_dir}:#{ENV["PATH"]}"})

    result = PluginSpecHelper.run("git", {
      "repo"           => "ssh://git@example.com/example/example.git",
      "dest"           => dest,
      "ssh_opts"       => "-o Port=2222",
      "key_file"       => "/tmp/id_test",
      "accept_hostkey" => "yes",
      "_environment"   => env,
    })

    result["failed"].as_bool.should be_true
    logged = File.read(log)
    logged.should contain("-o Port=2222")
    logged.should contain("-o StrictHostKeyChecking=no")
    logged.should contain("-o BatchMode=yes")
    logged.should contain("-i /tmp/id_test")
    logged.should contain("-o IdentitiesOnly=yes")
  end

  it "adds StrictHostKeyChecking=accept-new for accept_newhostkey:" do
    repo = tmp_path("git-fixture-ssh-newkey")
    build_fixture_repo(repo)
    dest = tmp_path("git-ssh-newkey-dest")
    `rm -rf #{dest}`
    shim_dir = tmp_path("ssh-shim-dir-newkey")
    Dir.mkdir_p(shim_dir)
    log = tmp_path("ssh-shim-newkey.log")
    File.delete(log) if File.exists?(log)
    write_exec_shim(File.join(shim_dir, "ssh"), log, accept_version_probe: true)
    env = %({"PATH": "#{shim_dir}:#{ENV["PATH"]}"})

    result = PluginSpecHelper.run("git", {
      "repo"              => "ssh://git@example.com/example/example.git",
      "dest"              => dest,
      "accept_newhostkey" => "yes",
      "_environment"      => env,
    })

    result["failed"].as_bool.should be_true
    File.read(log).should contain("-o StrictHostKeyChecking=accept-new")
    File.read(log).should_not contain("StrictHostKeyChecking=no")
  end

  it "rejects mutually exclusive separate_git_dir and bare" do
    repo = tmp_path("git-fixture-mx1")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => tmp_path("git-mx1-dest"),
                                          "separate_git_dir" => tmp_path("git-mx1-gitdir"), "bare" => "yes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: separate_git_dir|bare")
  end

  it "rejects mutually exclusive accept_hostkey and accept_newhostkey" do
    repo = tmp_path("git-fixture-mx2")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => tmp_path("git-mx2-dest"),
                                          "accept_hostkey" => "yes", "accept_newhostkey" => "yes"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("parameters are mutually exclusive: accept_hostkey|accept_newhostkey")
  end

  it "requires archive when archive_prefix is given" do
    repo = tmp_path("git-fixture-reqby")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => tmp_path("git-reqby-dest"),
                                          "archive_prefix" => "prefix/"})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("missing parameter(s) required by 'archive_prefix': archive")
  end

  it "creates a tar archive with archive: and is idempotent on a second run" do
    repo = tmp_path("git-fixture-archive")
    build_fixture_repo(repo)
    dest = tmp_path("git-archive-dest")
    `rm -rf #{dest}`
    tarball = tmp_path("git-archive.tar")
    File.delete(tarball) if File.exists?(tarball)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "archive" => tarball})

    result["changed"].as_bool.should be_true
    File.exists?(tarball).should be_true
    `tar -tf #{tarball}`.should contain("file.txt")

    second = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "archive" => tarball})
    second["changed"].as_bool.should be_false
  end

  it "adds archive_prefix: paths inside the archive" do
    repo = tmp_path("git-fixture-archiveprefix")
    build_fixture_repo(repo)
    dest = tmp_path("git-archiveprefix-dest")
    `rm -rf #{dest}`
    tarball = tmp_path("git-archiveprefix.tar")
    File.delete(tarball) if File.exists?(tarball)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest,
                                          "archive" => tarball, "archive_prefix" => "root/"})

    result["failed"]?.try(&.as_bool).should be_falsey
    `tar -tf #{tarball}`.should contain("root/file.txt")
  end

  it "fails for an archive: path with an unsupported extension" do
    repo = tmp_path("git-fixture-archiveext")
    build_fixture_repo(repo)
    dest = tmp_path("git-archiveext-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest,
                                          "archive" => tmp_path("git-archive.rar")})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Unable to get file extension")
  end

  it "uses reference: as a local object store on clone (creates alternates)" do
    repo = tmp_path("git-fixture-reference")
    build_fixture_repo(repo)
    reference = tmp_path("git-reference-repo")
    `rm -rf #{reference}`
    run!("git clone -q #{repo} #{reference}")
    dest = tmp_path("git-reference-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "reference" => reference})

    result["failed"]?.try(&.as_bool).should be_falsey
    File.exists?(File.join(dest, ".git", "objects", "info", "alternates")).should be_true
    File.read(File.join(dest, "file.txt")).strip.should eq("two")
  end

  it "fetches refspec: on a fresh shallow clone before checkout" do
    repo = tmp_path("git-fixture-refspec-clone")
    build_fixture_repo(repo)
    dest = tmp_path("git-refspec-clone-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "depth" => "1",
                                          "version" => "feature", "refspec" => "+refs/heads/feature:refs/remotes/origin/feature"})

    result["failed"]?.try(&.as_bool).should be_falsey
    File.read(File.join(dest, "file.txt")).strip.should eq("three")
  end

  it "fetches refspec: on update to reach a branch a shallow clone skipped" do
    repo = tmp_path("git-fixture-refspec-update")
    build_fixture_repo(repo)
    dest = tmp_path("git-refspec-update-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "depth" => "1"})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "depth" => "1",
                                          "version" => "feature", "refspec" => "+refs/heads/feature:refs/remotes/origin/feature"})

    result["failed"]?.try(&.as_bool).should be_falsey
    File.read(File.join(dest, "file.txt")).strip.should eq("three")
  end

  it "fails when local modifications exist and force: is not set" do
    repo = tmp_path("git-fixture-localmods")
    build_fixture_repo(repo)
    dest = tmp_path("git-localmods-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})
    File.write(File.join(dest, "file.txt"), "local edit\n")

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})

    result["failed"].as_bool.should be_true
    result["msg"].as_s.should contain("Local modifications exist")

    forced = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "force" => "yes"})
    forced["failed"]?.try(&.as_bool).should be_falsey
    File.read(File.join(dest, "file.txt")).strip.should eq("two")
  end

  it "initializes submodules on clone (recursive default yes)" do
    main = tmp_path("git-fixture-submodules")
    sub = tmp_path("git-fixture-submodules-sub")
    build_submodule_fixture(main, sub)
    dest = tmp_path("git-submodules-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {
      "repo"         => main,
      "dest"         => dest,
      "_environment" => FILE_PROTOCOL_ENV,
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    File.read(File.join(dest, "sub", "sub.txt")).strip.should eq("one")
  end

  it "skips submodules on clone when recursive: is no" do
    main = tmp_path("git-fixture-submodules-no")
    sub = tmp_path("git-fixture-submodules-no-sub")
    build_submodule_fixture(main, sub)
    dest = tmp_path("git-submodules-no-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {
      "repo"         => main,
      "dest"         => dest,
      "recursive"    => "no",
      "_environment" => FILE_PROTOCOL_ENV,
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    File.exists?(File.join(dest, "sub", "sub.txt")).should be_false
  end

  it "tracks submodule branches with track_submodules: yes" do
    main = tmp_path("git-fixture-tracksub")
    sub = tmp_path("git-fixture-tracksub-sub")
    build_submodule_fixture(main, sub)
    # Advance the submodule repo after the superproject pinned it, so only
    # --remote tracking can pick up the new tip.
    run!("cd #{sub} && echo two > sub.txt && git commit -qam 'sub commit 2'")
    dest = tmp_path("git-tracksub-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {
      "repo"             => main,
      "dest"             => dest,
      "track_submodules" => "yes",
      "_environment"     => FILE_PROTOCOL_ENV,
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    File.read(File.join(dest, "sub", "sub.txt")).strip.should eq("two")
  end
end
