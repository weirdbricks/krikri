require "../minitest_helper"
require "file_utils"

# KRIKRI_PLAYBOOK_DEADLINE_SECONDS bounds ONE playbook's wall clock, set by
# scripts/minitest.sh only (issue #1189): a spec's playbook that never exits
# froze its whole shard, because Process.run waits for the child AND for
# every holder of the captured pipes, while nothing in the engine bounds a
# local plugin or a grandchild that inherited them.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "playbook wall-clock deadline (KRIKRI_PLAYBOOK_DEADLINE_SECONDS)" do
  it "kills a playbook that outlives it, reporting the task and the child tree, and exits 124" do
    dir = PluginSpecHelper.tmp_path("playbook-deadline")
    FileUtils.mkdir_p(dir)
    playbook = File.join(dir, "hang.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: hang
            ansible.builtin.command: sleep 60
      YAML

    output = IO::Memory.new
    started = Time.instant
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output,
      env: {"KRIKRI_PLAYBOOK_DEADLINE_SECONDS" => "1"})
    elapsed = (Time.instant - started).total_seconds

    status.exit_code.must_equal(124)
    expect(elapsed < 30.0).must_equal(true)
    text = output.to_s
    # The killed play's own output is what the spec fails with, so the
    # diagnostic has to name the task that was in flight and the tree.
    text.must_include("TASK [hang]")
    text.must_include("still running after 1s")
    text.must_include("sleep 60")
  end

  it "runs normally when the variable is set but empty (the runner may hand one through)" do
    dir = PluginSpecHelper.tmp_path("playbook-deadline-empty")
    FileUtils.mkdir_p(dir)
    playbook = File.join(dir, "fast.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: fast
            ansible.builtin.debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output,
      env: {"KRIKRI_PLAYBOOK_DEADLINE_SECONDS" => ""})

    status.success?.must_equal(true, output.to_s[-400..]? || output.to_s)
  end

  it "leaves a playbook that finishes inside the deadline alone" do
    dir = PluginSpecHelper.tmp_path("playbook-deadline-fast")
    FileUtils.mkdir_p(dir)
    playbook = File.join(dir, "fast.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        connection: local
        tasks:
          - name: fast
            ansible.builtin.debug:
              msg: hi
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output,
      env: {"KRIKRI_PLAYBOOK_DEADLINE_SECONDS" => "60"})

    status.success?.must_equal(true, output.to_s[-400..]? || output.to_s)
    output.to_s.wont_include("still running after")
  end
end
