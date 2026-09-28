require "../minitest_helper"
require "file_utils"
require "http/server"
require "openssl/digest"
require "digest/sha1"
require "digest/md5"

# The file-common result fields real Ansible's AnsibleModule.add_path_info
# (module_utils/basic.py) merges into EVERY file-touching module's result -
# uid/gid/owner/group/mode/state/size for any result path that still exists
# at module exit time (so a state=absent --check reports the file's
# PRE-removal stats with state "file", while the same task for real reports
# only state "absent"), plus copy's own SHA1 `checksum:` (verified live
# against ansible-core 2.19.4's ad-hoc output: a 40-hex-char SHA1, not the
# 32-hex-char MD5 this engine used to emit) - all live-verified shapes.
describe "file-common result fields (real Ansible's add_path_info)" do
  describe "copy" do
    it "reports a SHA1 (40-hex) checksum plus the stat fields on the identical-content no-op" do
      dest = File.tempname("copy-fields-noop")
      content = "copy-fields-noop-content\n"
      File.write(dest, content)

      result = PluginSpecHelper.run("copy", {"content" => content, "dest" => dest})

      result["changed"].as_bool.must_equal(false)
      checksum = result["checksum"].as_s
      checksum.must_equal(Digest::SHA1.hexdigest(content))
      checksum.size.must_equal(40)
      result["dest"].as_s.must_equal(dest)
      result["uid"].as_i64.must_equal(File.info(dest, follow_symlinks: false).owner_id.to_i64)
      result["gid"].as_i64.must_equal(File.info(dest, follow_symlinks: false).group_id.to_i64)
      result["owner"].as_s.wont_be_empty
      result["group"].as_s.wont_be_empty
      result["mode"].as_s.must_match(/\A0[0-7]{3,4}\z/)
      result["state"].as_s.must_equal("file")
      result["size"].as_i64.must_equal(content.bytesize.to_i64)
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "reports SHA1 checksum, md5sum, and the stat fields on a real write" do
      dest = File.tempname("copy-fields-write")
      content = "copy-fields-write-content\n"

      result = PluginSpecHelper.run("copy", {"content" => content, "dest" => dest})

      result["changed"].as_bool.must_equal(true)
      result["checksum"].as_s.must_equal(Digest::SHA1.hexdigest(content))
      result["checksum"].as_s.size.must_equal(40)
      result["md5sum"].as_s.must_equal(Digest::MD5.hexdigest(content))
      result["uid"].as_i64.must_equal(File.info(dest, follow_symlinks: false).owner_id.to_i64)
      result["state"].as_s.must_equal("file")
      result["size"].as_i64.must_equal(content.bytesize.to_i64)
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "adds no stat fields when the dest doesn't exist (check mode would-change)" do
      dest = File.tempname("copy-fields-check")

      result = PluginSpecHelper.run("copy", {"content" => "new\n", "dest" => dest, "_ansible_check_mode" => "true"})

      result["changed"].as_bool.must_equal(true)
      File.exists?(dest).must_equal(false)
      result["uid"]?.must_be_nil
      result["state"]?.must_be_nil
      result["size"]?.must_be_nil
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end
  end

  describe "file" do
    it "state=absent --check reports the PRE-removal stats with state 'file'" do
      path = File.tempname("file-absent-check")
      content = "still here\n"
      File.write(path, content)
      File.chmod(path, 0o640)

      result = PluginSpecHelper.run("file", {"path" => path, "state" => "absent", "_ansible_check_mode" => "true"})

      result["changed"].as_bool.must_equal(true)
      File.exists?(path).must_equal(true)
      result["path"].as_s.must_equal(path)
      result["state"].as_s.must_equal("file")
      result["uid"].as_i64.must_equal(File.info(path, follow_symlinks: false).owner_id.to_i64)
      result["gid"].as_i64.must_equal(File.info(path, follow_symlinks: false).group_id.to_i64)
      result["owner"].as_s.wont_be_empty
      result["group"].as_s.wont_be_empty
      result["mode"].as_s.must_equal("0640")
      result["size"].as_i64.must_equal(content.bytesize.to_i64)
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "state=absent for real reports only path + state 'absent'" do
      path = File.tempname("file-absent-real")
      File.write(path, "bye\n")

      result = PluginSpecHelper.run("file", {"path" => path, "state" => "absent"})

      result["changed"].as_bool.must_equal(true)
      File.exists?(path).must_equal(false)
      result["path"].as_s.must_equal(path)
      result["state"].as_s.must_equal("absent")
      result["uid"]?.must_be_nil
      result["size"]?.must_be_nil
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "state=touch reports the stat fields under the 'dest' key (real Ansible's key for touch)" do
      path = File.tempname("file-touch")
      File.write(path, "x")

      result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch"})

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["dest"].as_s.must_equal(path)
      result["state"].as_s.must_equal("file")
      result["uid"].as_i64.must_equal(File.info(path, follow_symlinks: false).owner_id.to_i64)
      result["mode"].as_s.must_match(/\A0[0-7]{3,4}\z/)
      result["size"].as_i64.must_equal(1)
    ensure
      File.delete(path) if path && File.exists?(path)
    end

    it "state=directory reports the stat fields with state 'directory' and no checksum" do
      path = File.tempname("file-dir")
      Dir.mkdir_p(path)

      result = PluginSpecHelper.run("file", {"path" => path, "state" => "directory"})

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["path"].as_s.must_equal(path)
      result["state"].as_s.must_equal("directory")
      result["uid"].as_i64.must_equal(File.info(path, follow_symlinks: false).owner_id.to_i64)
      result["size"].as_i64.must_be_instance_of(Int64)
      result["checksum"]?.must_be_nil
    ensure
      FileUtils.rm_rf(path) if path
    end

    it "state=link reports the link's own stats (mode 0777, state 'link') under the 'dest' key" do
      target = File.tempname("file-link-target")
      File.write(target, "target!\n")
      link = File.tempname("file-link")
      File.symlink(target, link)

      result = PluginSpecHelper.run("file", {"path" => link, "src" => target, "state" => "link"})

      falsey?(result["failed"]?.try(&.as_bool)).must_equal(true)
      result["dest"].as_s.must_equal(link)
      result["state"].as_s.must_equal("link")
      result["mode"].as_s.must_equal("0777")
      result["size"].as_i64.must_equal(target.size.to_i64)
      result["checksum"]?.must_be_nil
    ensure
      File.delete?(link) if link
      File.delete?(target) if target
    end
  end

  describe "get_url" do
    it "merges the stat fields into a real download's result" do
      content = "get_url-fields-content\n"
      server = HTTP::Server.new do |context|
        context.response.print(content)
      end
      address = server.bind_unused_port
      spawn { server.listen }
      Fiber.yield

      dest = File.tempname("get-url-fields")
      result = PluginSpecHelper.run("get_url", {"url" => "http://#{address}/f.txt", "dest" => dest})

      result["changed"].as_bool.must_equal(true)
      result["dest"].as_s.must_equal(dest)
      result["uid"].as_i64.must_equal(File.info(dest, follow_symlinks: false).owner_id.to_i64)
      result["gid"].as_i64.must_equal(File.info(dest, follow_symlinks: false).group_id.to_i64)
      result["owner"].as_s.wont_be_empty
      result["group"].as_s.wont_be_empty
      result["mode"].as_s.must_match(/\A0[0-7]{3,4}\z/)
      result["state"].as_s.must_equal("file")
      result["size"].as_i64.must_equal(content.bytesize.to_i64)
      result["md5sum"].as_s.must_equal(Digest::MD5.hexdigest(content))
    ensure
      server.close if server
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "merges the stat fields into the already-present no-op's result too" do
      content = "get_url-fields-noop-content\n"
      server = HTTP::Server.new do |context|
        context.response.print(content)
      end
      address = server.bind_unused_port
      spawn { server.listen }
      Fiber.yield

      dest = File.tempname("get-url-fields-noop")
      File.write(dest, content)

      result = PluginSpecHelper.run("get_url", {"url" => "http://#{address}/f.txt", "dest" => dest})

      result["changed"].as_bool.must_equal(false)
      result["dest"].as_s.must_equal(dest)
      result["state"].as_s.must_equal("file")
      result["uid"].as_i64.must_equal(File.info(dest, follow_symlinks: false).owner_id.to_i64)
      result["size"].as_i64.must_equal(content.bytesize.to_i64)
    ensure
      server.close if server
      File.delete(dest) if dest && File.exists?(dest)
    end
  end
end
