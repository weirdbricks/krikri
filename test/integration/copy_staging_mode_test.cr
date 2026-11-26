require "../minitest_helper"
require "file_utils"

# Regression spec for the secret-staging TOCTOU (security pass, finding:
# "secret content staged world-readable and chmod-ed only after writing").
#
# copy: stages content in a temp file and only applied the task's mode:
# AFTER that file was renamed into place - so the staged bytes sat at the
# umask default (0644) for the whole staging + validate + move span,
# briefly readable, when the task was e.g. copying a private key with
# mode: 0600. The staging temp is now created 0600 and settled to its
# final mode BEFORE any content lands in it (BasePlugin#create_staging_temp).
#
# A nanosecond-scale create-then-chmod race can't be observed directly,
# but the validate: path makes the contract observable: the validate
# command runs while the staging file already exists WITH the content in
# it, so capturing the staged file's mode there pins "content never sits
# at a wider mode than its final one". (The file left behind on a failed
# validation - deliberately, see copy.cr - would otherwise still be
# readable at the wrong mode too.)

private def with_temp_dir(&)
  dir = File.tempname("copy-staging-mode-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "copy: staging temp never holds content wider than its final mode" do
  it "stages content with mode: 0600 at 0600 while the validate: command runs" do
    with_temp_dir do |dir|
      probe = File.join(dir, "mode-probe")
      dest = File.join(dir, "secret.key")

      result = PluginSpecHelper.run("copy", {
        "content"  => "PRIVATE KEY MATERIAL\n",
        "dest"     => dest,
        "mode"     => "0600",
        "validate" => "stat -c %a %s > #{probe}",
      })

      result["changed"].as_bool.must_equal(true)
      File.info(dest).permissions.value.must_equal(0o600)
      File.read(probe).strip.must_equal("600")
    end
  end

  it "stages content with no mode: at 0644 (0666 & ~umask) while validate: runs" do
    with_temp_dir do |dir|
      probe = File.join(dir, "mode-probe")
      dest = File.join(dir, "plain.conf")

      result = PluginSpecHelper.run("copy", {
        "content"  => "plain config\n",
        "dest"     => dest,
        "validate" => "stat -c %a %s > #{probe}",
      }, umask: 0o022)

      result["changed"].as_bool.must_equal(true)
      File.info(dest).permissions.value.must_equal(0o644)
      File.read(probe).strip.must_equal("644")
    end
  end

  it "keeps an existing dest's mode across the validate: path" do
    with_temp_dir do |dir|
      probe = File.join(dir, "mode-probe")
      dest = File.join(dir, "locked.conf")
      File.write(dest, "kpg locked dest\nsecond line\n")
      File.chmod(dest, 0o440)

      result = PluginSpecHelper.run("copy", {
        "content"  => "inner\n",
        "dest"     => dest,
        "validate" => "stat -c %a %s > #{probe}",
      }, umask: 0o022)

      result["changed"].as_bool.must_equal(true)
      File.read(dest).must_equal("inner\n")
      # copy.py's atomic_move copystat()s an existing dest over the staged
      # source right before the rename, so a no-mode overwrite keeps the
      # dest's own mode even with validate: (issue #1806).
      File.info(dest).permissions.value.must_equal(0o440)
      # That copy happens after validate: ran, which still sees the umask
      # default it saw before.
      File.read(probe).strip.must_equal("644")
    end
  end
end

describe "copy: read-only mode: as the non-root run user" do
  # ansible-core 2.21.5 writes the content into its staging temp and only
  # then applies the final mode (atomic_move's chmod), so a non-root user
  # can create - and overwrite - a 0440/0400/0444 dest. Pre-settling the
  # temp to that mode made the write's open fail EACCES ("Failed to write
  # temporary file ... Permission denied") and left the empty read-only
  # .tmp in the dest directory (issue #1385).
  it "creates a 0440/0400/0444 dest without leaving a temp file" do
    with_temp_dir do |dir|
      {"0440" => 0o440, "0400" => 0o400, "0444" => 0o444}.each do |mode, bits|
        dest = File.join(dir, "readonly-#{mode}.conf")

        result = PluginSpecHelper.run("copy", {
          "content" => "read only\n",
          "dest"    => dest,
          "mode"    => mode,
        })

        falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
        result["changed"].as_bool.must_equal(true)
        File.info(dest).permissions.value.must_equal(bits)
        File.read(dest).must_equal("read only\n")
      end
      Dir.children(dir).count { |name| name.includes?(".tmp") }.must_equal(0)
    end
  end

  it "overwrites an existing 0440 dest" do
    with_temp_dir do |dir|
      dest = File.join(dir, "existing.conf")
      File.write(dest, "old\n")
      File.chmod(dest, 0o440)

      result = PluginSpecHelper.run("copy", {
        "content" => "new\n",
        "dest"    => dest,
        "mode"    => "0440",
      })

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      File.info(dest).permissions.value.must_equal(0o440)
      File.read(dest).must_equal("new\n")
      Dir.children(dir).count { |name| name.includes?(".tmp") }.must_equal(0)
    end
  end
end

describe "copy: validate: across devices (TMPDIR on a different mount)" do
  # The validate path stages the temp under Dir.tempdir (remote_tmp-style);
  # moving that temp onto a dest on another filesystem fails the rename with
  # EXDEV, and the plain FileUtils.mv fallback then opens the read-only
  # dest for writing (File.copy opens "wb") - exactly the 0440 case that
  # regressed #1806. The real atomic_move stages a fresh writable file next
  # to dest instead. The dest lives under PluginSpecHelper.tmp_path (repo
  # fs) while TMPDIR points at a separate mount, and the test asserts the
  # whole sequence - changed result, preserved mode, content - so the ladder
  # in plugins/copy.cr cannot silently pass.
  it "overwrites an existing 0440 dest when TMPDIR is on a different mount" do
    repo_tmp = PluginSpecHelper.tmp_path("copy-validate-cross-device")
    FileUtils.mkdir_p(repo_tmp)
    dest = File.join(repo_tmp, "dest-0440.txt")
    File.write(dest, "kpg locked dest\nsecond line\n")
    File.chmod(dest, 0o440)

    shm = "/dev/shm"
    skip("/dev/shm unavailable") unless Dir.exists?(shm)

    repo_dev = `stat -f -c %d #{repo_tmp}`.strip
    shm_dev = `stat -f -c %d #{shm}`.strip
    skip("TMPDIR mount (#{shm_dev}) matches repo fs (#{repo_dev}); cross-device ladder not exercised") if repo_dev == shm_dev

    result = PluginSpecHelper.run("copy", {
      "content"  => "inner\n",
      "dest"     => dest,
      "validate" => "cat %s > /dev/null",
    }, umask: 0o022, env: {"TMPDIR" => shm})

    result["changed"].as_bool.must_equal(true)
    File.read(dest).must_equal("inner\n")
    File.info(dest).permissions.value.must_equal(0o440)
    Dir.children(repo_tmp).count { |name| name.includes?(".tmp") || name.starts_with?(".ansible_tmp") }.must_equal(0)
  ensure
    FileUtils.rm_rf(repo_tmp) if repo_tmp && Dir.exists?(repo_tmp)
  end
end
