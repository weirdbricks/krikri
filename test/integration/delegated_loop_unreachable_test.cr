require "../minitest_helper"
require "file_utils"
require "../../src/krikri/task_executor/result_display"

# Issue #275: a LOOPED task with delegate_to: pointing at a name that is
# neither in the inventory nor resolvable over ssh. After the
# with_inventory_hostnames fix, the ssh attempt reaches the right (fallback,
# ssh-forced) delegate host - but the per-item unreachable results still
# displayed as bare `ok:` lines and the closure printed a single-task-shaped
# fatal with the ssh detail lost (the message named the ORIGIN host).
#
# Observed ansible-playbook 2.19 shapes being pinned here:
# - each item fails with its own `failed: [host -> delegate] (item=X) => {...}`
#   line, msg "Task failed: Failed to connect to the host via ssh: ssh: Could
#   not resolve hostname <delegate>: Name or service not known" (the ssh
#   transport's own error, lowercased harness text and all);
# - the `[ERROR]: Task failed:` block prints once (Display-level dedup across
#   identical repeats) before the first item's failed: line;
# - the closing fatal carries the RAW, unrendered delegate_to text
#   (`{{ ctl }}`), the loop aggregate's own msg ("All items completed") and
#   the registered per-item entries inside - each with the
#   "(traceback unavailable)" exception placeholder and no stderr key;
# - recap books exactly one unreachable on the origin host; no `ok:` item
#   lines - the ssh error message names the delegate lowercase while the
#   `->` label keeps the original case.
# ignore_unreachable: keeps the same display but books ok+ignored and lets
# the run carry on (rc 0).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")

private DELEGATE_NAME = "your_CA_controller_inventory_hostname"
# The ssh transport's own error for a name the resolver refuses (EAI_NONAME);
# same host-dependent wording the non-looped issue-#102 test asserts.
private SSH_DETAIL = "ssh: Could not resolve hostname #{DELEGATE_NAME.downcase}: Name or service not known"

private def run_play(playbook : String) : {Process::Status, String}
  dir = PluginSpecHelper.tmp_path("delegated-loop-unreach")
  FileUtils.mkdir_p(dir)
  inv = File.join(dir, "inv.ini")
  File.write(inv, "testhost ansible_connection=local\n")
  pb = File.join(dir, "pb.yml")
  File.write(pb, playbook)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", inv, pb, "-T", "5"], output: output, error: output, chdir: dir)
  {status, output.to_s}
ensure
  FileUtils.rm_r(dir) if dir && Dir.exists?(dir)
end

private def find_line(lines : Array(String), prefix : String) : Int32
  lines.index! { |line| line.starts_with?(prefix) }
end

describe "looped delegated task to an unresolvable delegate (issue #275)" do
  it "shows per-item failed lines, the {{ ctl }} fatal and unreachable=1" do
    status, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        vars:
          ctl: #{DELEGATE_NAME}
        tasks:
          - name: Slurp
            slurp:
              src: "{{ item }}"
            with_items:
              - /etc/hostname
              - /etc/passwd
            register: slurpik
            delegate_to: "{{ ctl }}"
      YAML

    status.exit_code.must_equal(4)
    lines = output.lines
    banner = find_line(lines, "TASK [Slurp]")

    # The [ERROR]/"Task failed." block (identical-table dedup shows it once)
    # comes before the per-item lines.
    err = find_line(lines, "[ERROR]: Task failed: ")
    (err > banner).must_equal(true)
    lines[err].must_equal("[ERROR]: Task failed: Failed to connect to the host via ssh: #{SSH_DETAIL}")

    item1 = find_line(lines, "failed: [testhost -> #{DELEGATE_NAME}] (item=/etc/hostname)")
    (item1 > err).must_equal(true)
    lines[item1].must_equal("failed: [testhost -> #{DELEGATE_NAME}] (item=/etc/hostname) => {\"ansible_loop_var\": \"item\", \"changed\": false, \"item\": \"/etc/hostname\", \"msg\": \"Task failed: Failed to connect to the host via ssh: #{SSH_DETAIL}\", \"unreachable\": true}")
    lines[item1 + 1].must_equal("failed: [testhost -> #{DELEGATE_NAME}] (item=/etc/passwd) => {\"ansible_loop_var\": \"item\", \"changed\": false, \"item\": \"/etc/passwd\", \"msg\": \"Task failed: Failed to connect to the host via ssh: #{SSH_DETAIL}\", \"unreachable\": true}")
    lines[item1 + 2].must_equal("fatal: [testhost -> {{ ctl }}]: UNREACHABLE! => {\"changed\": false, \"msg\": \"All items completed\", \"results\": [{\"ansible_loop_var\": \"item\", \"changed\": false, \"exception\": \"(traceback unavailable)\", \"item\": \"/etc/hostname\", \"msg\": \"Task failed: Failed to connect to the host via ssh: #{SSH_DETAIL}\", \"unreachable\": true}, {\"ansible_loop_var\": \"item\", \"changed\": false, \"exception\": \"(traceback unavailable)\", \"item\": \"/etc/passwd\", \"msg\": \"Task failed: Failed to connect to the host via ssh: #{SSH_DETAIL}\", \"unreachable\": true}], \"unreachable\": true}")

    output.wont_include("ok: [testhost")
    output.wont_include("Could not resolve hostname testhost")
    output.must_match(/testhost\s*:\s*ok=0\s+changed=0\s+unreachable=1\s+failed=0/)
  end

  it "keeps run-going accounting with ignore_unreachable: (ok+ignored, rc 0)" do
    status, output = run_play(<<-YAML)
      - hosts: all
        gather_facts: false
        vars:
          ctl: #{DELEGATE_NAME}
        tasks:
          - name: Slurp
            slurp:
              src: /etc/hostname
            with_items:
              - /etc/hostname
            register: slurpik
            delegate_to: "{{ ctl }}"
            ignore_unreachable: true
      YAML

    status.exit_code.must_equal(0)
    lines = output.lines
    item = find_line(lines, "failed: [testhost -> #{DELEGATE_NAME}] (item=/etc/hostname) => {")
    lines[item].must_equal("failed: [testhost -> #{DELEGATE_NAME}] (item=/etc/hostname) => {\"ansible_loop_var\": \"item\", \"changed\": false, \"item\": \"/etc/hostname\", \"msg\": \"Task failed: Failed to connect to the host via ssh: #{SSH_DETAIL}\", \"unreachable\": true}")
    fatal = find_line(lines, "fatal: [testhost -> {{ ctl }}]: UNREACHABLE!")
    (fatal > item).must_equal(true)
    (find_line(lines, "...ignoring") > fatal).must_equal(true)
    output.must_match(/testhost\s*:\s*ok=1\s+changed=0\s+unreachable=0\s+failed=0\s+skipped=0\s+rescued=0\s+ignored=1/)
  end

  # An ssh-origin round cannot run without a real ssh server, so the origin-
  # dependent block shape is pinned on the node builder directly.
  it "collapses the error block to its single brief segment for an ssh origin" do
    msg = "Task failed: Failed to connect to the host via ssh: #{SSH_DETAIL}"
    origin = "Origin: /r/tasks/t.yml:2:3\n\n1 ---\n2 - name: Slurp\n    ^ column 3\n"
    shown = ->(local : Bool) do
      io = IO::Memory.new
      Krikri::ErrorBlock.emit_to(io, Krikri::ResultDisplay.loop_unreachable_error_node(msg, origin, local_origin: local))
      io.to_s
    end

    remote = shown.call(false)
    remote.must_include("[ERROR]: #{msg}\n")
    remote.wont_include("<<< caused by >>>")
    remote.wont_include("Task failed.\n")

    shown.call(true).must_include("<<< caused by >>>")
  end
end
