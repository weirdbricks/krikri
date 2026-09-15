require "../spec_helper"
require "file_utils"

# fetch's dest-dir creation failure surface.
#
# Real fetch's `flat: false` layout is dest/<hostname>/<src> and the
# containing directories are created on the CONTROLLER inside the action
# plugin's run() (makedirs_safe). When an ancestor is a non-directory -
# dest=/etc/passwd on a local connection lands the file at
# /etc/passwd/target/etc/hostname, and /etc/passwd is a file - the
# AnsibleError escapes run() uncaught, so the failure result is the
# executor's {failed, msg} shape with NO `changed` key at all. A
# registered variable from that failure has `changed` UNDEFINED (not
# false), and `when: r.changed` on it raises the same "has no attribute"
# error real Ansible raises. fetch.cr previously let mkdir_p's exception
# bubble into the generic rescue (changed: false, msg
# "Plugin execution failed: ..."), defining `changed` where real Ansible
# leaves it undefined.
private def with_temp_dir(&)
  dir = File.tempname("fetch-destdir-spec")
  Dir.mkdir_p(dir)
  begin
    yield dir
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe "fetch dest-dir creation failure" do
  it "fails without a changed key when a dest ancestor is a file (controller-side AnsibleError shape)" do
    with_temp_dir do |dir|
      parent = File.join(dir, "parent")
      File.write(parent, "i am a file, not a directory\n")

      src = File.join(dir, "source.txt")
      File.write(src, "fetch me\n")

      result = PluginSpecHelper.run("fetch", {
        "src"  => src,
        "dest" => File.join(parent, "target", "etc"),
      })

      result["failed"].as_bool.should be_true
      result["msg"].as_s.should contain("Unable to create local directories")
      # The load-bearing assertion: no `changed` key at all.
      result["changed"]?.should be_nil
    end
  end
end
