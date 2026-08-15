require "../spec_helper"

describe "copy plugin - __precomputed_match" do
  it "reports unchanged and applies attributes without ever touching src" do
    # Real bug/inefficiency found via round 25-27's benchmark rounds:
    # TaskExecutor#stage_large_copy_source unconditionally SCP'd a large
    # src file to the remote host on every single run, even when the
    # destination already held identical content - real Ansible's own
    # copy: checksums the destination first and skips the transfer
    # entirely on a match. The fix lives mostly in TaskExecutor (a
    # remote md5sum check before ever staging anything, not testable
    # here without a real SSH connection - PluginSpecHelper always runs
    # locally), but this spec covers the plugin-side half of the
    # contract: when __precomputed_match is set, the plugin must report
    # changed: false and apply file attributes WITHOUT ever reading
    # src - proven here by pointing src at a path that doesn't exist at
    # all (a real remote staging skip means src, still the
    # controller-only original path, is never present on the remote
    # filesystem the plugin actually runs on).
    dest = File.tempname("copy-precomputed-match-spec")
    File.write(dest, "already here\n")

    result = PluginSpecHelper.run("copy", {
      "dest"                    => dest,
      "src"                     => "/nonexistent/path/should-never-be-read",
      "__precomputed_match"     => "true",
      "__precomputed_checksum"  => "deadbeef",
      "__original_src_basename" => "should-never-be-read",
    })

    result["changed"].as_bool.should be_false
    result["failed"]?.try(&.as_bool).should_not be_true
    result["msg"].as_s.should eq("File already exists with identical content")
    result["checksum"]?.try(&.as_s).should eq("deadbeef")
    File.read(dest).should eq("already here\n")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "check mode reports unchanged without touching src or dest" do
    dest = File.tempname("copy-precomputed-match-check-spec")
    File.write(dest, "original\n")

    result = PluginSpecHelper.run("copy", {
      "dest"                => dest,
      "src"                 => "/nonexistent/path/should-never-be-read",
      "__precomputed_match" => "true",
      "check_mode"          => "true",
    })

    result["changed"].as_bool.should be_false
    File.read(dest).should eq("original\n")
  ensure
    File.delete(dest) if dest && File.exists?(dest)
  end
end
