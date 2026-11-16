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
