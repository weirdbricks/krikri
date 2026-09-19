require "../spec_helper"
require "file_utils"
require "http/server"

# Regression for the symlink/TOCTOU class in the DeepSeek review (finding #5):
# plugins used to build target-side temp paths from a URL basename or a small
# Random.rand(100000..999999) range and then write to them with
# symlink-following opens, so a local user could pre-plant /tmp/<that exact
# path> as a symlink to any file and have the plugin (running as root) clobber
# the target through it (for the 6-digit range: plant all 900k paths and every
# run hits one).
#
# The fix stages downloads through File.tempfile (unguessable name + O_EXCL +
# 0600), so a pre-planted path is never used. Both properties are asserted
# below: the planted path is untouched, and the download's own staging path
# (exposed as `src` in the result) is no longer of the old predictable
# 6-digit form.

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "symlink_race")

private def old_unarchive_path : String
  # The exact shape unarchive.cr used before the fix.
  "/tmp/.krikri-playbook-unarchive-123456"
end

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(File.join(TMP_DIR, "src"))
  File.write(File.join(TMP_DIR, "src", "canary.txt"), "sentinel")
  `tar czf #{File.join(TMP_DIR, "race.tar.gz")} -C #{File.join(TMP_DIR, "src")} canary.txt`
  # The file the planted symlink points at (what an attacker wants root to
  # clobber through the predictable temp path).
  File.write(File.join(TMP_DIR, "target.txt"), "sentinel")
end

race_test_server = HTTP::Server.new do |context|
  case context.request.path
  when "/race.tar.gz"
    context.response.status_code = 200
    IO.copy(File.open(File.join(TMP_DIR, "race.tar.gz")), context.response)
  else
    context.response.status_code = 404
  end
end
race_test_address = race_test_server.bind_unused_port
spawn { race_test_server.listen }
Fiber.yield
race_base = "http://#{race_test_address}"

describe "plugin temp-file symlink race hardening" do
  it "does not follow a symlink planted at the old predictable unarchive download path" do
    target = File.join(TMP_DIR, "target.txt")
    planted = old_unarchive_path
    File.delete(planted) if File.exists?(planted) || File.symlink?(planted)
    File.symlink(target, planted)

    dest = File.join(TMP_DIR, "dest")
    FileUtils.rm_rf(dest) if Dir.exists?(dest)
    Dir.mkdir_p(dest)

    result = PluginSpecHelper.run("unarchive", {
      "src"  => "#{race_base}/race.tar.gz",
      "dest" => dest,
    })

    result["failed"]?.try(&.as_bool).should be_falsey
    # The download itself landed in the plugin's own temp file and extracted...
    File.read(File.join(dest, "canary.txt")).should eq("sentinel")
    # ...and the pre-planted symlink was neither replaced nor followed...
    File.symlink?(planted).should be_true
    File.read(target).should eq("sentinel")
    # ...and the staging path no longer uses the old 6-digit predictable
    # scheme (this is what deterministically fails against the old code,
    # whose result src was /tmp/.krikri-playbook-unarchive-<6 digits>).
    staging = result["src"].as_s
    staging.should_not match(/-[0-9]{6}$/)
    staging.should match(/\.krikri-playbook-unarchive-[0-9a-z]+$/)
  end
end
