require "../minitest_helper"
require "file_utils"

# Regression spec for issue #583 (nickjj.monit divergence).
#
# The role templates /etc/monit/monitrc with NO mode:. The Debian monit
# package ships that file at 0600, and monit refuses to start on anything
# wider ("control file '/etc/monit/monitrc' permission 0644 is wrong"),
# so the role's service: state=started task fails. Real Ansible keeps the
# existing dest's mode here (ansible's atomic_move preserves it); the
# template staging temp was created with preserve_dest_mode: false, so
# the rename settled the dest to 0666 & ~umask and monit broke.

private def with_temp_dir(&)
  dir = File.tempname("template-dest-mode-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "template: preserves an existing dest's mode when no mode: is given" do
  it "keeps an existing dest at 0600 when the task has no mode:" do
    with_temp_dir do |dir|
      dest = File.join(dir, "monitrc")
      File.write(dest, "old monitrc\n")
      File.chmod(dest, 0o600)

      result = PluginSpecHelper.run("template", {
        "content" => "set daemon 60\n",
        "dest"    => dest,
      })

      result["changed"].as_bool.must_equal(true)
      File.info(dest).permissions.value.must_equal(0o600)
    end
  end

  it "creates a new dest at 0644 (0666 & ~umask) when the task has no mode:" do
    with_temp_dir do |dir|
      dest = File.join(dir, "fresh.conf")

      result = PluginSpecHelper.run("template", {
        "content" => "plain config\n",
        "dest"    => dest,
      }, umask: 0o022)

      result["changed"].as_bool.must_equal(true)
      File.info(dest).permissions.value.must_equal(0o644)
    end
  end
end
