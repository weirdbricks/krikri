require "../minitest_helper"

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String) : {Process::Status, String}
  playbook = File.tempname("raw-trailing-newline", ".yml")
  File.write(playbook, yaml)
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

# Real's raw action runs the command through the connection
# (_low_level_execute_command), so the command module's strip_empty_ends
# trailing-\r\n rstrip never applies to a raw result: its stdout/stderr
# keep their trailing newline (live-verified vs 2.19.11, issue #896 -
# `raw: echo hi` registers stdout "hi\n", and a failed spawn keeps dash's
# "...not found\n" on stderr). stderr_lines/stdout_lines are splitlines()
# of that text, so they stay newline-free on both engines. krikri aliases
# raw onto the shell plugin, whose strip_empty_ends defaulted to true and
# used to eat that newline.
describe "raw: result streams" do
  it "keep their trailing newline on a non-zero rc - the strip_empty_ends default does not apply to raw" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: raw two streams
            ansible.builtin.raw: echo out; echo err 1>&2; exit 7
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("\"stdout\": \"out\\n\"")
    output.must_include("\"stdout_lines\": [\"out\"]")
    output.must_include("\"stderr\": \"err\\n\"")
    output.must_include("\"stderr_lines\": [\"err\"]")
  end

  it "keep dash's trailing newline on stderr when the command is missing" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: raw missing binary
            ansible.builtin.raw: /opt/kpg-fixtures/script.sh_bogus
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("\"stderr\": \"/bin/sh: 1: /opt/kpg-fixtures/script.sh_bogus: not found\\n\"")
    output.must_include("\"stderr_lines\": [\"/bin/sh: 1: /opt/kpg-fixtures/script.sh_bogus: not found\"]")
  end
end
