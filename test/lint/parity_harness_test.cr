require "../minitest_helper"
require "file_utils"

# testing/lint/parity.py is Python, but the one thing that decides whether an
# opt-in rule is visible at all is the argv it hands the two linters: with no
# --enable-list both tools report nothing for such a rule, so the harness
# compares zero triples and prints a clean run (issue #1926). Stub linters that
# emit a triple only when the flag names the rule pin that contract without
# needing ansible-lint in the fast suite.
describe "lint parity harness" do
  it "enables opt-in rules on both linters" do
    python = Process.find_executable("python3") || Process.find_executable("python")
    skip "no python on this host (the harness is a Python script)" unless python

    dir = PluginSpecHelper.tmp_path("parity-harness")
    FileUtils.mkdir_p(dir)
    target = File.join(dir, "pb.yml")
    File.write(target, "---\n- name: Play\n  hosts: all\n  tasks: []\n")

    krikri = write_parity_linter_stub(File.join(dir, "krikri-lint"), target, "no-same-owner")
    ansible = write_parity_linter_stub(File.join(dir, "ansible-lint"), target, "no-same-owner")

    output = IO::Memory.new
    status = Process.run(
      python,
      [File.join(PluginSpecHelper::PROJECT_ROOT, "testing", "lint", "parity.py"),
       "--krikri", krikri, "--ansible-lint", ansible, target],
      output: output,
      error: output
    )
    status.success?.must_equal(true)
    output.to_s.must_include("PARITY| files=1 matched=1 krikri_only=0 upstream_only=0 unimplemented=0")
  end
end

# A stub linter that advertises one opt-in rule for --list-rules and reports it
# only when --enable-list named it, the way both real linters behave.
private def write_parity_linter_stub(path : String, target : String, rule : String) : String
  File.write(path, <<-SH)
    #!/bin/sh
    for arg in "$@"; do
      if [ "$arg" = "--list-rules" ]; then
        echo "#{rule}"
        exit 0
      fi
    done
    for arg in "$@"; do
      if [ "$arg" = "#{rule}" ]; then
        echo "#{target}:7: #{rule}: opt-in rule fired"
        exit 0
      fi
    done
    exit 0
    SH
  File.chmod(path, 0o755)
  path
end
