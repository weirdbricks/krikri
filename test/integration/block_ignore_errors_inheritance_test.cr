require "../minitest_helper"
require "file_utils"

# Block-level ignore_errors: inheritance. The parser used to hardcode
# `ignore_errors = true` onto every block:/rescue:/always: child, so a
# block whose ignore_errors resolved FALSE (a plain `ignore_errors:
# false`, or the exphost.create_user idiom
# `ignore_errors: "{{ ignore_erros|default(False) }}"` - note the role's
# own typo'd variable name - resolved False at runtime) silently IGNORED
# every member failure and kept executing tasks on a host Ansible had
# already halted (round 5250000, exphost.mysql's dependency role). Also
# fixed on the way: the runtime resolver's no-context fallback evaluated
# the expression against an ansible_check_mode-only scope and fell back
# to the parse-time default-to-true guess for exactly this shape. All
# shapes below verified against ansible-playbook 2.19.11.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_block_playbook(ignore_block : String, child_ignore : String? = nil) : String
  child_line = child_ignore ? "          ignore_errors: #{child_ignore}\n" : ""
  playbook = File.tempname("block-ignore", ".yml")
  File.write(playbook, <<-YAML
    - hosts: localhost
      connection: local
      gather_facts: false
      vars:
        flag: false
      tasks:
        - block:
            - fail:
                msg: "boom"
            - debug:
                msg: "after-fail"
          ignore_errors: #{ignore_block}
        - debug:
            msg: "outside"
    YAML
  )
  output = IO::Memory.new
  Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  output.to_s
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "block-level ignore_errors inheritance (block_ignore_errors_inheritance_test.cr)" do
  it "halts on a member failure when the block's ignore_errors is the literal false" do
    output = run_block_playbook("false")
    output.must_match(/failed=1\b/)
    output.must_include("ignored=0")
    output.wont_include("after-fail")
    output.wont_include("outside")
  end

  it "halts on a member failure when the block's ignore_errors is templated False" do
    output = run_block_playbook(%({"{ ignore_erros | default(False) }"}))
    output.must_match(/failed=1\b/)
    output.wont_include("after-fail")
    output.wont_include("outside")
  end

  it "keeps ignoring member failures when the block's ignore_errors is true" do
    output = run_block_playbook("true")
    output.must_include("after-fail")
    output.must_include("outside")
    output.must_match(/ignored=1\b/)
  end

  it "halts on a member failure when the block's ignore_errors is a False variable" do
    playbook = File.tempname("block-ignore-var", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        vars:
          flag: false
        tasks:
          - block:
              - fail:
                  msg: "boom"
              - debug:
                  msg: "after-fail"
            ignore_errors: "{{ flag }}"
      YAML
    output = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
    output.to_s.must_match(/failed=1\b/)
    output.to_s.wont_include("after-fail")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
