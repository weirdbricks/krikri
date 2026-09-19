require "file_utils"
require "../spec_helper"

# Runs the compiled binary against a real playbook, since this bug is
# about krikri-playbook.cr's own top-level play loop, not reachable
# from a unit spec.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "a play with an empty tasks: list" do
  it "still gathers facts but recaps ok=0 when gather_facts: is left at its default" do
    # Real bug found benchmarking arubanetworks.aoscx_role/aos_wlan_role
    # (round833/834, both entirely task-less placeholder roles): real
    # ansible-playbook always runs "Gathering Facts" as a synthetic step
    # independent of the play's own task list (unless gather_facts:
    # false) - this engine's "Skipping play - no tasks defined" early
    # exit used to fire unconditionally on an empty task list, skipping
    # fact gathering entirely too and recapping ok=0. The recap
    # expectation itself used to be ok=1 (facts counted), but a
    # successful implicit Gathering Facts task contributes NOTHING to
    # real ansible-core 2.19's recap - instrumented live against
    # 2.19.11 (AggregateStats.increment never fires for it; a task-less
    # play recaps no host line at all), while an explicit setup: task
    # in the task list counts normally.
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
    output.to_s.should contain("ok=0")
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
