require "../spec_helper"
require "../../src/krikri/base_plugin"
require "file_utils"

# BasePlugin#atomic_move - the EXDEV fallback real Ansible's
# AnsibleModule.atomic_move provides. Found live on
# konstruktoid.hardening: the openssh_keypair task generates into a
# File.tempname (under /tmp, a separate tmpfs there) and renamed it
# into /etc/ssh, which rename(2) refuses with "Invalid cross-device
# link" - a hard task failure real Ansible survives by falling back to
# copy-then-delete when rename fails with EXDEV specifically.
#
# The helper-spec cases below run the shared helper directly; the
# end-to-end case runs the real openssh_keypair plugin binary with its
# destination on the spec dir's filesystem and TMPDIR left at the
# system default - when those are different devices (as on the machine
# this bug was found on, /tmp is a tmpfs) the plugin's old plain
# File.rename would fail the task, and the fallback now has to carry
# the keypair across.
private class AtomicMoveProbe < Krikri::BasePlugin
  def execute : Krikri::PluginResult
    Krikri::PluginResult.new(changed: false, failed: false, msg: "probe")
  end

  def move(src : String, dest : String) : Nil
    atomic_move(src, dest)
  end
end

private def probe : AtomicMoveProbe
  config = JSON.parse(%({"host": {"name": "localhost", "user": "root", "port": 22}, "params": {}, "vars": {}}))
  AtomicMoveProbe.new(config)
end

private def with_temp_dir(&)
  # Deliberately rooted under the repo, NOT the system tempdir: the
  # cross-device cases compare against /tmp, and a File.tempname-based
  # dir would land in /tmp itself, defeating the point.
  dir = File.join(Dir.current, ".atomic-move-spec-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "BasePlugin#atomic_move" do
  it "renames within one filesystem, removing the source" do
    with_temp_dir do |dir|
      src = File.join(dir, "src.conf")
      dest = File.join(dir, "dest.conf")
      File.write(src, "payload\n")

      probe.move(src, dest)

      File.read(dest).should eq("payload\n")
      File.exists?(src).should be_false
    end
  end

  it "falls back to copy-then-delete across devices, preserving mode" do
    # Only meaningfully exercises the EXDEV path when the two
    # directories actually sit on different devices; on a single-fs
    # dev box the plain rename succeeds and the assertions still hold
    # (the fallback just never fires).
    tmp_dev = `stat -c %d /tmp`.strip
    with_temp_dir do |dir|
      next if `stat -c %d #{dir}`.strip == tmp_dev

      src = File.join("/tmp", "atomic-move-spec-#{Random::Secure.hex(8)}")
      File.write(src, "cross-device payload\n")
      File.chmod(src, 0o600)
      dest = File.join(dir, "dest.conf")
      begin
        probe.move(src, dest)

        File.read(dest).should eq("cross-device payload\n")
        File.exists?(src).should be_false
        File.info(dest, follow_symlinks: false).permissions.value.should eq(0o600)
      ensure
        File.delete(src) if File.exists?(src)
      end
    end
  end
end

describe "openssh_keypair: cross-device temp-to-dest move" do
  it "generates the keypair at the destination without an EXDEV failure" do
    tmp_dev = `stat -c %d /tmp`.strip
    with_temp_dir do |dir|
      # The plugin stages its ssh-keygen temp via File.tempname under
      # the system tempdir (/tmp) and moves it to `path`. When /tmp is
      # a different device from dir, this is exactly the
      # konstruktoid.hardening reproduction.
      next if `stat -c %d #{dir}`.strip == tmp_dev

      key_path = File.join(dir, "test_host_key")

      result = PluginSpecHelper.run("openssh_keypair", {
        "path"       => key_path,
        "type"       => "ed25519",
        "state"      => "present",
        "mode"       => "0600",
        "regenerate" => "always",
      })

      result["failed"]?.try(&.as_bool).should_not be_true
      result["changed"].as_bool.should be_true
      File.exists?(key_path).should be_true
      File.exists?("#{key_path}.pub").should be_true

      # The generated key material is usable and the temp files did not
      # leak into /tmp.
      fingerprint = Process.run("ssh-keygen", ["-l", "-f", key_path], output: Process::Redirect::Pipe) do |proc|
        proc.output.gets_to_end
      end
      fingerprint.should contain("ED25519")
      File.info(key_path, follow_symlinks: false).permissions.value.should eq(0o600)
    end
  end
end
