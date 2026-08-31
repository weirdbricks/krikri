require "../spec_helper"
require "file_utils"

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

describe "copy plugin - content: converted from a small src: file, dest: is an existing directory" do
  it "appends __original_src_basename instead of writing straight to the directory" do
    # Real bug found benchmarking juju4.brim's own "Add Brim applications
    # desktop shortcut" task: `copy: {src: brim.desktop, dest: /usr/
    # share/applications/}` (dest already an existing directory) failed
    # live over SSH ("Failed to write file: ... 'Is a directory'") even
    # though handle_file_copy's OWN dest-is-directory basename-append
    # logic works correctly - because TaskExecutor#
    # inline_copy_source_content reads a small src: file's content on
    # the controller and forwards it as content: instead (a real,
    # deliberate optimization, only for a non-local connection - which
    # is exactly why a `connection: local` repro never hit this), and
    # only handle_file_copy's src:-based path had the directory-append
    # logic; the content:-based handle_content_copy never got it. Fixed
    # by having inline_copy_source_content ALSO set
    # __original_src_basename (the same param stage_large_copy_source's
    # own precomputed-match path above already relies on) when it
    # rewrites src: into content:, and having the content: dispatch
    # point in copy.cr's own #execute append it to an existing-directory
    # dest before ever reaching handle_content_copy.
    dest_dir = File.tempname("copy-content-dir-spec")
    Dir.mkdir_p(dest_dir)

    result = PluginSpecHelper.run("copy", {
      "content"                 => "shortcut file contents\n",
      "dest"                    => dest_dir,
      "__original_src_basename" => "brim.desktop",
    })

    result["failed"]?.try(&.as_bool).should_not be_true
    result["changed"].as_bool.should be_true
    File.read(File.join(dest_dir, "brim.desktop")).should eq("shortcut file contents\n")
  ensure
    FileUtils.rm_rf(dest_dir) if dest_dir
  end
end
