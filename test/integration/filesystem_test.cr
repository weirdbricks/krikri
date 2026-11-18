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
