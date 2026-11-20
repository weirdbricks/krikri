require "../minitest_helper"
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

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["changed"].as_bool.must_equal(true)
      result["rc"].as_i.must_equal(0)
      File.read(File.join(dest, "a.txt")).must_equal("file a\n")
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
      first["changed"].as_bool.must_equal(true)

      second = PluginSpecHelper.run("synchronize", {"src" => "#{src}/", "dest" => "#{dest}/"})
      second["changed"].as_bool.must_equal(false)
      falsey?(second["failed"]?.try(&.as_bool)).must_equal(true)
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
      # same-second, same-size rewrite is invisible to it (Ansible
      # included), so pin the mtime apart before the content update.
      sleep 1.seconds
      File.write(File.join(src, "b.txt"), "v2\n")

      result = PluginSpecHelper.run("synchronize", {"src" => "#{src}/", "dest" => "#{dest}/"})
      result["changed"].as_bool.must_equal(true)
      File.read(File.join(dest, "b.txt")).must_equal("v2\n")
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

      result["changed"].as_bool.must_equal(true)
      File.read(File.join(dest, "sub", "c.txt")).must_equal("file c\n")
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

      result["changed"].as_bool.must_equal(true)
      File.exists?(File.join(dest, "stale.txt")).must_equal(false)
      File.read(File.join(dest, "keep.txt")).must_equal("keep\n")
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

      PluginSpecHelper.run("synchronize", {"src" => "#{src}/", "dest" => "#{dest}/"})

      File.exists?(File.join(dest, "stale2.txt")).must_equal(true)
    ensure
      cleanup_sync_dirs([src, dest])
    end
  end

  it "fails when rsync fails (nonexistent src) and carries rc/cmd" do
    result = PluginSpecHelper.run("synchronize", {
      "src"  => "/nonexistent/synchronize-spec-src-path",
      "dest" => "/nonexistent/synchronize-spec-dest-path",
    })

    result["failed"].as_bool.must_equal(true)
    result["changed"].as_bool.must_equal(false)
    result["rc"].as_i.wont_equal(0)
    result["cmd"].as_s.must_include("rsync")
  end

  it "fails when src or dest is missing" do
    result = PluginSpecHelper.run("synchronize", {"src" => "/only-src"})
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("synchronize requires both src and dest parameters are set")
  end
end

# The module half of `_substitute_controller` (issue #1629). This binary is
# what real ansible runs where the module actually executes, so its own
# SSH_CLIENT/SSH_CONNECTION decides: without either the module fails before
# running rsync, and with one it rewrites a localhost: prefix to that
# address's first token.
describe "synchronize plugin _substitute_controller" do
  serial! # SSH_CLIENT/SSH_CONNECTION are process-global

  it "fails before rsync when no controller hostname is known" do
    saved = {"SSH_CLIENT", "SSH_CONNECTION"}.map { |name| {name, ENV[name]?} }
    ENV.delete("SSH_CLIENT")
    ENV.delete("SSH_CONNECTION")
    begin
      result = PluginSpecHelper.run("synchronize", {
        "src"                    => "/nonexistent/synchronize-spec-src-path",
        "dest"                   => "/nonexistent/synchronize-spec-dest-path",
        "_substitute_controller" => "true",
      })

      result["failed"].as_bool.must_equal(true)
      result["changed"].as_bool.must_equal(false)
      result["msg"].as_s.must_equal("Could not determine controller hostname for rsync to send to")
      result["cmd"]?.must_be_nil
    ensure
      saved.try &.each do |name, value|
        value ? (ENV[name] = value) : ENV.delete(name)
      end
    end
  end

  it "rewrites the src localhost: prefix to SSH_CLIENT's address" do
    result = PluginSpecHelper.run("synchronize", {
      "src"                    => "localhost:/nonexistent/synchronize-spec-src-path",
      "dest"                   => "/nonexistent/synchronize-spec-dest-path",
      "_substitute_controller" => "true",
    }, env: {"SSH_CLIENT" => "127.0.0.1 12345 22"})

    result["failed"].as_bool.must_equal(true)
    result["cmd"].as_s.must_include("127.0.0.1:/nonexistent/synchronize-spec-src-path")
    result["cmd"].as_s.wont_include("localhost:")
  end
end
