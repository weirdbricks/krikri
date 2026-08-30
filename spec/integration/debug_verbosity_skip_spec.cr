require "../spec_helper"

# Runs the compiled binary against a real playbook.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

describe "debug: verbosity: gate" do
  it "shows as a real skipping: task, counted under skipped=, not ok=, when run verbosity is below the gate" do
    # Real bug found benchmarking evrardjp.keepalived (round 158):
    # debug.cr's own execute already correctly detected the verbosity
    # gate and returned `skipped: true` in its PluginResult - but
    # PluginResult has no real `skipped` FIELD, so that `skipped: true`
    # kwarg just landed in its generic `@extra` bag and got serialized
    # as an ordinary top-level JSON key that nothing downstream ever
    # checked. Since changed/failed both stayed false, it fell straight
    # into the normal "ok" display/stats path: `finish_single_task`
    # printed "ok: [host]" followed by the plugin's own literal msg
    # text ("skipped") as if it were real debug output, and counted it
    # under `ok=`, never `skipped=` - a real, user-visible recap
    # divergence from real ansible-playbook (which correctly prints
    # "skipping: [host]" and counts it under skipped=).
    playbook = File.tempname("debug-verbosity", ".yml")
    File.write(playbook, <<-YAML)
      - name: repro
        hosts: localhost
        gather_facts: false
        tasks:
          - name: verbosity gated debug
            ansible.builtin.debug:
              msg: "should not print at default verbosity"
              verbosity: 2
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output)

    status.success?.should be_true
    output.to_s.should contain("skipping:")
    output.to_s.should contain("skipped=1")
    output.to_s.should_not contain("ok=1")
    output.to_s.should_not contain("should not print at default verbosity")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
  end
end
