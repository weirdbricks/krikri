require "../minitest_helper"
require "file_utils"

# Issue #13: an identical `[WARNING]` printed twice where ansible-core 2.19.11
# prints it once. A `service:` task passing an UNUSED_PARAMS param (e.g.
# `pattern=`) makes krikri emit the warning from TWO sources - the
# controller-side argspec validator and the module result's own `warnings`
# list - and those used two separate dedupe sets, so the same line printed
# twice. Real dedupes GLOBALLY in Display.warning (`_warns`, keyed on the
# formatted "[WARNING]: {msg}" line, utils/display.py _deduplicate), so the
# console shows one line per distinct message per run - live-verified vs
# 2.19.11 with `service: {pattern: ...}` on a systemd host (one line, and one
# line even when two identical tasks both raise it).
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_play(playbook : String) : String
  root = File.tempname("service-warning-dedupe")
  Dir.mkdir_p(root)
  File.write(File.join(root, "pb.yml"), playbook)
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, "--check", "pb.yml"], output: output, error: output, chdir: root)
  output.to_s
ensure
  FileUtils.rm_rf(root) if root
end

describe "identical warnings dedupe like Display.warning" do
  it "prints the unused-param warning once, not once per emitting source" do
    playbook = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          # nonexistent unit: the module fails before touching anything real
          - name: svc
            ansible.builtin.service:
              name: krikri-no-such-unit-xyz
              state: started
              pattern: krikri
              use: systemd
      YAML

    output = run_play(playbook)

    output.scan("[WARNING]: Ignoring \"pattern\" as it is not used in \"systemd\"").size
      .must_equal(1, output)
  end

  # Per-run dedupe: real's Display._warns lives on the Display instance for
  # the whole run, so a second task raising the SAME message adds no line.
  # A different param (`sleep:`) keeps this independent of the first test's
  # process-wide dedupe state (minitest runs `it`s in one process).
  it "prints the warning once even when two identical tasks both raise it" do
    playbook = <<-YAML
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: svc a
            ansible.builtin.service:
              name: krikri-no-such-unit-xyz
              state: started
              sleep: 5
              use: systemd
          - name: svc b
            ansible.builtin.service:
              name: krikri-no-such-unit-xyz
              state: started
              sleep: 5
              use: systemd
      YAML

    output = run_play(playbook)

    output.scan("[WARNING]: Ignoring \"sleep\" as it is not used in \"systemd\"").size
      .must_equal(1, output)
  end
end
