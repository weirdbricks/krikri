require "../spec_helper"
require "file_utils"
require "http/server"

# The default mode real Ansible gives a NEWLY CREATED file when no explicit
# mode: is passed: 0666 & ~umask of the creating process (ansible-core's
# module_utils/basic.py atomic_move chmods a non-existing dest to exactly
# that; live-verified against ansible-core 2.19.4: umask 002 -> 0664, umask
# 022 -> 0644, for copy (src: and content:), file state=touch, and get_url
# alike). Crystal's own File.write/File.open default their creation perm to
# 0644, which ignored the umask's group-write bit entirely - the divergence
# these specs pin. Existing-dest overwrites are NOT covered here: real
# Ansible preserves an existing dest's mode across the move, which is a
# separate behavior (copy.cr's stat-preservation).
private def with_umask(mask : UInt32, &)
  old_mask = LibC.umask(mask)
  yield
ensure
  LibC.umask(old_mask || mask)
end

describe "default mode of newly created files tracks the umask (no explicit mode:)" do
  it "copy (content:) creates the file 0666 & ~umask" do
    with_umask(0o002_u32) do
      dest = File.tempname("umask-copy-002")

      result = PluginSpecHelper.run("copy", {"content" => "umask-copy\n", "dest" => dest})

      result["changed"].as_bool.should be_true
      result["mode"].as_s.should eq("0664")
      File.info(dest).permissions.value.should eq(0o664)
    end

    with_umask(0o022_u32) do
      dest = File.tempname("umask-copy-022")

      result = PluginSpecHelper.run("copy", {"content" => "umask-copy\n", "dest" => dest})

      result["mode"].as_s.should eq("0644")
      File.info(dest).permissions.value.should eq(0o644)
    end
  ensure
    FileUtils.rm_f(["umask-copy-002", "umask-copy-022"].map { |name| "/tmp/#{name}" })
  end

  it "copy (src:) ignores the SOURCE file's mode, using 0666 & ~umask" do
    src = File.tempname("umask-src")
    dest = File.tempname("umask-copy-src")
    File.write(src, "umask-src-content\n")
    File.chmod(src, 0o600)

    with_umask(0o002_u32) do
      result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest})

      result["changed"].as_bool.should be_true
      result["mode"].as_s.should eq("0664")
      File.info(dest).permissions.value.should eq(0o664)
    end
  ensure
    File.delete(src) if src && File.exists?(src)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "file state=touch creating a NEW file uses 0666 & ~umask" do
    with_umask(0o002_u32) do
      path = File.tempname("umask-touch-002")

      PluginSpecHelper.run("file", {"path" => path, "state" => "touch"})

      File.info(path).permissions.value.should eq(0o664)
    end

    with_umask(0o022_u32) do
      path = File.tempname("umask-touch-022")

      PluginSpecHelper.run("file", {"path" => path, "state" => "touch"})

      File.info(path).permissions.value.should eq(0o644)
    end
  ensure
    FileUtils.rm_f(Dir["/tmp/umask-touch-*"])
  end

  it "get_url creating a NEW dest uses 0666 & ~umask" do
    server = HTTP::Server.new do |context|
      context.response.status_code = 200
      context.response.print("umask-geturl-content\n")
    end
    address = server.bind_unused_port
    spawn { server.listen }
    Fiber.yield

    with_umask(0o002_u32) do
      dest = File.tempname("umask-geturl-002")

      result = PluginSpecHelper.run("get_url", {"url" => "http://#{address}/file.txt", "dest" => dest})

      result["changed"].as_bool.should be_true
      result["mode"].as_s.should eq("0664")
      File.info(dest).permissions.value.should eq(0o664)
    end

    with_umask(0o022_u32) do
      dest = File.tempname("umask-geturl-022")

      result = PluginSpecHelper.run("get_url", {"url" => "http://#{address}/file.txt", "dest" => dest})

      result["mode"].as_s.should eq("0644")
      File.info(dest).permissions.value.should eq(0o644)
    end
  ensure
    server.try(&.close)
    FileUtils.rm_f(Dir["/tmp/umask-geturl-*"])
  end
end
