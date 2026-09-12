require "file_utils"
require "../spec_helper"

# A looped include_tasks: whose FIRST iteration's included tasks fail the
# host must not let a LATER iteration's include file surface a second
# failure. Real Ansible registers every loop iteration's include before any
# included task executes (all the "included:" lines print first, then the
# included tasks run in order), so by the time a task failure halts the
# host, every include file has already been registered - a later file's
# content never produces an extra error. krikri executes each iteration
# lazily (load the file, run its tasks, next iteration), so loading a later
# iteration's file anyway meant a load-time failure in it (e.g.
# pluggero.upgrade's 03_reboot.yml referencing the unimplemented
# ansible.windows.win_reboot, round 601548) added a spurious second
# failed= entry: recap failed=2 where real ansible-core 2.19.4 recaps
# failed=1 with only the original task's error.
#
# Not covered live: this spec uses krikri's own unimplemented-module
# hard-stop as the load-time failure, which real Ansible has no equivalent
# for (it resolves win_reboot fine) - the recap numbers above were verified
# against real ansible-playbook with a fail:/command failure instead.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(files : Hash(String, String))
  dir = File.tempname("include-loop-halt")
  Dir.mkdir(dir)
  playbook = File.join(dir, "site.yml")
  files.each do |rel, content|
    path = File.join(dir, rel)
    File.dirname(path).tap { |parent| Dir.mkdir_p(parent) }
    File.write(path, content)
  end
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)
  {status, output.to_s}
ensure
  FileUtils.rm_rf(dir) if dir && File.exists?(dir)
end

describe "looped include_tasks stops loading later iterations after the host fails" do
  it "recaps failed=1 with only the original failure, no load error from later includes" do
    status, output = run_playbook({
      "tasks/02_second.yml" => <<-YAML,
        - name: Unimplemented module in later include
          ansible.windows.win_reboot:
            msg: "never"
        YAML
      "site.yml" => <<-YAML,
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: Loop includes
              ansible.builtin.include_tasks: "{{ item }}"
              with_items:
                - tasks/01_first.yml
                - tasks/02_second.yml
        YAML
      "tasks/01_first.yml" => <<-YAML,
        - name: Failing task in first include
          ansible.builtin.fail:
            msg: "first include fails"
        YAML
    })

    status.exit_code.should eq(2)
    output.should contain("first include fails")
    output.should_not contain("win_reboot")
    output.should_not contain("Failed to load included tasks")
    output.should contain("failed=1")
    output.should_not contain("failed=2")
    # Both loop iterations' include registrations still count ok, matching
    # real Ansible's upfront registration of every iteration.
    output.should contain("ok=2")
  end
end
