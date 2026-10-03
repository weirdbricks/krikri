require "../minitest_helper"

# All of these specs clone from a throwaway local git repository (created
# fresh in spec/tmp for each example that needs a fixture), never touching
# a network or a real remote - fully safe to run repeatedly.

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead.
private def tmp_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
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

    result["changed"].as_bool.must_equal(true)
    Dir.exists?(File.join(dest, ".git")).must_equal(true)
    File.read(File.join(dest, "file.txt")).strip.must_equal("two")
  end

  it "checks out a specific tag when version: is given" do
    repo = tmp_path("git-fixture-tag")
    build_fixture_repo(repo)
    dest = tmp_path("git-clone-tag-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1"})

    result["changed"].as_bool.must_equal(true)
    File.read(File.join(dest, "file.txt")).strip.must_equal("one")
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
    first["changed"].as_bool.must_equal(true)

    second = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1-annotated"})
    second["changed"].as_bool.must_equal(false)
  end

  it "does not clone in check mode" do
    repo = tmp_path("git-fixture-check-mode")
    build_fixture_repo(repo)
    dest = tmp_path("git-clone-check-mode-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    Dir.exists?(dest).must_equal(false)
  end

  it "reports no change when the repo is already up to date" do
    repo = tmp_path("git-fixture-uptodate")
    build_fixture_repo(repo)
    dest = tmp_path("git-uptodate-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})

    result["changed"].as_bool.must_equal(false)
    result["msg"].as_s.must_include("up to date")
  end

  it "updates to a new commit pushed to the source repo" do
    repo = tmp_path("git-fixture-update")
    shas = build_fixture_repo(repo)
    dest = tmp_path("git-update-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1"})
    File.read(File.join(dest, "file.txt")).strip.must_equal("one")

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "main"})

    result["changed"].as_bool.must_equal(true)
    result["after"].as_s.must_equal(shas["second_sha"])
    File.read(File.join(dest, "file.txt")).strip.must_equal("two")
  end

  it "switches to a different branch on update" do
    repo = tmp_path("git-fixture-branch")
    build_fixture_repo(repo)
    dest = tmp_path("git-branch-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "main"})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "feature"})

    result["changed"].as_bool.must_equal(true)
    File.read(File.join(dest, "file.txt")).strip.must_equal("three")
  end

  it "does not update in check mode" do
    repo = tmp_path("git-fixture-update-check-mode")
    build_fixture_repo(repo)
    dest = tmp_path("git-update-check-mode-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1"})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "main", "_ansible_check_mode" => "true"})

    result["changed"].as_bool.must_equal(true)
    File.read(File.join(dest, "file.txt")).strip.must_equal("one")
  end

  it "does not fetch/update when update: no" do
    repo = tmp_path("git-fixture-noupdate")
    build_fixture_repo(repo)
    dest = tmp_path("git-noupdate-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "v1"})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "main", "update" => "no"})

    result["changed"].as_bool.must_equal(false)
    File.read(File.join(dest, "file.txt")).strip.must_equal("one")
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

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(File.join(dest, "file.txt")).strip.must_equal("one")
  end

  it "falls back to a full clone + checkout when depth: is given but version: is a commit sha (not directly fetchable)" do
    repo = tmp_path("git-fixture-sha-depth")
    shas = build_fixture_repo(repo)
    dest = tmp_path("git-clone-sha-depth-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => shas["first_sha"], "depth" => "1"})

    result["changed"].as_bool.must_equal(true)
    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(File.join(dest, "file.txt")).strip.must_equal("one")
  end

  it "fails with a clear message for an unresolvable version" do
    repo = tmp_path("git-fixture-badversion")
    build_fixture_repo(repo)
    dest = tmp_path("git-badversion-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "does-not-exist"})

    result["failed"].as_bool.must_equal(true)
  end

  it "fails with a clear message when repo or dest is missing" do
    result = PluginSpecHelper.run("git", {"dest" => tmp_path("whatever")})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("repo")
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

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("destination directory")
  end

  it "supports clone: no by reporting the remote head without touching dest" do
    repo = tmp_path("git-fixture-cloneno")
    shas = build_fixture_repo(repo)
    dest = tmp_path("git-cloneno-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "clone" => "no", "update" => "no"})

    result["changed"].as_bool.must_equal(true)
    Dir.exists?(dest).must_equal(false)
    result["after"].as_s.must_equal(shas["second_sha"])
  end

  it "uses remote: for the clone remote and for update fetches" do
    repo = tmp_path("git-fixture-remote")
    build_fixture_repo(repo)
    dest = tmp_path("git-remote-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "remote" => "upstream"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    remotes = `git -C #{dest} remote`.strip
    remotes.must_equal("upstream")
    `git -C #{dest} config --get remote.upstream.url`.strip.wont_be_empty

    second = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "remote" => "upstream"})
    second["changed"].as_bool.must_equal(false)
    second["msg"].as_s.must_include("up to date")
  end

  it "clones with --single-branch when single_branch: is set" do
    repo = tmp_path("git-fixture-singlebranch")
    build_fixture_repo(repo)
    dest = tmp_path("git-singlebranch-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "feature", "single_branch" => "yes"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    branches = `git -C #{dest} branch`.lines.map(&.strip).reject(&.empty?)
    branches.must_equal(["* feature"])
    File.read(File.join(dest, "file.txt")).strip.must_equal("three")
  end

  it "clones a bare repository with bare: yes" do
    repo = tmp_path("git-fixture-bare")
    build_fixture_repo(repo)
    dest = tmp_path("git-bare-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "bare" => "yes"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.exists?(File.join(dest, "HEAD")).must_equal(true)
    Dir.exists?(File.join(dest, ".git")).must_equal(false)
  end

  it "places the git dir at separate_git_dir: and leaves a gitdir pointer" do
    repo = tmp_path("git-fixture-sepdir")
    build_fixture_repo(repo)
    dest = tmp_path("git-sepdir-dest")
    sep = tmp_path("git-sepdir-gitdir")
    `rm -rf #{dest} #{sep}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "separate_git_dir" => sep})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.file?(File.join(dest, ".git")).must_equal(true)
    File.read(File.join(dest, ".git")).strip.must_equal("gitdir: #{sep}")
    File.exists?(File.join(sep, "config")).must_equal(true)
  end

  it "applies umask: to files created by the checkout" do
    repo = tmp_path("git-fixture-umask")
    build_fixture_repo(repo)
    dest = tmp_path("git-umask-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "umask" => "077"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    perms = File.info(File.join(dest, "file.txt")).permissions.value
    (perms & 0o077).must_equal(0)
  end

  it "fails for a non-octal umask" do
    repo = tmp_path("git-fixture-umask-bad")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => tmp_path("git-umask-bad-dest"), "umask" => "abc"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("umask must be an octal integer")
  end

  it "fails verify_commit: on an unsigned commit" do
    repo = tmp_path("git-fixture-verify")
    build_fixture_repo(repo)
    dest = tmp_path("git-verify-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "verify_commit" => "yes"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Failed to verify GPG signature")
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

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(File.join(dest, "file.txt")).strip.must_equal("two")
    File.exists?(log).must_equal(true)
    File.read(log).must_include("clone")
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

    result["failed"].as_bool.must_equal(true)
    logged = File.read(log)
    logged.must_include("-o Port=2222")
    logged.must_include("-o StrictHostKeyChecking=no")
    logged.must_include("-o BatchMode=yes")
    logged.must_include("-i /tmp/id_test")
    logged.must_include("-o IdentitiesOnly=yes")
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

    result["failed"].as_bool.must_equal(true)
    File.read(log).must_include("-o StrictHostKeyChecking=accept-new")
    File.read(log).wont_include("StrictHostKeyChecking=no")
  end

  it "rejects mutually exclusive separate_git_dir and bare" do
    repo = tmp_path("git-fixture-mx1")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => tmp_path("git-mx1-dest"),
                                          "separate_git_dir" => tmp_path("git-mx1-gitdir"), "bare" => "yes"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: separate_git_dir|bare")
  end

  it "rejects mutually exclusive accept_hostkey and accept_newhostkey" do
    repo = tmp_path("git-fixture-mx2")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => tmp_path("git-mx2-dest"),
                                          "accept_hostkey" => "yes", "accept_newhostkey" => "yes"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("parameters are mutually exclusive: accept_hostkey|accept_newhostkey")
  end

  it "requires archive when archive_prefix is given" do
    repo = tmp_path("git-fixture-reqby")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => tmp_path("git-reqby-dest"),
                                          "archive_prefix" => "prefix/"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("missing parameter(s) required by 'archive_prefix': archive")
  end

  it "creates a tar archive with archive: and is idempotent on a second run" do
    repo = tmp_path("git-fixture-archive")
    build_fixture_repo(repo)
    dest = tmp_path("git-archive-dest")
    `rm -rf #{dest}`
    tarball = tmp_path("git-archive.tar")
    File.delete(tarball) if File.exists?(tarball)

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "archive" => tarball})

    result["changed"].as_bool.must_equal(true)
    File.exists?(tarball).must_equal(true)
    `tar -tf #{tarball}`.must_include("file.txt")

    second = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "archive" => tarball})
    second["changed"].as_bool.must_equal(false)
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

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    `tar -tf #{tarball}`.must_include("root/file.txt")
  end

  it "fails for an archive: path with an unsupported extension" do
    repo = tmp_path("git-fixture-archiveext")
    build_fixture_repo(repo)
    dest = tmp_path("git-archiveext-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest,
                                          "archive" => tmp_path("git-archive.rar")})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Unable to get file extension")
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

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.exists?(File.join(dest, ".git", "objects", "info", "alternates")).must_equal(true)
    File.read(File.join(dest, "file.txt")).strip.must_equal("two")
  end

  it "fetches refspec: on a fresh shallow clone before checkout" do
    repo = tmp_path("git-fixture-refspec-clone")
    build_fixture_repo(repo)
    dest = tmp_path("git-refspec-clone-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "depth" => "1",
                                          "version" => "feature", "refspec" => "+refs/heads/feature:refs/remotes/origin/feature"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(File.join(dest, "file.txt")).strip.must_equal("three")
  end

  it "fetches refspec: on update to reach a branch a shallow clone skipped" do
    repo = tmp_path("git-fixture-refspec-update")
    build_fixture_repo(repo)
    dest = tmp_path("git-refspec-update-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "depth" => "1"})

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "depth" => "1",
                                          "version" => "feature", "refspec" => "+refs/heads/feature:refs/remotes/origin/feature"})

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(File.join(dest, "file.txt")).strip.must_equal("three")
  end

  it "fails when local modifications exist and force: is not set" do
    repo = tmp_path("git-fixture-localmods")
    build_fixture_repo(repo)
    dest = tmp_path("git-localmods-dest")
    `rm -rf #{dest}`
    PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})
    File.write(File.join(dest, "file.txt"), "local edit\n")

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Local modifications exist")

    forced = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "force" => "yes"})
    falsey?(forced["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(File.join(dest, "file.txt")).strip.must_equal("two")
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

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(File.join(dest, "sub", "sub.txt")).strip.must_equal("one")
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

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.exists?(File.join(dest, "sub", "sub.txt")).must_equal(false)
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

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    File.read(File.join(dest, "sub", "sub.txt")).strip.must_equal("two")
  end

  # --- Failure-result shape parity with ansible.builtin.git -------------
  #
  # git.py reports each failure through a DIFFERENT shape, depending on
  # whether the command ran under run_command(check_rc=True) (basic.py's
  # own failure: the rstripped stderr as msg, plus cmd/rc/stdout/stderr)
  # or through one of the module's own fail_json(msg=..., stdout=, stderr=,
  # rc=, cmd=) sites. It never appends the command output to a
  # "Failed to <action>: <output>" message. Every expectation below was
  # read off ansible-playbook 2.19.11's own git.py and confirmed against
  # a live 2.19.11 run.

  it "fails a checkout of a nonexistent ref with git.py's own message and fields" do
    repo = tmp_path("git-fixture-checkout-fail")
    build_fixture_repo(repo)
    dest = tmp_path("git-checkout-fail-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest, "version" => "no-such-ref"})

    result["failed"].as_bool.must_equal(true)
    # switch_version()'s fail_json: the message is the module's own
    # wording, and the pathspec error is NOT appended to it.
    result["msg"].as_s.must_equal("Failed to checkout no-such-ref")
    # ... with the command, its rc, and both streams as siblings.
    result["cmd"].as_s.must_include("checkout --force no-such-ref")
    result["rc"].as_i64.must_equal(1)
    result["stderr"].as_s.must_include("did not match any file(s) known to git")
    result["stdout"].as_s.must_equal("")
  end

  it "fails a clone of an existing non-empty directory with basic.py's check_rc shape" do
    repo = tmp_path("git-fixture-clone-fail")
    build_fixture_repo(repo)
    dest = tmp_path("git-clone-fail-dest")
    `rm -rf #{dest}`
    # git happily clones into an existing EMPTY directory, so the
    # "already exists" failure needs something already in there.
    FileUtils.mkdir_p(dest)
    File.write(File.join(dest, "occupied"), "")

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})

    result["failed"].as_bool.must_equal(true)
    # clone()'s clone command is check_rc=True, so msg is the bare
    # rstripped stderr - git.py has no "Failed to clone repository" text.
    result["msg"].as_s.must_include("already exists")
    result["msg"].as_s.wont_include("Failed to")
    result["msg"].as_s.wont_include("\n")
    result["cmd"].as_s.must_include("clone")
    result["rc"].as_i64.wont_equal(0)
    result["stderr"].as_s.must_include("already exists")
  end

  it "reports the clone command in cmd the way _clean_args renders it" do
    repo = tmp_path("git-fixture-clone-cmd")
    build_fixture_repo(repo)
    dest = tmp_path("git-clone-cmd-dest")
    `rm -rf #{dest}`
    FileUtils.mkdir_p(dest)
    File.write(File.join(dest, "occupied"), "")

    result = PluginSpecHelper.run("git", {"repo" => repo, "dest" => dest})

    # basic.py shlex-quotes each argv token, leaving safe ones bare -
    # krikri's own execution quoting must not leak into the reported cmd.
    result["cmd"].as_s.must_include(" --origin origin ")
    result["cmd"].as_s.wont_include("'origin'")
  end

  it "fails a post-clone refspec fetch with basic.py's check_rc shape" do
    repo = tmp_path("git-fixture-refspec-fail")
    build_fixture_repo(repo)
    dest = tmp_path("git-refspec-fail-dest")
    `rm -rf #{dest}`

    result = PluginSpecHelper.run("git", {
      "repo"    => repo,
      "dest"    => dest,
      "refspec" => "no-such-ref",
    })

    result["failed"].as_bool.must_equal(true)
    # clone()'s refspec fetch is also check_rc=True.
    result["msg"].as_s.must_equal("fatal: couldn't find remote ref no-such-ref")
    result["cmd"].as_s.must_include("fetch origin no-such-ref")
    result["rc"].as_i64.wont_equal(0)
  end

  # --- git_version() preflight parity ----------------------------------
  #
  # git.py resolves the binary (executable: or get_bin_path('git', True))
  # at the top of main(), then probes it with `<git> --version` before any
  # repo work. A binary that cannot be exec'd therefore fails as
  # "Error executing command." with rc = the errno - it never reaches the
  # ls-remote/clone that would otherwise produce the confusing fallout.

  it "fails an executable: that does not exist the way Popen does" do
    repo = tmp_path("git-fixture-exec-missing")
    build_fixture_repo(repo)
    missing = tmp_path("git-no-such-binary")

    result = PluginSpecHelper.run("git", {
      "repo"       => repo,
      "dest"       => tmp_path("git-exec-missing-dest"),
      "executable" => missing,
    })

    result["failed"].as_bool.must_equal(true)
    # ENOENT, and the failing command is the version probe, not an
    # ls-remote against the nonexistent binary.
    result["rc"].as_i64.must_equal(2)
    result["cmd"].as_s.must_equal("#{missing} --version")
    result["msg"].as_s.must_equal("Error executing command.")
    result["stderr"].as_s.must_equal("")
    result["stdout"].as_s.must_equal("")
  end

  it "fails a non-executable executable: with EACCES" do
    repo = tmp_path("git-fixture-exec-noexec")
    build_fixture_repo(repo)
    plain = tmp_path("git-not-executable")
    File.write(plain, "")
    File.chmod(plain, 0o644)

    result = PluginSpecHelper.run("git", {
      "repo"       => repo,
      "dest"       => tmp_path("git-exec-noexec-dest"),
      "executable" => plain,
    })

    result["failed"].as_bool.must_equal(true)
    result["rc"].as_i64.must_equal(13)
    result["cmd"].as_s.must_equal("#{plain} --version")
  end

  it "fails a bare executable: name that is not on PATH with ENOENT" do
    repo = tmp_path("git-fixture-exec-bare")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {
      "repo"       => repo,
      "dest"       => tmp_path("git-exec-bare-dest"),
      "executable" => "git-not-a-real-binary-name",
    })

    result["failed"].as_bool.must_equal(true)
    result["rc"].as_i64.must_equal(2)
    result["cmd"].as_s.must_equal("git-not-a-real-binary-name --version")
  end

  it "checks the git binary before requiring dest" do
    # get_bin_path runs at the top of main(), so a PATH with no git wins
    # over the dest-required failure that follows it. An empty PATH also
    # keeps the sbin dirs get_bin_path appends out of the picture.
    repo = tmp_path("git-fixture-no-git")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {"repo" => repo}, {} of String => String, "localhost",
      env: {"PATH" => "/nonexistent-git-path"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Failed to find required executable")
  end

  it "requires dest before probing a missing executable:" do
    # ...but the dest check itself runs BEFORE git_version()'s probe, so
    # with no dest at all the dest message is the one reported.
    repo = tmp_path("git-fixture-exec-vs-dest")
    build_fixture_repo(repo)

    result = PluginSpecHelper.run("git", {
      "repo"       => repo,
      "executable" => tmp_path("git-no-such-binary-2"),
    })

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("the destination directory must be specified unless clone=no")
  end

  it "fails a non-git executable: only where clone() would" do
    # git_version() returns None for a binary that runs but is not git;
    # clone() turns that into a hard failure for single_branch: and
    # separate_git_dir: only.
    repo = tmp_path("git-fixture-not-git")
    build_fixture_repo(repo)
    not_git = tmp_path("git-true")
    File.write(not_git, "#!/bin/sh\nexit 0\n")
    File.chmod(not_git, 0o755)

    single = PluginSpecHelper.run("git", {
      "repo"          => repo,
      "dest"          => tmp_path("git-not-git-sb-dest"),
      "executable"    => not_git,
      "single_branch" => "yes",
    })
    single["failed"].as_bool.must_equal(true)
    single["msg"].as_s.must_equal("Cannot find git executable at #{not_git}")

    separate = PluginSpecHelper.run("git", {
      "repo"             => repo,
      "dest"             => tmp_path("git-not-git-sgd-dest"),
      "executable"       => not_git,
      "separate_git_dir" => tmp_path("git-not-git-sgd"),
    })
    separate["failed"].as_bool.must_equal(true)
    separate["msg"].as_s.must_equal("Cannot find git executable at #{not_git}")
  end

  it "reports a failed remote-url rewrite the way set_remote_url does" do
    # set_remote_url()'s fail_json concatenates out/err into the message
    # and passes neither rc nor cmd.
    repo = tmp_path("git-fixture-seturl-fail")
    build_fixture_repo(repo)
    dest = tmp_path("git-seturl-fail-dest")
    `rm -rf #{dest}`
    run!("git clone -q #{repo} #{dest}")
    # Break the repo so `git remote set-url` fails while the module still
    # takes the update path: a .git/config that is a DIRECTORY satisfies
    # git.py's os.path.exists(gitconfig) gate but leaves git unable to
    # read or write the config.
    run!("rm -f #{dest}/.git/config && mkdir #{dest}/.git/config")

    other = tmp_path("git-seturl-fail-other")
    build_fixture_repo(other)
    result = PluginSpecHelper.run("git", {"repo" => other, "dest" => dest})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_include("Failed to set a new url")
    result.as_h.has_key?("rc").must_equal(false)
    result.as_h.has_key?("cmd").must_equal(false)
    result.as_h.has_key?("stdout").must_equal(false)
    result.as_h.has_key?("stderr").must_equal(false)
  end
end
