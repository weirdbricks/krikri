require "file_utils"
require "../spec_helper"

# Runs the compiled binary, since the magic-var binding happens in the
# executor's vars context and --diff is a CLI flag, neither reachable
# from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

# Found benchmarking linux-system-roles.firewall (round 970345): its
# "Show diffs" task guards with `when: ansible_check_mode or
# ansible_diff_mode or ...`, which hard-failed ("'ansible_diff_mode' is
# undefined") where real ansible-playbook just skips - ansible_check_mode
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

    status.success?.should be_true
    output.to_s.should_not contain("'ansible_diff_mode' is undefined")
    output.to_s.should_not contain("DIFF_SHOULD_NOT_SHOW")
    output.to_s.should match(/skipped=1\b/)
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

    status.success?.should be_true
    output.to_s.should contain("DIFF_SHOULD_SHOW")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
