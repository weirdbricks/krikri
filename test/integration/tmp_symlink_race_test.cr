require "../minitest_helper"
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

# crystal spec ran this setup in Spec.before_suite and captured
# `RACE_BASE` in each example's closure; minitest compiles `it` bodies
# as methods, so the once-per-process setup is file-level constants.
# The dir is unique per process (each suite run rebuilds it), matching
# the classic before_suite's rm_rf+mkdir-fresh semantics.
private RACE_DIR = begin
  dir = File.join(Dir.tempdir, "symlink-race-#{Random::Secure.hex(4)}")
  FileUtils.rm_rf(dir) if Dir.exists?(dir)
  Dir.mkdir_p(File.join(dir, "src"))
  File.write(File.join(dir, "src", "canary.txt"), "sentinel")
  `tar czf #{File.join(dir, "race.tar.gz")} -C #{File.join(dir, "src")} canary.txt`
  # The file the planted symlink points at (what an attacker wants root to
  # clobber through the predictable temp path).
  File.write(File.join(dir, "target.txt"), "sentinel")
  dir
end

RACE_TEST_SERVER = HTTP::Server.new do |context|
  case context.request.path
  when "/race.tar.gz"
    context.response.status_code = 200
    IO.copy(File.open(File.join(RACE_DIR, "race.tar.gz")), context.response)
  else
    context.response.status_code = 404
  end
end
RACE_ADDRESS = RACE_TEST_SERVER.bind_unused_port
spawn { RACE_TEST_SERVER.listen }
Fiber.yield
RACE_BASE = "http://#{RACE_ADDRESS}"

private def old_unarchive_path : String
  # The exact shape unarchive.cr used before the fix.
  "/tmp/.krikri-playbook-unarchive-123456"
end

describe "plugin temp-file symlink race hardening" do
  it "does not follow a symlink planted at the old predictable unarchive download path" do
    target = File.join(RACE_DIR, "target.txt")
    planted = old_unarchive_path
    File.delete(planted) if File.exists?(planted) || File.symlink?(planted)
    File.symlink(target, planted)

    dest = File.join(RACE_DIR, "dest")
    FileUtils.rm_rf(dest) if Dir.exists?(dest)
    Dir.mkdir_p(dest)

    result = PluginSpecHelper.run("unarchive", {
      "src"  => "#{RACE_BASE}/race.tar.gz",
      "dest" => dest,
    })

    falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
    # The download itself landed in the plugin's own temp file and extracted...
    File.read(File.join(dest, "canary.txt")).must_equal("sentinel")
    # ...and the pre-planted symlink was neither replaced nor followed...
    File.symlink?(planted).must_equal(true)
    File.read(target).must_equal("sentinel")
    # ...and the staging path no longer uses the old 6-digit predictable
    # scheme (this is what deterministically fails against the old code,
    # whose result src was /tmp/.krikri-playbook-unarchive-<6 digits>).
    staging = result["src"].as_s
    staging.wont_match(/-[0-9]{6}$/)
    staging.must_match(/\.krikri-playbook-unarchive-[0-9a-z]+$/)
  end
end
