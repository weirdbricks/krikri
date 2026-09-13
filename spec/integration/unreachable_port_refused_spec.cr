require "file_utils"
require "../spec_helper"

# A host that actively REFUSES the connection (closed port, not a
# nonexistent name) must be reported and skipped by BOTH drivers, never
# crash the process. Two regressions lived here:
#
#   1. bin/krikri (ad-hoc) discarded batch_upload_plugins_for_playbook's
#      unreachable-host return value and never told the executor, so the
#      per-task lazy-upload path re-attempted the connection and raised
#      an uncaught "Failed to upload ..." that killed the whole run with
#      a stack trace - while krikri-playbook reported cleanly.
#   2. A host that survives the pre-run batch pass but goes unreachable
#      before its lazy upload (the include_tasks: case, or a network
#      drop mid-play) hit the same unguarded raise in
#      PluginManager#execute_remote_plugin.
#
# Real Ansible never ends a run for one bad host: every transport
# failure becomes a per-host UNREACHABLE result. Port 9 (discard) on
# 127.0.0.1 reliably refuses without depending on external hosts.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private ADHOC_BINARY = File.join(PROJECT_ROOT, "bin", "krikri")
private PLAY_BINARY  = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private REFUSED_HOST = "refused ansible_connection=ssh ansible_host=127.0.0.1 ansible_user=nobody ansible_port=9\n"

private def with_inventory(&block : String -> Nil) : Nil
  dir = File.tempname("unreachable-refused")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "inv.ini"), REFUSED_HOST)
  block.call(dir)
ensure
  FileUtils.rm_rf(dir) if dir && Dir.exists?(dir)
end

describe "unreachable host (connection refused)" do
  it "ad-hoc driver reports UNREACHABLE and exits 4 instead of crashing" do
    with_inventory do |dir|
      stdout_io = IO::Memory.new
      status = Process.run(ADHOC_BINARY, ["all", "-i", "inv.ini", "-m", "ping"],
        output: stdout_io, error: stdout_io, chdir: dir)
      output = stdout_io.to_s

      status.exit_code.should eq(4)
      output.should_not contain("Unhandled exception")
      output.should contain("UNREACHABLE!")
      output.should contain("refused")
    end
  end

  it "playbook driver reports UNREACHABLE with a clean recap and exits 4" do
    with_inventory do |dir|
      File.write(File.join(dir, "pb.yml"), <<-YAML)
        - hosts: all
          gather_facts: false
          tasks:
            - name: t
              ansible.builtin.ping:
        YAML

      stdout_io = IO::Memory.new
      status = Process.run(PLAY_BINARY, ["-i", "inv.ini", "-T", "5", "pb.yml"],
        output: stdout_io, error: stdout_io, chdir: dir)
      output = stdout_io.to_s

      status.exit_code.should eq(4)
      output.should_not contain("Unhandled exception")
      output.should contain("UNREACHABLE!")
      output.should match(/refused\s+: ok=0\s+changed=0\s+unreachable=1\s+failed=0/)
    end
  end
end
