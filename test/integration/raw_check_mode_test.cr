require "../minitest_helper"

# raw: is an action plugin with no module side: its run() answers check
# mode with the bare skip shape BEFORE it reads any argument
# (ansible/plugins/action/raw.py, live-verified against ansible-core
# 2.21.6), so `args: {creates: ...}` never reaches command.py's own gate
# logic. command/shell DO run those gates in check mode and report a
# gated would-run command as "changed:" - raw must keep "skipping:"
# (issue #1738, dustinrue.xenial-bootstrap's "Install python 2.7 on
# xenial").
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

private def run_raw_check_mode_playbook(tasks : String) : {Process::Status, String}
  playbook = File.tempname("raw-check-mode", ".yml")
  File.write(playbook, "- hosts: localhost\n  connection: local\n  gather_facts: false\n  tasks:\n" + tasks)

  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, "--check", playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "raw: check-mode gating" do
  it "skips a creates:-gated raw instead of command's gated would-run changed" do
    marker = File.tempname("raw-check-marker")
    status, output = run_raw_check_mode_playbook(<<-YAML)
          - name: gated raw
            raw: echo raw-check-probe
            args:
              creates: #{marker}
        YAML

    status.success?.must_equal(true)
    output.must_include("skipping: [localhost]")
    output.must_match(/skipped=1\b/)
    output.wont_include("changed: [localhost]")
    output.wont_include("raw-check-probe")
  end

  it "skips a creates:-gated raw whose marker already exists, without the command module's ok/wording" do
    marker = File.tempname("raw-check-present-marker")
    File.write(marker, "x")
    status, output = run_raw_check_mode_playbook(<<-YAML)
          - name: gated raw
            raw: echo raw-check-probe
            args:
              creates: #{marker}
        YAML

    status.success?.must_equal(true)
    output.must_include("skipping: [localhost]")
    output.wont_include("Would not run command since")
  ensure
    File.delete(marker) if marker && File.exists?(marker)
  end
end
