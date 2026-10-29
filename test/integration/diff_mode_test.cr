require "file_utils"
require "../minitest_helper"

# Runs the compiled binary, since the magic-var binding happens in the
# executor's vars context and --diff is a CLI flag, neither reachable
# from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(__DIR__, "..", "fixtures", "inventory-explicit-localhost.ini")

# Found benchmarking linux-system-roles.firewall (round 970345): its
# "Show diffs" task guards with `when: ansible_check_mode or
# ansible_diff_mode or ...`, which hard-failed ("'ansible_diff_mode' is
# undefined") where ansible-playbook just skips - ansible_check_mode
# was bound as a magic var, its --diff sibling was not.
describe "ansible_diff_mode magic var" do
  it "defaults to false on a plain run instead of being undefined" do
    playbook = File.tempname("diff-mode-default", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Show diffs
            ansible.builtin.debug:
              msg: DIFF_SHOULD_NOT_SHOW
            when: ansible_check_mode or ansible_diff_mode or extra_flag | d(false)
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.wont_include("'ansible_diff_mode' is undefined")
    output.to_s.wont_include("DIFF_SHOULD_NOT_SHOW")
    output.to_s.must_match(/skipped=1\b/)
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "flips to true under --diff and lets the guarded task run" do
    playbook = File.tempname("diff-mode-on", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Show diffs
            ansible.builtin.debug:
              msg: DIFF_SHOULD_SHOW
            when: ansible_check_mode or ansible_diff_mode or extra_flag | d(false)
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["--diff", "-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("DIFF_SHOULD_SHOW")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  # Issue #457 (live-verified vs ansible-core 2.19.11): the task-level
  # `diff:` keyword overrides the --diff flag for that task - `diff: true`
  # shows the file diff on a plain run, `diff: false` suppresses it under
  # --diff - for both the module's diff payload (via _ansible_diff) and
  # the callback's display.
  it "shows the copy diff on a plain run with task-level diff: true" do
    playbook = File.tempname("task-diff-on", ".yml")
    dest = PluginSpecHelper.tmp_path("task-diff-on.txt")
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Diff without --diff
            ansible.builtin.copy:
              content: "hello\\n"
              dest: #{dest}
            diff: true
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("--- before")
    output.to_s.must_include("+++ after: #{dest}")
    output.to_s.must_include("+hello")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end

  it "suppresses the copy diff under --diff with task-level diff: false" do
    playbook = File.tempname("task-diff-off", ".yml")
    dest = PluginSpecHelper.tmp_path("task-diff-off.txt")
    FileUtils.mkdir_p(File.dirname(dest))
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: No diff despite --diff
            ansible.builtin.copy:
              content: "hello\\n"
              dest: #{dest}
            diff: false
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["--diff", "-c", "local", "-i", INVENTORY, playbook], output: output, error: output)

    status.success?.must_equal(true)
    output.to_s.must_include("changed: [localhost]")
    output.to_s.wont_include("--- before")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    File.delete(dest) if dest && File.exists?(dest)
  end
end
