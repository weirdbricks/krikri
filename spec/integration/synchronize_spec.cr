require "../spec_helper"
require "file_utils"

# Integration specs for the synchronize (ansible.posix) plugin binary,
# against a real rsync between two real local paths - the same shape the
# other plugin-binary specs use (PluginSpecHelper pipes a JSON config into
# bin/plugins/<name> and reads the JSON result off stdout). This exercises
# the module half end to end: argv construction, a real rsync run, and the
# itemize-changes protocol that produces changed: true/false (idempotency).
#
# The controller-half (SynchronizeActionPlugin - remote user@host: munging,
# push/pull direction) is never dispatched as a binary, so the local-path
# runs here are also exactly what a delegate_to: localhost / ansible_
# connection=local synchronize task does on the controller.
def cleanup_sync_dirs(paths : Array(String?)) : Nil
  paths.each { |path| FileUtils.rm_rf(path) if path }
end

describe "synchronize plugin" do
  it "syncs a file from src to dest and reports changed" do
    src = File.tempname("sync-spec-src")
    dest = File.tempname("sync-spec-dest")
    begin
      Dir.mkdir_p(src)
      Dir.mkdir_p(dest)
      File.write(File.join(src, "a.txt"), "file a\n")

      result = PluginSpecHelper.run("synchronize", {"src" => "#{src}/", "dest" => "#{dest}/"})

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_true
      result["rc"].as_i.should eq(0)
      File.read(File.join(dest, "a.txt")).should eq("file a\n")
    ensure
      cleanup_sync_dirs([src, dest])
    end
  end

  it "reports changed: false when nothing needed transferring (idempotency)" do
    src = File.tempname("sync-spec-src2")
    dest = File.tempname("sync-spec-dest2")
    begin
      Dir.mkdir_p(src)
      Dir.mkdir_p(dest)
      File.write(File.join(src, "a.txt"), "file a\n")

      first = PluginSpecHelper.run("synchronize", {"src" => "#{src}/", "dest" => "#{dest}/"})
      first["changed"].as_bool.should be_true

      second = PluginSpecHelper.run("synchronize", {"src" => "#{src}/", "dest" => "#{dest}/"})
      second["changed"].as_bool.should be_false
      second["failed"]?.try(&.as_bool).should be_falsey
    ensure
      cleanup_sync_dirs([src, dest])
    end
  end

  it "propagates content updates as changed" do
    src = File.tempname("sync-spec-src3")
    dest = File.tempname("sync-spec-dest3")
    begin
      Dir.mkdir_p(src)
      Dir.mkdir_p(dest)
      File.write(File.join(src, "b.txt"), "v1\n")

      PluginSpecHelper.run("synchronize", {"src" => "#{src}/", "dest" => "#{dest}/"})
      # rsync's quick check is size + 1-second-granularity mtime - a
      # same-second, same-size rewrite is invisible to it (real Ansible
      # included), so pin the mtime apart before the content update.
      sleep 1.seconds
      File.write(File.join(src, "b.txt"), "v2\n")

      result = PluginSpecHelper.run("synchronize", {"src" => "#{src}/", "dest" => "#{dest}/"})
      result["changed"].as_bool.should be_true
      File.read(File.join(dest, "b.txt")).should eq("v2\n")
    ensure
      cleanup_sync_dirs([src, dest])
    end
  end

  it "carries directories recursively under the default archive" do
    src = File.tempname("sync-spec-src4")
    dest = File.tempname("sync-spec-dest4")
    begin
      Dir.mkdir_p(File.join(src, "sub"))
      File.write(File.join(src, "sub", "c.txt"), "file c\n")

      result = PluginSpecHelper.run("synchronize", {"src" => "#{src}/", "dest" => "#{dest}/"})

      result["changed"].as_bool.should be_true
      File.read(File.join(dest, "sub", "c.txt")).should eq("file c\n")
    ensure
      cleanup_sync_dirs([src, dest])
    end
  end

  it "deletes stale dest files with delete: true (and reports changed)" do
    src = File.tempname("sync-spec-src5")
    dest = File.tempname("sync-spec-dest5")
    begin
      Dir.mkdir_p(src)
      Dir.mkdir_p(dest)
      File.write(File.join(src, "keep.txt"), "keep\n")
      File.write(File.join(dest, "stale.txt"), "stale\n")

      result = PluginSpecHelper.run("synchronize", {
        "src"       => "#{src}/",
        "dest"      => "#{dest}/",
        "delete"    => "true",
        "recursive" => "true",
      })

      result["changed"].as_bool.should be_true
      File.exists?(File.join(dest, "stale.txt")).should be_false
      File.read(File.join(dest, "keep.txt")).should eq("keep\n")
    ensure
      cleanup_sync_dirs([src, dest])
    end
  end

  it "keeps stale dest files without delete:" do
    src = File.tempname("sync-spec-src6")
    dest = File.tempname("sync-spec-dest6")
    begin
      Dir.mkdir_p(src)
      Dir.mkdir_p(dest)
      File.write(File.join(src, "keep2.txt"), "keep\n")
      File.write(File.join(dest, "stale2.txt"), "stale\n")

      result = PluginSpecHelper.run("synchronize", {"src" => "#{src}/", "dest" => "#{dest}/"})

      File.exists?(File.join(dest, "stale2.txt")).should be_true
    ensure
      cleanup_sync_dirs([src, dest])
    end
  end

  it "fails when rsync fails (nonexistent src) and carries rc/cmd" do
    result = PluginSpecHelper.run("synchronize", {
      "src"  => "/nonexistent/synchronize-spec-src-path",
      "dest" => "/nonexistent/synchronize-spec-dest-path",
    })

    result["failed"].as_bool.should be_true
    result["changed"].as_bool.should be_false
    result["rc"].as_i.should_not eq(0)
    result["cmd"].as_s.should contain("rsync")
  end

  it "fails when src or dest is missing" do
    result = PluginSpecHelper.run("synchronize", {"src" => "/only-src"})
    result["failed"].as_bool.should be_true
    result["msg"].as_s.should eq("synchronize requires both src and dest parameters are set")
  end
end
