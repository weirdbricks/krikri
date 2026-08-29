require "../spec_helper"
require "file_utils"
require "../../src/crystal_play/plugin_manager"

# OPUS_PERFORMANCE_IMPROVEMENTS.md item 6a - the controller-side record
# of "which plugin binaries were verified present on which host".
#
# A warm run's bootstrap was two round trips before any real work: one
# `exec_script` listing the remote `.md5` files, and one fact gather.
# Measured with item 0's profile over ten real roles, that bootstrap is
# 4.9% of a 15-second run but 59-74% of a sub-second one - it dominates
# exactly the small roles items 1-3 cannot help. This removes the first
# of the two.
#
# The whole safety argument rests on two properties, and those are what
# is pinned here rather than the happy path:
#
#   1. the record is only trusted when it matches the CURRENT local
#      binary and is inside its TTL, so a rebuilt binary or an old
#      entry always falls back to real verification; and
#   2. a wrong belief is recoverable - see the missing-binary detection,
#      without which this would be a correctness bug rather than an
#      optimization.
describe "plugin host-state cache (item 6a)" do
  after_each do
    CrystalPlay::PluginManager.clear_cache
    CrystalPlay::PluginManager.host_state_cache_enabled = true
  end

  it "puts its cache under XDG_CACHE_HOME when that is set" do
    # Never in the repo, never in /tmp where another user could plant it.
    previous = ENV["XDG_CACHE_HOME"]?
    begin
      ENV["XDG_CACHE_HOME"] = "/some/cache/root"
      CrystalPlay::PluginManager.host_state_path
        .should eq("/some/cache/root/crystal-ansible/plugin-state.json")
    ensure
      previous ? (ENV["XDG_CACHE_HOME"] = previous) : ENV.delete("XDG_CACHE_HOME")
    end
  end

  it "treats a corrupt cache file as simply absent" do
    # A cache that cannot be parsed must degrade to "verify the slow
    # way", never take the run down with it.
    previous = ENV["XDG_CACHE_HOME"]?
    dir = File.tempname("host-state-spec")
    begin
      Dir.mkdir_p(File.join(dir, "crystal-ansible"))
      File.write(File.join(dir, "crystal-ansible", "plugin-state.json"), "{not json at all")
      ENV["XDG_CACHE_HOME"] = dir
      CrystalPlay::PluginManager.clear_cache

      # Reading it must not raise; the flush path must also survive.
      CrystalPlay::PluginManager.invalidate_host_state("root@example:22")
      CrystalPlay::PluginManager.flush_host_state
    ensure
      previous ? (ENV["XDG_CACHE_HOME"] = previous) : ENV.delete("XDG_CACHE_HOME")
      FileUtils.rm_rf(dir)
    end
  end

  it "recognises a missing remote binary from the shell's own error" do
    # The detection has to be narrow: a module that fails normally
    # returns parseable JSON and must NOT be mistaken for a missing
    # binary, or every ordinary failure would trigger a re-upload.
    missing = JSON.parse({
      "failed" => true,
      "stdout" => "",
      "stderr" => "bash: line 1: #{CrystalPlay::PluginManager::REMOTE_PLUGIN_DIR}/command: No such file or directory",
    }.to_json)
    CrystalPlay::PluginManager.missing_remote_binary_for_spec?(missing).should be_true
  end

  it "does not mistake an ordinary module failure for a missing binary" do
    # A real module reporting that the FILE IT WAS ASKED ABOUT is
    # missing says "No such file or directory" too. The difference is
    # whether the path is ours.
    ordinary = JSON.parse({
      "failed" => true,
      "msg"    => "Could not open /etc/nope.conf: No such file or directory",
      "stdout" => "",
      "stderr" => "",
    }.to_json)
    CrystalPlay::PluginManager.missing_remote_binary_for_spec?(ordinary).should be_false
  end

  it "does not treat a successful result as a missing binary" do
    ok = JSON.parse({"failed" => false, "stdout" => "", "stderr" => ""}.to_json)
    CrystalPlay::PluginManager.missing_remote_binary_for_spec?(ok).should be_false
  end

  it "can be switched off entirely" do
    # --no-plugin-state-cache must genuinely restore the old behaviour,
    # which is the escape hatch for debugging a suspected staleness
    # problem.
    CrystalPlay::PluginManager.host_state_cache_enabled = false
    CrystalPlay::PluginManager.host_state_satisfies_for_spec?("root@example:22", ["command"])
      .should be_false
  end
end
