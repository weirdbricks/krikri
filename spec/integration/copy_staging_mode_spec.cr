require "../spec_helper"
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

private def with_umask(mask : UInt32, &)
  old_mask = LibC.umask(mask)
  yield
ensure
  LibC.umask(old_mask || mask)
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

      result["changed"].as_bool.should be_true
      File.info(dest).permissions.value.should eq(0o600)
      File.read(probe).strip.should eq("600")
    end
  end

  it "stages content with no mode: at 0644 (0666 & ~umask) while validate: runs" do
    with_umask(0o022_u32) do
      with_temp_dir do |dir|
        probe = File.join(dir, "mode-probe")
        dest = File.join(dir, "plain.conf")

        result = PluginSpecHelper.run("copy", {
          "content"  => "plain config\n",
          "dest"     => dest,
          "validate" => "stat -c %a %s > #{probe}",
        })

        result["changed"].as_bool.should be_true
        File.info(dest).permissions.value.should eq(0o644)
        File.read(probe).strip.should eq("644")
      end
    end
  end
end
