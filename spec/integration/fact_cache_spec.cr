require "file_utils"
require "../spec_helper"

# Runs the compiled binary against real playbooks (this is about
# persisted, cross-PROCESS fact caching - ANSIBLE_CACHE_PLUGIN=jsonfile
# + ANSIBLE_CACHE_PLUGIN_CONNECTION - which by definition can't be
# observed from a single in-process unit spec). See KNOWN_MISSING.md's
# (now-fixed) "No fact-caching support" entry and FactCache's own
# comment for why this is gated on --gathering smart specifically -
# verified live against ansible-core 2.19.12: real Ansible's own
# default `implicit` gathering re-gathers even with a warm fact-cache
# configured; only `smart` consults it.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")

private def run(playbook : String, extra_args : Array(String), cache_dir : String) : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(
    BINARY,
    ["-i", INVENTORY] + extra_args + [playbook],
    output: output,
    error: output,
    env: {
      "ANSIBLE_CACHE_PLUGIN"            => "jsonfile",
      "ANSIBLE_CACHE_PLUGIN_CONNECTION" => cache_dir,
      "ANSIBLE_GATHERING"               => nil,
    }
  )
  {status, output.to_s}
end

describe "ANSIBLE_CACHE_PLUGIN=jsonfile fact caching" do
  it "is ignored under the default implicit gathering (matches real Ansible: cache alone never skips gathering)" do
    cache_dir = File.tempname("fact-cache")
    playbook = File.tempname("fact-cache-implicit", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
      YAML

    status1, output1 = run(playbook, [] of String, cache_dir)
    status1.success?.should be_true
    output1.should contain("TASK [Gathering Facts]")

    status2, output2 = run(playbook, [] of String, cache_dir)
    status2.success?.should be_true
    output2.should contain("TASK [Gathering Facts]")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    FileUtils.rm_rf(cache_dir) if cache_dir
  end

  it "skips re-gathering on a warm rerun under --gathering smart" do
    cache_dir = File.tempname("fact-cache")
    playbook = File.tempname("fact-cache-smart", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
      YAML

    status1, output1 = run(playbook, ["--gathering", "smart"], cache_dir)
    status1.success?.should be_true
    output1.should contain("TASK [Gathering Facts]")
    Dir.children(cache_dir).should_not be_empty

    status2, output2 = run(playbook, ["--gathering", "smart"], cache_dir)
    status2.success?.should be_true
    output2.should_not contain("TASK [Gathering Facts]")
    output2.should contain("ok=1")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    FileUtils.rm_rf(cache_dir) if cache_dir
  end

  it "populated vars from the cached facts are usable by a task (not just skipped bookkeeping)" do
    cache_dir = File.tempname("fact-cache")
    playbook = File.tempname("fact-cache-usable", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        tasks:
          - name: show a fact
            ansible.builtin.debug:
              msg: "os is {{ ansible_system }}"
      YAML

    status1, _ = run(playbook, ["--gathering", "smart"], cache_dir)
    status1.success?.should be_true

    status2, output2 = run(playbook, ["--gathering", "smart"], cache_dir)
    status2.success?.should be_true
    output2.should contain("os is Linux")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    FileUtils.rm_rf(cache_dir) if cache_dir
  end
end
