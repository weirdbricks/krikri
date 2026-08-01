require "../spec_helper"

# These specs drive the compiled `bin/crystal-ansible` binary against the
# example playbooks in testing/*.yml, in --check mode, using an inventory
# that defines no hosts. Fixtures targeting the "testservers" group therefore
# have their play skipped (no hosts match) rather than actually connecting
# anywhere; the "localhost" fixture runs for real, but every plugin it uses
# (shell/debug) refuses to act in check mode, so nothing on disk changes.
# This turns the manual fixtures into a regression net for free, without
# requiring SSH access or a target host.

private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory.ini")
private FIXTURES_DIR = File.join(PROJECT_ROOT, "testing")

Spec.before_suite do
  needs_build = !File.exists?(BINARY) || !Dir.exists?(File.join(PROJECT_ROOT, "bin", "plugins"))
  next unless needs_build

  status = Process.run("./build.sh", chdir: PROJECT_ROOT, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
  raise "build.sh failed while preparing integration specs" unless status.success?
end

private def run_playbook(fixture : String) : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(
    BINARY,
    ["--check", "-i", INVENTORY, File.join(FIXTURES_DIR, fixture)],
    output: output,
    error: output
  )
  {status, output.to_s}
end

describe "crystal-ansible CLI (--check mode)" do
  fixtures = Dir.glob(File.join(FIXTURES_DIR, "*.yml")).map { |path| File.basename(path) }
  fixtures.sort!

  fixtures.each do |fixture|
    it "runs #{fixture} to completion" do
      status, output = run_playbook(fixture)

      status.success?.should be_true
      output.should contain("PLAY RECAP")
      output.should contain("Playbook execution complete")
      output.should_not contain("Error parsing playbook")
      output.should_not contain("Error loading inventory")
    end
  end

  it "runs the localhost fixture in check mode without making changes" do
    status, output = run_playbook("test-debug-quick.yml")

    status.success?.should be_true
    output.should contain("Mode: CHECK (dry-run)")
    output.should contain("ok: [localhost]")
    output.should contain("does not support check mode")
    output.should contain("NOTE: Running in check mode - no changes were made")
  end

  it "iterates loop:, with_items:, with_dict:, with_nested:, with_sequence: and with_indexed_items:" do
    status, output = run_playbook("test-loop-quick.yml")

    status.success?.should be_true
    output.should contain("=> (item=a)")
    output.should contain("loop item: a")
    output.should contain("=> (item=b)")
    output.should contain("=> (item=c)")
    output.should contain("with_items item: x")
    output.should contain("with_items item: y")
    output.should contain("one=1")
    output.should contain("two=2")
    output.should contain(%(nested item: ["a","x"]))
    output.should contain(%(nested item: ["b","y"]))
    output.should contain("sequence item: 1")
    output.should contain("sequence item: 3")
    output.should contain(%(indexed item: ["0","x"]))
    output.should contain(%(indexed item: ["1","y"]))
  end

  it "skips plays whose hosts pattern matches nothing in the inventory" do
    status, output = run_playbook("test-command.yml")

    status.success?.should be_true
    output.should contain("Skipping play - no hosts match pattern: testservers")
  end

  it "exits non-zero and reports the error for an invalid playbook" do
    Dir.mkdir_p(File.join(PROJECT_ROOT, "spec", "tmp"))
    bad_playbook = File.join(PROJECT_ROOT, "spec", "tmp", "invalid.yml")
    File.write(bad_playbook, "not: a: valid: playbook: [")

    status, output = run_playbook(File.join("..", "spec", "tmp", "invalid.yml"))

    status.success?.should be_false
    output.should contain("Error parsing playbook")

    File.delete(bad_playbook)
  end
end
