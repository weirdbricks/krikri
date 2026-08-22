require "../spec_helper"
require "file_utils"
require "system/user"

private TMP_DIR = File.join(PluginSpecHelper::PROJECT_ROOT, "spec", "tmp", "file")

Spec.before_suite do
  FileUtils.rm_rf(TMP_DIR) if Dir.exists?(TMP_DIR)
  Dir.mkdir_p(TMP_DIR)
end

private def tmp_path(name : String) : String
  File.join(TMP_DIR, name)
end

describe "file plugin" do
  describe "state=directory" do
    it "creates a directory that doesn't exist yet" do
      path = tmp_path("newdir")
      result = PluginSpecHelper.run("file", {"path" => path, "state" => "directory", "mode" => "0750"})

      result["changed"].as_bool.should be_true
      result["failed"].as_bool.should be_false
      Dir.exists?(path).should be_true
      (File.info(path, follow_symlinks: false).permissions.value & 0o777).should eq(0o750)
    end

    it "is idempotent when the directory already exists with correct mode" do
      path = tmp_path("idempotentdir")
      PluginSpecHelper.run("file", {"path" => path, "state" => "directory", "mode" => "0755"})
      result = PluginSpecHelper.run("file", {"path" => path, "state" => "directory", "mode" => "0755"})

      result["changed"].as_bool.should be_false
    end

    it "reports changed but doesn't create anything in check mode" do
      path = tmp_path("checkmodedir")
      result = PluginSpecHelper.run("file", {"path" => path, "state" => "directory", "check_mode" => "true"})

      result["changed"].as_bool.should be_true
      Dir.exists?(path).should be_false
    end
  end

  describe "state=touch" do
    it "creates a new file" do
      path = tmp_path("touched.txt")
      result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch", "mode" => "0640"})

      result["changed"].as_bool.should be_true
      File.exists?(path).should be_true
      (File.info(path, follow_symlinks: false).permissions.value & 0o777).should eq(0o640)
    end

    it "updates mtime on an existing file" do
      path = tmp_path("retouch.txt")
      File.write(path, "x")
      old_mtime = File.info(path).modification_time
      sleep 1.1.seconds
      result = PluginSpecHelper.run("file", {"path" => path, "state" => "touch"})

      result["changed"].as_bool.should be_true
      File.info(path).modification_time.should be > old_mtime
    end

    it "expands a leading ~ in path using $HOME (real Ansible's file module is type: path)" do
      original_home = ENV["HOME"]?
      home = File.join(Dir.tempdir, "crystal_ansible_spec_home_#{Random.rand(100_000)}")
      Dir.mkdir_p(home)
      ENV["HOME"] = home
      begin
        result = PluginSpecHelper.run("file", {"path" => "~/tilde_touched.txt", "state" => "touch"})

        result["changed"].as_bool.should be_true
        result["failed"].as_bool.should be_false
        File.exists?(File.join(home, "tilde_touched.txt")).should be_true
      ensure
        FileUtils.rm_rf(home)
        ENV["HOME"] = original_home if original_home
      end
    end
  end

  describe "state=file" do
    it "fails when the path doesn't exist" do
      result = PluginSpecHelper.run("file", {"path" => tmp_path("missing.txt"), "state" => "file"})

      result["failed"].as_bool.should be_true
    end

    it "updates a directory's attributes under its default state: file" do
      # Real Ansible's file module applies owner/group/mode to whatever type
      # the path already is - a directory at a state: file task (no explicit
      # state: directory) is updated, not an error. dev-sec os_hardening
      # loops such a task over /etc/crontab plus the /etc/cron.* directories.
      path = tmp_path("adir")
      Dir.mkdir_p(path)
      File.chmod(path, 0o755)

      result = PluginSpecHelper.run("file", {"path" => path, "state" => "file", "mode" => "0700"})

      result["failed"].as_bool.should be_false
      result["changed"].as_bool.should be_true
      (File.info(path, follow_symlinks: false).permissions.value & 0o777).should eq(0o700)
    end

    it "updates mode on an existing file and is idempotent afterward" do
      path = tmp_path("modefile.txt")
      File.write(path, "x")
      File.chmod(path, 0o644)

      changed = PluginSpecHelper.run("file", {"path" => path, "state" => "file", "mode" => "0600"})
      changed["changed"].as_bool.should be_true
      (File.info(path, follow_symlinks: false).permissions.value & 0o777).should eq(0o600)

      unchanged = PluginSpecHelper.run("file", {"path" => path, "state" => "file", "mode" => "0600"})
      unchanged["changed"].as_bool.should be_false
    end

    it "applies a symbolic mode (the one narrow shell-fallback path)" do
      path = tmp_path("symbolic.txt")
      File.write(path, "x")
      File.chmod(path, 0o644)

      result = PluginSpecHelper.run("file", {"path" => path, "state" => "file", "mode" => "u+x"})

      result["failed"].as_bool.should be_false
      (File.info(path, follow_symlinks: false).permissions.value & 0o100).should eq(0o100)
    end

    it "preserves setuid/setgid/sticky bits in change detection" do
      path = tmp_path("setuid.txt")
      File.write(path, "x")
      File.chmod(path, 0o4755)

      result = PluginSpecHelper.run("file", {"path" => path, "state" => "file", "mode" => "4755"})
      result["changed"].as_bool.should be_false
    end
  end

  describe "state=link" do
    it "creates a symbolic link" do
      target = tmp_path("linktarget.txt")
      link = tmp_path("mylink")
      File.write(target, "hi")

      result = PluginSpecHelper.run("file", {"path" => link, "src" => target, "state" => "link"})

      result["changed"].as_bool.should be_true
      File.symlink?(link).should be_true
      File.readlink(link).should eq(target)
    end

    it "is idempotent when the link already points to src" do
      target = tmp_path("linktarget2.txt")
      link = tmp_path("mylink2")
      File.write(target, "hi")
      PluginSpecHelper.run("file", {"path" => link, "src" => target, "state" => "link"})

      result = PluginSpecHelper.run("file", {"path" => link, "src" => target, "state" => "link"})
      result["changed"].as_bool.should be_false
    end

    it "refuses to overwrite an existing regular file without force" do
      target = tmp_path("linktarget3.txt")
      path = tmp_path("occupied")
      File.write(target, "hi")
      File.write(path, "already here")

      result = PluginSpecHelper.run("file", {"path" => path, "src" => target, "state" => "link"})
      result["failed"].as_bool.should be_true
      File.symlink?(path).should be_false
    end

    it "overwrites an existing file when force=yes" do
      target = tmp_path("linktarget4.txt")
      path = tmp_path("occupied2")
      File.write(target, "hi")
      File.write(path, "already here")

      result = PluginSpecHelper.run("file", {"path" => path, "src" => target, "state" => "link", "force" => "yes"})
      result["changed"].as_bool.should be_true
      File.symlink?(path).should be_true
    end
  end

  describe "state=hard" do
    it "creates a hard link" do
      target = tmp_path("hardtarget.txt")
      path = tmp_path("hardlink")
      File.write(target, "hi")

      result = PluginSpecHelper.run("file", {"path" => path, "src" => target, "state" => "hard"})

      result["changed"].as_bool.should be_true
      File.same?(path, target).should be_true
    end

    it "is idempotent when the hard link already exists" do
      target = tmp_path("hardtarget2.txt")
      path = tmp_path("hardlink2")
      File.write(target, "hi")
      PluginSpecHelper.run("file", {"path" => path, "src" => target, "state" => "hard"})

      result = PluginSpecHelper.run("file", {"path" => path, "src" => target, "state" => "hard"})
      result["changed"].as_bool.should be_false
    end
  end

  describe "state=absent" do
    it "removes a regular file" do
      path = tmp_path("toremove.txt")
      File.write(path, "bye")

      result = PluginSpecHelper.run("file", {"path" => path, "state" => "absent"})
      result["changed"].as_bool.should be_true
      File.exists?(path).should be_false
    end

    it "removes a directory recursively" do
      path = tmp_path("toremovedir")
      Dir.mkdir_p(File.join(path, "nested"))
      File.write(File.join(path, "nested", "f.txt"), "x")

      result = PluginSpecHelper.run("file", {"path" => path, "state" => "absent"})
      result["changed"].as_bool.should be_true
      Dir.exists?(path).should be_false
    end

    it "reports changed: false when already absent" do
      result = PluginSpecHelper.run("file", {"path" => tmp_path("never-existed"), "state" => "absent"})
      result["changed"].as_bool.should be_false
      result["failed"].as_bool.should be_false
    end
  end

  describe "owner/group" do
    it "is a no-op when owner/group already match" do
      path = tmp_path("ownerfile.txt")
      File.write(path, "x")
      me = System::User.find_by?(id: LibC.getuid.to_s).not_nil!.username

      result = PluginSpecHelper.run("file", {"path" => path, "state" => "file", "owner" => me})
      result["changed"].as_bool.should be_false
    end

    it "fails (matching real Ansible's own 'chown failed: failed to look up user') when owner: names a nonexistent user" do
      # Real bug found benchmarking robertdebock.openbao_agent on Rocky
      # 9.6 (round 162): a directory-creation task with `owner: openbao`
      # BEFORE any earlier task creates that system user - real
      # ansible-playbook correctly fails ("chown failed: failed to look
      # up user openbao"); this previously left the chown uid at its -1
      # sentinel (never set, never checked) and simply never attempted
      # the chown at all, silently creating the directory as root:root
      # and reporting success.
      path = tmp_path("nonexistent-owner-dir")
      result = PluginSpecHelper.run("file", {"path" => path, "state" => "directory", "owner" => "nonexistent_user_xyz_abc"})

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("chown failed: failed to look up user nonexistent_user_xyz_abc")
    end

    it "fails when group: names a nonexistent group" do
      path = tmp_path("nonexistent-group-dir")
      result = PluginSpecHelper.run("file", {"path" => path, "state" => "directory", "group" => "nonexistent_group_xyz_abc"})

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("chown failed: failed to look up group nonexistent_group_xyz_abc")
    end
  end

  describe "recurse" do
    it "applies mode to every file and directory under path" do
      root = tmp_path("recursedir")
      Dir.mkdir_p(File.join(root, "sub"))
      File.write(File.join(root, "a.txt"), "x")
      File.write(File.join(root, "sub", "b.txt"), "x")
      File.chmod(root, 0o755)
      File.chmod(File.join(root, "a.txt"), 0o644)
      File.chmod(File.join(root, "sub"), 0o755)
      File.chmod(File.join(root, "sub", "b.txt"), 0o644)

      result = PluginSpecHelper.run("file", {"path" => root, "state" => "directory", "mode" => "0700", "recurse" => "yes"})
      result["changed"].as_bool.should be_true

      (File.info(root, follow_symlinks: false).permissions.value & 0o777).should eq(0o700)
      (File.info(File.join(root, "a.txt"), follow_symlinks: false).permissions.value & 0o777).should eq(0o700)
      (File.info(File.join(root, "sub"), follow_symlinks: false).permissions.value & 0o777).should eq(0o700)
      (File.info(File.join(root, "sub", "b.txt"), follow_symlinks: false).permissions.value & 0o777).should eq(0o700)
    end
  end

  describe "creating a nested directory path" do
    it "applies mode to every newly-created intermediate component, not just the leaf" do
      # Real bug found benchmarking geerlingguy.solr: "Ensure Solr conf
      # directories exist." (path: .../data/collection1/conf, owner:
      # solr_user, recurse: true) needed a LATER become_user: solr task
      # to delete/recreate that same conf/ subdirectory - which needs
      # WRITE permission on its PARENT (collection1). Dir.mkdir_p
      # created the whole missing chain in one shot with no
      # per-component hook, so #apply_file_attributes only ever ran on
      # the leaf afterward - every newly-created ANCESTOR directory
      # (collection1 itself) kept the default mode/owner from whoever
      # ran this process (root), not the requested one.
      root = tmp_path("nesteddir")
      leaf = File.join(root, "middle", "conf")

      result = PluginSpecHelper.run("file", {"path" => leaf, "state" => "directory", "mode" => "0700"})
      result["changed"].as_bool.should be_true

      (File.info(root, follow_symlinks: false).permissions.value & 0o777).should eq(0o700)
      (File.info(File.join(root, "middle"), follow_symlinks: false).permissions.value & 0o777).should eq(0o700)
      (File.info(leaf, follow_symlinks: false).permissions.value & 0o777).should eq(0o700)
    end
  end
end
