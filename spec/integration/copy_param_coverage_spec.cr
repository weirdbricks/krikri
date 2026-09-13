require "../spec_helper"
require "file_utils"
require "digest/sha1"

# Proactive parameter-coverage pass for `copy:` - every behavior below
# was live-verified against the locally-installed real ansible-core
# 2.19.4 (`ansible-playbook`/`ansible-doc` on PATH) before being pinned
# here, mirroring the conventions file.cr's attr:/attributes: specs and
# archive_spec.cr's own SELinux specs established.
private def sha1_of(path : String) : String
  Digest::SHA1.hexdigest(File.read(path))
end

describe "copy plugin - parameter coverage (checksum/attributes/SELinux/follow/local_follow/remote_src/directory_mode)" do
  describe "checksum:" do
    # Live-verified against ansible-core 2.19.4: a copy: whose
    # checksum: param matches the destination's existing SHA1 skips
    # the transfer entirely WITHOUT comparing content: against the
    # file - a copy with matching checksum and DIFFERENT content
    # reports changed=false and leaves the file untouched.
    it "skips the copy entirely (changed=false) when dest already holds the given checksum, even when content differs" do
      dest = File.tempname("copy-checksum-skip-dest")
      File.write(dest, "on disk\n")

      result = PluginSpecHelper.run("copy", {
        "content"  => "different\n",
        "dest"     => dest,
        "checksum" => sha1_of(dest),
      })

      result["changed"].as_bool.should be_false
      result["failed"]?.try(&.as_bool).should be_falsey
      File.read(dest).should eq("on disk\n")
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "copies successfully when the written content matches the given checksum" do
      dest = File.tempname("copy-checksum-ok-dest")
      body = "verified body\n"

      result = PluginSpecHelper.run("copy", {
        "content"  => body,
        "dest"     => dest,
        "checksum" => Digest::SHA1.hexdigest(body),
      })

      result["changed"].as_bool.should be_true
      result["failed"]?.try(&.as_bool).should be_falsey
      File.read(dest).should eq(body)
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    # Live-verified against ansible-core 2.19.4: a copy whose written
    # content does not match the given checksum: fails with exactly
    # "Copied file does not match the expected checksum. Transfer
    # failed." (plus checksum/expected_checksum in the result), and an
    # absent dest stays absent - the verification happens on the staged
    # file BEFORE it is moved into place.
    it "fails with real Ansible's exact message and leaves an absent dest absent when the written content doesn't match" do
      dest = File.tempname("copy-checksum-bad-dest")
      File.delete(dest) if File.exists?(dest)

      result = PluginSpecHelper.run("copy", {
        "content"  => "chk body\n",
        "dest"     => dest,
        "checksum" => "0" * 40,
      })

      result["failed"].as_bool.should be_true
      result["changed"].as_bool.should be_false
      result["msg"].as_s.should eq("Copied file does not match the expected checksum. Transfer failed.")
      result["checksum"].as_s.should eq(Digest::SHA1.hexdigest("chk body\n"))
      result["expected_checksum"].as_s.should eq("0" * 40)
      File.exists?(dest).should be_false
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end
  end

  describe "attributes:/attr: (chattr flags)" do
    # Mirrors file_spec.cr's own attr: specs - same set_attributes_if_
    # different semantics: '-'-prefixed requests report changed
    # unconditionally (ansible/ansible#33745).
    it "reports changed on every run for '-'-prefixed attributes, flag set or not (real Ansible's quirk)" do
      dest = File.tempname("copy-attr-clear-dest")
      File.write(dest, "x")

      result = PluginSpecHelper.run("copy", {"content" => "x\n", "dest" => dest, "attributes" => "-i"})
      result["changed"].as_bool.should be_true
      result["failed"]?.try(&.as_bool).should be_falsey

      warm = PluginSpecHelper.run("copy", {"content" => "x\n", "dest" => dest, "attributes" => "-i"})
      warm["changed"].as_bool.should be_true
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "fails the task when chattr itself errors (real Ansible's chattr-failed shape)" do
      # tmpfs doesn't support chattr - /dev/shm is reliably tmpfs in
      # every environment this suite runs in (containers included).
      dest = File.join("/dev/shm", "krikri-copy-attr-fail-#{Random.new.hex(8)}")

      result = PluginSpecHelper.run("copy", {"content" => "x\n", "dest" => dest, "attributes" => "+i"})

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("chattr failed")
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "reports changed in check mode without touching the file" do
      dest = File.tempname("copy-attr-check-dest")
      File.write(dest, "x")

      result = PluginSpecHelper.run("copy", {"content" => "x\n", "dest" => dest, "attributes" => "-i", "check_mode" => "true"})
      result["changed"].as_bool.should be_true
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end
  end

  describe "seuser:/serole:/setype:/selevel: (SELinux context)" do
    # Same convention as archive_spec.cr's own SELinux spec: real
    # Ansible skips the whole chcon step when SELinux isn't enabled on
    # the target - this confirms copy: still succeeds cleanly (a true
    # no-op) rather than attempting (and failing) a chcon call.
    it "does not fail the copy when SELinux isn't enabled on the target (a true no-op, matching real Ansible)" do
      dest = File.tempname("copy-selinux-noop-dest")

      result = PluginSpecHelper.run("copy", {
        "content" => "x\n", "dest" => dest,
        "seuser" => "system_u", "serole" => "object_r",
        "setype" => "etc_t", "selevel" => "s0",
      })

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_true
      File.read(dest).should eq("x\n")
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end
  end

  describe "follow: (dest symlink handling)" do
    # Live-verified against ansible-core 2.19.4: follow: true keeps the
    # dest symlink and writes through it to the target file.
    it "writes through a dest symlink when follow: is true (symlink survives, target updated)" do
      target = File.tempname("copy-follow-target")
      File.write(target, "before\n")
      link = File.tempname("copy-follow-link")
      File.delete(link) if File.exists?(link)
      File.symlink(target, link)

      result = PluginSpecHelper.run("copy", {"content" => "via follow\n", "dest" => link, "follow" => "true"})

      result["changed"].as_bool.should be_true
      result["failed"]?.try(&.as_bool).should be_falsey
      File.symlink?(link).should be_true
      File.read(target).should eq("via follow\n")
    ensure
      File.delete(link) if link && (File.exists?(link) || File.symlink?(link))
      File.delete(target) if target && File.exists?(target)
    end

    # Live-verified against ansible-core 2.19.4: the default follow:
    # false replaces the symlink itself with a regular file.
    it "replaces a dest symlink with a regular file by default (follow: false)" do
      target = File.tempname("copy-replace-target")
      File.write(target, "before\n")
      link = File.tempname("copy-replace-link")
      File.delete(link) if File.exists?(link)
      File.symlink(target, link)

      result = PluginSpecHelper.run("copy", {"content" => "replace\n", "dest" => link})

      result["changed"].as_bool.should be_true
      File.symlink?(link).should be_false
      File.read(link).should eq("replace\n")
      # The old target is untouched.
      File.read(target).should eq("before\n")
    ensure
      File.delete(link) if link && (File.exists?(link) || File.symlink?(link))
      File.delete(target) if target && File.exists?(target)
    end
  end

  describe "local_follow: (source-tree symlink handling)" do
    # Live-verified against ansible-core 2.19.4: the default (None)
    # follows symlinks in the source directory - the dest gets a
    # regular file holding the target's content.
    it "follows a symlink in the source tree by default (content copied, not the link)" do
      src_dir = File.join(Dir.tempdir, "krikri-lf-src-#{Random.new.hex(8)}")
      Dir.mkdir_p(src_dir)
      File.write(File.join(src_dir, "target.txt"), "target body\n")
      File.symlink("target.txt", File.join(src_dir, "link.txt"))

      dest_dir = File.join(Dir.tempdir, "krikri-lf-dest-#{Random.new.hex(8)}")
      result = PluginSpecHelper.run("copy", {"src" => "#{src_dir}/", "dest" => "#{dest_dir}/"})

      result["changed"].as_bool.should be_true
      File.symlink?(File.join(dest_dir, "link.txt")).should be_false
      File.read(File.join(dest_dir, "link.txt")).should eq("target body\n")
    ensure
      FileUtils.rm_rf(src_dir) if src_dir
      FileUtils.rm_rf(dest_dir) if dest_dir
    end

    # Live-verified against ansible-core 2.19.4: an explicit
    # local_follow: false recreates the symlink at dest (same link
    # target, relative links stay relative).
    it "recreates the source symlink at dest when local_follow is explicitly false" do
      src_dir = File.join(Dir.tempdir, "krikri-lf2-src-#{Random.new.hex(8)}")
      Dir.mkdir_p(src_dir)
      File.write(File.join(src_dir, "target.txt"), "target body\n")
      File.symlink("target.txt", File.join(src_dir, "link.txt"))

      dest_dir = File.join(Dir.tempdir, "krikri-lf2-dest-#{Random.new.hex(8)}")
      result = PluginSpecHelper.run("copy", {"src" => "#{src_dir}/", "dest" => "#{dest_dir}/", "local_follow" => "false"})

      result["changed"].as_bool.should be_true
      File.symlink?(File.join(dest_dir, "link.txt")).should be_true
      File.readlink(File.join(dest_dir, "link.txt")).should eq("target.txt")
    ensure
      FileUtils.rm_rf(src_dir) if src_dir
      FileUtils.rm_rf(dest_dir) if dest_dir
    end
  end

  describe "remote_src: (source resolved on the target host)" do
    # With remote_src: true the executor skips all controller-side
    # staging, so the src path this plugin receives IS a target-local
    # path and the copy is a plain server-side file-to-file copy. On a
    # local connection (which is how PluginSpecHelper runs the plugin)
    # that resolves to exactly this file-to-file copy too.
    it "copies a file already present on the target host" do
      src = File.tempname("copy-remote-src")
      File.write(src, "remote body\n")
      dest = File.tempname("copy-remote-dest")
      File.delete(dest) if File.exists?(dest)

      result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest, "remote_src" => "true"})

      result["changed"].as_bool.should be_true
      result["failed"]?.try(&.as_bool).should be_falsey
      File.read(dest).should eq("remote body\n")
    ensure
      File.delete(src) if src && File.exists?(src)
      File.delete(dest) if dest && File.exists?(dest)
    end

    # Live-verified against ansible-core 2.19.4: a missing remote_src
    # source fails with exactly "Source <src> not found" (module-side,
    # since nothing controller-side runs for remote_src).
    it "fails with real Ansible's exact message when the remote-side source is missing" do
      src = File.join(Dir.tempdir, "krikri-remote-missing-#{Random.new.hex(8)}")
      dest = File.tempname("copy-remote-missing-dest")

      result = PluginSpecHelper.run("copy", {"src" => src, "dest" => dest, "remote_src" => "true"})

      result["failed"].as_bool.should be_true
      result["changed"].as_bool.should be_false
      result["msg"].as_s.should eq("Source #{src} not found")
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end
  end

  describe "directory_mode: (mode for directories the copy creates)" do
    # Live-verified against ansible-core 2.19.4: created directories
    # get exactly directory_mode; pre-existing directories are left
    # untouched; and the file's own mode: is NOT applied to created
    # directories (they get the umask default without directory_mode).
    it "applies directory_mode to every directory the copy creates" do
      src_dir = File.join(Dir.tempdir, "krikri-dm-src-#{Random.new.hex(8)}")
      Dir.mkdir_p(File.join(src_dir, "sub"))
      File.write(File.join(src_dir, "a.txt"), "a\n")
      File.write(File.join(src_dir, "sub", "b.txt"), "b\n")

      dest_dir = File.join(Dir.tempdir, "krikri-dm-dest-#{Random.new.hex(8)}")
      result = PluginSpecHelper.run("copy", {"src" => "#{src_dir}/", "dest" => "#{dest_dir}/", "directory_mode" => "0700"})

      result["changed"].as_bool.should be_true
      (File.info(dest_dir).permissions.value & 0o777).should eq(0o700)
      (File.info(File.join(dest_dir, "sub")).permissions.value & 0o777).should eq(0o700)
      File.read(File.join(dest_dir, "a.txt")).should eq("a\n")
    ensure
      FileUtils.rm_rf(src_dir) if src_dir
      FileUtils.rm_rf(dest_dir) if dest_dir
    end

    it "leaves pre-existing directories untouched by directory_mode" do
      src_dir = File.join(Dir.tempdir, "krikri-dm2-src-#{Random.new.hex(8)}")
      Dir.mkdir_p(src_dir)
      File.write(File.join(src_dir, "a.txt"), "a\n")

      dest_dir = File.join(Dir.tempdir, "krikri-dm2-dest-#{Random.new.hex(8)}")
      Dir.mkdir_p(dest_dir)
      File.chmod(dest_dir, 0o755)

      result = PluginSpecHelper.run("copy", {"src" => "#{src_dir}/", "dest" => "#{dest_dir}/", "directory_mode" => "0700"})

      result["changed"].as_bool.should be_true
      (File.info(dest_dir).permissions.value & 0o777).should eq(0o755)
    ensure
      FileUtils.rm_rf(src_dir) if src_dir
      FileUtils.rm_rf(dest_dir) if dest_dir
    end
  end

  describe "unsafe_writes: (non-atomic write fallback)" do
    # On a normal filesystem the rename-based atomic write simply
    # succeeds (live-verified: real Ansible behaves identically with
    # unsafe_writes: true there) - this pins that the happy path is
    # unchanged when the param is given.
    it "writes normally when the atomic path succeeds (param has no effect on a normal filesystem)" do
      dest = File.tempname("copy-uw-ok-dest")

      result = PluginSpecHelper.run("copy", {"content" => "x\n", "dest" => dest, "unsafe_writes" => "true"})

      result["failed"]?.try(&.as_bool).should be_falsey
      result["changed"].as_bool.should be_true
      File.read(dest).should eq("x\n")
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end

    it "preserves an existing dest's mode across an overwrite when no mode: is given (real Ansible's atomic-move behavior)" do
      # Live-verified against ansible-core 2.19.4: an overwrite with no
      # explicit mode: preserves the existing dest's permissions - the
      # rename-based write copies them onto the temp file before the
      # move, exactly like real Ansible's atomic_move does.
      dest = File.tempname("copy-uw-mode-dest")
      File.write(dest, "old\n")
      File.chmod(dest, 0o660)

      result = PluginSpecHelper.run("copy", {"content" => "new\n", "dest" => dest})

      result["changed"].as_bool.should be_true
      File.read(dest).should eq("new\n")
      (File.info(dest).permissions.value & 0o777).should eq(0o660)
    ensure
      File.delete(dest) if dest && File.exists?(dest)
    end
  end
end
