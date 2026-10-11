require "file_utils"
require "../minitest_helper"

# ansible-core 2.19.11 (live-verified 2026-10-07, byte-identical stdout vs
# this engine) reports a host the implicit Gathering Facts task cannot
# reach as:
#
#   PLAY [all] ...
#   TASK [Gathering Facts] ...
#   [ERROR]: Task failed: Failed to connect to the host via ssh: ssh: connect to host 127.0.0.1 port 1: Connection refused
#
#   Task failed.
#
#   <<< caused by >>>
#
#   Failed to connect to the host via ssh: ssh: connect to host 127.0.0.1 port 1: Connection refused
#
#   fatal: [deadhost]: UNREACHABLE! => {"changed": false, "msg": "Task failed: Failed to connect to the host via ssh: ssh: ...", "unreachable": true}
#   ok: [h1]
#
# Two regressions lived here:
#
#   1. PluginManager.batch_upload_plugins_for_playbook printed the
#      UNREACHABLE! fatal ITSELF - before the `PLAY [` banner (the pass
#      runs before any play executes) - and the task-level report printed
#      it a SECOND time, with a bare connection host instead of the ssh
#      error in the msg.
#   2. report_unreachable wrapped the msg in literal quotes
#      ("msg": "\"Failed to connect ...\""), producing malformed JSON.
#
# The report must appear exactly once, under the Gathering Facts banner,
# carrying the ssh transport's own error text. 127.0.0.1:1 refuses
# instantly, no external host involved.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private PLAY_BINARY  = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

describe "unreachable host at the implicit Gathering Facts task" do
  it "reports once, under the task banner, with the ssh error in the msg" do
    dir = File.tempname("unreachable-gather")
    Dir.mkdir_p(dir)
    File.write(File.join(dir, "inv.ini"),
      "deadhost ansible_host=127.0.0.1 ansible_port=1 ansible_user=root ansible_connection=ssh\n" +
      "h1 ansible_connection=local\n")
    File.write(File.join(dir, "pb.yml"), <<-YAML)
      - hosts: all
        tasks:
          - name: t
            ansible.builtin.debug:
              msg: hi
      YAML

    stdout_io = IO::Memory.new
    status = Process.run(PLAY_BINARY, ["-i", "inv.ini", "pb.yml"],
      output: stdout_io, error: stdout_io, chdir: dir,
      # pin gathering so the ambient developer env (ANSIBLE_GATHERING=smart
      # + a warm fact cache on some dev boxes) cannot mask the implicit
      # gather task
      env: {"PATH" => ENV["PATH"], "HOME" => ENV["HOME"], "ANSIBLE_GATHERING" => "implicit"})
    output = stdout_io.to_s

    status.exit_code.must_equal(4)
    output.wont_include("Unhandled exception")

    # nothing at all prints before the PLAY banner (the old pre-upload
    # fatal printed here)
    pre_banner = output.split("PLAY [", 2).first
    pre_banner.strip.must_be_empty

    # the report lives under the Gathering Facts banner, once
    banner_idx = output.index("TASK [Gathering Facts]")
    fatal_idx = output.index("UNREACHABLE!")
    banner_idx.wont_be_nil
    fatal_idx.wont_be_nil
    (fatal_idx.not_nil! > banner_idx.not_nil!).must_equal(true)
    output.scan("UNREACHABLE!").size.must_equal(1)

    # the fatal msg embeds the ssh transport's own error, prefixed the
    # way ansible-core 2.19 composes task errors
    output.must_include(%(fatal: [deadhost]: UNREACHABLE! => {"changed": false, "msg": "Task failed: Failed to connect to the host via ssh: ssh: connect to host 127.0.0.1 port 1: Connection refused", "unreachable": true}))
    output.wont_include("Failed to upload")

    recap = output.lines.find(&.starts_with?("deadhost"))
    recap.wont_be_nil
    recap.not_nil!.must_include("unreachable=1")
    recap.not_nil!.must_include("failed=0")
  end
end
