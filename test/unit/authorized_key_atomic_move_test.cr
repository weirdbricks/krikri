require "../minitest_helper"
require "file_utils"

# Regression spec for issue #819 (RedHatGov.copy_local_pub_key): authorized_key
# used to write dest with a direct File.write, while real's module writes the
# new content to a /tmp mkstemp temp and runs it through
# AnsibleModule.atomic_move's rename ladder. On a dest the ladder cannot land
# (the round's bind-mounted authorized_keys: the final rename fails EBUSY)
# real crashes with "Unable to make ... failed final rename from ..." while a
# direct write reports a different errno from a different syscall; and on a
# dest whose DIRECTORY refuses real's stage mkstemp the crash names the
# not-writable directory, which a direct write never mentions at all.
#
# Both scenarios here need no root: a directory the suite user cannot write
# (mode 0555, owned by itself) fails the rename and the mkstemp for any
# non-root user. Root writes through mode 0555, so the ladder that is under
# test never runs - CI runs the suite as root inside its container.
describe "authorized_key: atomic_move write ladder" do
  it "crashes with real's not-writable-directory shape when the dest dir refuses the stage mkstemp" do
    skip "root ignores the 0555 directory this spec needs" if PluginSpecHelper.running_as_root?

    cwd = PluginSpecHelper.tmp_path("ak-atomic-ro-dir")
    dir = File.join(cwd, "d")
    FileUtils.mkdir_p(dir)
    dest = File.join(dir, "authorized_keys")
    File.write(dest, "stale\n")
    File.chmod(dest, 0o644)
    File.chmod(dir, 0o555)

    begin
      result = PluginSpecHelper.run("authorized_key", {
        "user"       => "root",
        "key"        => "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl kpg",
        "path"       => dest,
        "manage_dir" => "false",
      }, chdir: cwd)

      result["failed"].as_bool.must_equal(true)
      msg = result["msg"].as_s
      # real's crash chain, joined: the wrapper message (its trailing period
      # stripped by the same ": " concat join real's chain brief uses) + the
      # mkstemp OSError - whose candidate path real passes as bytes, hence
      # the b'...' repr. The random stage name is matched loosely.
      msg.starts_with?("Task failed: Module failed: The destination directory '#{dir}' is not writable by the current user: [Errno 13] Permission denied: b'").must_equal(true)
      msg.includes?(".ansible_tmp").must_equal(true)
      msg.includes?("authorized_keys'").must_equal(true)
      # the failed ladder left dest untouched
      File.read(dest).must_equal("stale\n")
    ensure
      File.chmod(dir, 0o755)
    end
  end

  it "still lands the key through the rename ladder on a normal writable dest" do
    cwd = PluginSpecHelper.tmp_path("ak-atomic-ok")
    FileUtils.mkdir_p(cwd)
    dest = File.join(cwd, "authorized_keys")
    File.write(dest, "stale\n")
    File.chmod(dest, 0o644)

    result = PluginSpecHelper.run("authorized_key", {
      "user"       => "root",
      "key"        => "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl kpg",
      "path"       => dest,
      "manage_dir" => "false",
    }, chdir: cwd)

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    content = File.read(dest)
    content.includes?("stale").must_equal(true)
    content.includes?("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl kpg").must_equal(true)
  end

  it "still creates a missing dest file through the ladder" do
    cwd = PluginSpecHelper.tmp_path("ak-atomic-create")
    FileUtils.mkdir_p(cwd)
    dest = File.join(cwd, "authorized_keys")

    result = PluginSpecHelper.run("authorized_key", {
      "user"       => "root",
      "key"        => "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl kpg",
      "path"       => dest,
      "manage_dir" => "false",
    }, chdir: cwd)

    result["failed"]?.must_be_nil
    result["changed"].as_bool.must_equal(true)
    File.read(dest).includes?("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl kpg").must_equal(true)
  end
end
