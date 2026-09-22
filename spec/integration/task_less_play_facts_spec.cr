require "file_utils"
require "../spec_helper"

# Runs the compiled binary against a real playbook, since this bug is
# about krikri-playbook.cr's own top-level play loop, not reachable
# from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a play with an empty tasks: list" do
  it "still gathers facts and recaps ok=1 when gather_facts: is left at its default" do
    # Real bug found benchmarking arubanetworks.aoscx_role/aos_wlan_role
    # (round833/834, both entirely task-less placeholder roles): real
    # ansible-playbook always runs "Gathering Facts" as a synthetic step
    # independent of the play's own task list (unless gather_facts:
    # false) - this engine's "Skipping play - no tasks defined" early
    # exit used to fire unconditionally on an empty task list, skipping
    # fact gathering entirely too and recapping ok=0. Real ansible-core
    # 2.19.11 recaps ok=1 for a task-less play (verified live,
    # cache-free) - the implicit facts task counts like any task; the
    # once-committed ok=0 expectation came from measuring real Ansible
    # with a warm fact cache still active, which makes it silently skip
    # Gathering Facts on a rerun.
    playbook = File.tempname("task-less-play", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        tasks: []
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("TASK [Gathering Facts]")
    output.to_s.should contain("ok=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "still skips the whole play when gather_facts: false is set explicitly" do
    playbook = File.tempname("task-less-play-no-facts", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks: []
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("Skipping play - no tasks defined")
    output.to_s.should_not contain("TASK [Gathering Facts]")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
