require "../minitest_helper"
require "file_utils"

# community.general.filesystem's "already used as <fs>" failure is a
# fail_json that passes blkid's run_command result along as rc/err
# kwargs (filesystem.py: `fail_json(msg=..., rc=rc, err=err)`), so
# ansible's registered result carries both even though the filesystem
# never gets reformatted. Previously krikri emitted only msg/failed,
# and a playbook reading `r.rc`/`r.err` after ignore_errors (or in a
# rescue) hit an undefined attribute.
private PROJECT_ROOT_FS = File.expand_path("../..", __DIR__)
private BINARY_FS       = File.join(PROJECT_ROOT_FS, "bin", "krikri-playbook")
private INVENTORY_FS    = File.join(PROJECT_ROOT_FS, "test", "fixtures", "inventory-explicit-localhost.ini")

private def filesystem_tools_available? : Bool
  !Process.find_executable("blkid").nil? && !Process.find_executable("mkfs.ext4").nil?
end

# Formats a scratch image as ext4 so the following fstype=xfs task hits
# the "already used as ext4" guard.
private def filesystem_conflict_playbook(image : String, dump : String) : String
  <<-YAML
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - ansible.builtin.command: truncate -s 16M #{image}
        - ansible.builtin.command: mkfs.ext4 -F #{image}
        - community.general.filesystem:
            fstype: xfs
            dev: #{image}
          register: r
          ignore_errors: true
        - ansible.builtin.copy:
            content: |-
              {{ r | to_json }}
            dest: #{dump}
    YAML
end

private def run_filesystem_playbook(playbook : String) : Nil
  path = File.tempname("filesystem-spec", ".yml")
  File.write(path, playbook)
  output = IO::Memory.new
  status = Process.run(BINARY_FS, ["-i", INVENTORY_FS, path], output: output, error: output)
  status.success?.must_equal(true)
ensure
  File.delete(path) if path && File.exists?(path)
end

describe "filesystem already-used failure result" do
  it "includes blkid's rc and err, like ansible's fail_json kwargs" do
    skip("no blkid/mkfs.ext4") unless filesystem_tools_available?

    tmp = PluginSpecHelper.tmp_path("filesystem-conflict")
    FileUtils.mkdir_p(tmp)
    image = File.join(tmp, "fs-demo.img")
    dump = File.join(tmp, "result.json")

    run_filesystem_playbook(filesystem_conflict_playbook(image, dump))
    result = JSON.parse(File.read(dump))

    result.as_h.keys.must_equal(["changed", "failed", "exception", "msg", "rc", "err"])
    result["changed"].as_bool.must_equal(false)
    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("'#{image}' is already used as ext4, use force=true to overwrite")
    result["rc"].as_i64.must_equal(0)
    result["err"].as_s.must_equal("")
  end

  it "carries rc/err in the module's own wire output too" do
    skip("no blkid/mkfs.ext4") unless filesystem_tools_available?

    tmp = PluginSpecHelper.tmp_path("filesystem-wire")
    FileUtils.mkdir_p(tmp)
    image = File.join(tmp, "fs-demo.img")
    Process.run("truncate", ["-s", "16M", image]).success?.must_equal(true)
    Process.run("mkfs.ext4", ["-F", image],
      output: Process::Redirect::Close, error: Process::Redirect::Close).success?.must_equal(true)

    result = PluginSpecHelper.run("filesystem", {"fstype" => "xfs", "dev" => image})

    result.as_h.keys.must_equal(["rc", "err", "failed", "msg", "changed", "exception"])
    result["rc"].as_i64.must_equal(0)
    result["err"].as_s.must_equal("")
  end
end

# Both mkfs and wipefs run through AnsibleModule.run_command(check_rc=True), so
# a non-zero rc is basic.py's own fail_json: the tool's stderr rstripped as
# msg, the shlex-quoted argv (with get_bin_path's resolved executable) as cmd,
# plus rc/stdout/stderr and their *_lines. krikri used to invent a
# "mkfs.ext2 failed: ..." label and drop everything else, which is what a role
# reading the registered result after ignore_errors sees (issue #1855).
describe "filesystem check_rc failure result" do
  it "reports run_command's shape for a failing mkfs, uuid included in cmd" do
    tmp = PluginSpecHelper.tmp_path("filesystem-mkfs-failure")
    stub_dir = File.join(tmp, "stubbin")
    FileUtils.mkdir_p(stub_dir)
    mkfs = File.join(stub_dir, "mkfs.ext2")
    File.write(mkfs, "#!/bin/sh\necho 'mkfs stub: cannot format' >&2\nexit 1\n")
    File.chmod(mkfs, 0o755)
    image = File.join(tmp, "image.img")
    File.write(image, "")

    result = PluginSpecHelper.run("filesystem",
      {"fstype" => "ext2", "dev" => image, "force" => "false", "uuid" => "okypgd"},
      env: {"PATH" => "#{stub_dir}:#{ENV["PATH"]? || "/usr/bin:/bin"}"})

    result.as_h.keys.must_equal(
      ["changed", "cmd", "msg", "rc", "stderr", "stderr_lines", "stdout", "stdout_lines",
       "exception", "failed"])
    result["changed"].as_bool.must_equal(false)
    result["failed"].as_bool.must_equal(true)
    result["rc"].as_i64.must_equal(1)
    result["cmd"].as_s.must_equal("#{mkfs} -F -U okypgd #{image}")
    result["msg"].as_s.must_equal("mkfs stub: cannot format")
    result["stderr"].as_s.must_equal("mkfs stub: cannot format\n")
    result["stderr_lines"].as_a.map(&.as_s).must_equal(["mkfs stub: cannot format"])
    result["stdout"].as_s.must_equal("")
    result["stdout_lines"].as_a.must_equal([] of JSON::Any)
  end

  it "refuses uuid for a fstype that has no uuid support at all" do
    tmp = PluginSpecHelper.tmp_path("filesystem-uuid-unsupported")
    FileUtils.mkdir_p(tmp)
    image = File.join(tmp, "image.img")
    File.write(image, "")

    result = PluginSpecHelper.run("filesystem",
      {"fstype" => "btrfs", "dev" => image, "uuid" => "okypgd"})

    result["failed"].as_bool.must_equal(true)
    result["msg"].as_s.must_equal("module does not support UUID option for this filesystem (btrfs) yet.")
  end
end
