require "file_utils"
require "../minitest_helper"

# Runs the compiled binary against real playbooks (this is about
# persisted, cross-PROCESS fact caching - ANSIBLE_CACHE_PLUGIN=jsonfile
# + ANSIBLE_CACHE_PLUGIN_CONNECTION - which by definition can't be
# observed from a single in-process unit spec). See KNOWN_MISSING.md's
# (now-fixed) "No fact-caching support" entry and FactCache's own
# comment: the cache is read into every play's vars and written after
# every gather regardless of gathering mode (as Ansible's VariableManager
# and gather_facts action plugin do), while SKIPPING the gather itself is
# gated on --gathering smart - verified live against ansible-core 2.21.6,
# where default `implicit` gathering re-gathers over a warm cache.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run(playbook : String, extra_args : Array(String), cache_dir : String, prefix : String? = nil) : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(
    BINARY,
    ["-i", INVENTORY] + extra_args + [playbook],
    output: output,
    error: output,
    env: {
      "ANSIBLE_CACHE_PLUGIN"            => "jsonfile",
      "ANSIBLE_CACHE_PLUGIN_CONNECTION" => cache_dir,
      "ANSIBLE_CACHE_PLUGIN_PREFIX"     => prefix,
      "ANSIBLE_GATHERING"               => nil,
    }
  )
  {status, output.to_s}
end

describe "ANSIBLE_CACHE_PLUGIN=jsonfile fact caching" do
  it "honors ANSIBLE_CACHE_PLUGIN_PREFIX like ansible's jsonfile plugin" do
    cache_dir = File.tempname("fact-cache-prefix")
    playbook = File.tempname("fact-cache-prefix", ".yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        tasks:
          - ansible.builtin.debug:
              msg: hi
      YAML

    status, _ = run(playbook, [] of String, cache_dir, prefix: "pfx-")
    status.success?.must_equal(true)
    Dir.children(cache_dir).must_equal(["pfx-localhost"])

    # The prefixed entry is the one a warm rerun reads.
    status2, output2 = run(playbook, ["--gathering", "smart"], cache_dir, prefix: "pfx-")
    status2.success?.must_equal(true)
    output2.wont_include("TASK [Gathering Facts]")
  ensure
    FileUtils.rm_rf(cache_dir) if cache_dir
    File.delete(playbook) if playbook && File.exists?(playbook)
  end

  it "still gathers under the default implicit gathering (matches Ansible: cache alone never skips gathering)" do
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
    status1.success?.must_equal(true)
    output1.must_include("TASK [Gathering Facts]")
    # Ansible's gather_facts action plugin persists every gather into a
    # configured cache, implicit gathering included (2.21.6), so a later
    # run - of either gathering mode - starts warm.
    Dir.children(cache_dir).wont_be_empty

    status2, output2 = run(playbook, [] of String, cache_dir)
    status2.success?.must_equal(true)
    output2.must_include("TASK [Gathering Facts]")
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
    status1.success?.must_equal(true)
    output1.must_include("TASK [Gathering Facts]")
    Dir.children(cache_dir).wont_be_empty

    status2, output2 = run(playbook, ["--gathering", "smart"], cache_dir)
    status2.success?.must_equal(true)
    output2.wont_include("TASK [Gathering Facts]")
    output2.must_include("ok=1")
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
    status1.success?.must_equal(true)

    status2, output2 = run(playbook, ["--gathering", "smart"], cache_dir)
    status2.success?.must_equal(true)
    output2.must_include("os is Linux")
  ensure
    File.delete(playbook) if playbook && File.exists?(playbook)
    FileUtils.rm_rf(cache_dir) if cache_dir
  end

  it "makes cached facts available to a play that sets gather_facts: false" do
    cache_dir = File.tempname("fact-cache")
    gathering_playbook = File.tempname("fact-cache-gathers", ".yml")
    idle_playbook = File.tempname("fact-cache-idle", ".yml")
    File.write(gathering_playbook, <<-YAML)
      - hosts: localhost
        connection: local
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
      YAML
    # Ansible's VariableManager merges the fact cache into every host's
    # vars on every play, so a play that skips gathering still reads the
    # facts an earlier run cached (live-verified vs 2.21.6).
    File.write(idle_playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: show a cached fact
            ansible.builtin.debug:
              msg: "os is {{ ansible_facts.system }}"
      YAML

    status1, _ = run(gathering_playbook, [] of String, cache_dir)
    status1.success?.must_equal(true)
    Dir.children(cache_dir).wont_be_empty

    status2, output2 = run(idle_playbook, [] of String, cache_dir)
    status2.success?.must_equal(true)
    output2.wont_include("TASK [Gathering Facts]")
    output2.must_include("os is Linux")
  ensure
    File.delete(gathering_playbook) if gathering_playbook && File.exists?(gathering_playbook)
    File.delete(idle_playbook) if idle_playbook && File.exists?(idle_playbook)
    FileUtils.rm_rf(cache_dir) if cache_dir
  end

  it "drops the persisted entry on meta: clear_facts, so a later play cannot resurrect it" do
    cache_dir = File.tempname("fact-cache")
    gathering_playbook = File.tempname("fact-cache-gathers", ".yml")
    clearing_playbook = File.tempname("fact-cache-clears", ".yml")
    File.write(gathering_playbook, <<-YAML)
      - hosts: localhost
        connection: local
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
      YAML
    File.write(clearing_playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: clear
            ansible.builtin.meta: clear_facts
      YAML

    status1, _ = run(gathering_playbook, [] of String, cache_dir)
    status1.success?.must_equal(true)
    Dir.children(cache_dir).wont_be_empty

    status2, _ = run(clearing_playbook, [] of String, cache_dir)
    status2.success?.must_equal(true)
    Dir.children(cache_dir).must_be_empty
  ensure
    File.delete(gathering_playbook) if gathering_playbook && File.exists?(gathering_playbook)
    File.delete(clearing_playbook) if clearing_playbook && File.exists?(clearing_playbook)
    FileUtils.rm_rf(cache_dir) if cache_dir
  end

  it "drops a warm cache under --flush-cache instead of seeding from it" do
    cache_dir = File.tempname("fact-cache")
    gathering_playbook = File.tempname("fact-cache-gathers", ".yml")
    idle_playbook = File.tempname("fact-cache-idle", ".yml")
    File.write(gathering_playbook, <<-YAML)
      - hosts: localhost
        connection: local
        tasks:
          - name: trigger
            ansible.builtin.debug:
              msg: hi
      YAML
    File.write(idle_playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: show a cached fact
            ansible.builtin.debug:
              msg: "os is {{ ansible_facts.system }}"
      YAML

    status1, _ = run(gathering_playbook, [] of String, cache_dir)
    status1.success?.must_equal(true)
    Dir.children(cache_dir).wont_be_empty

    # Real's --flush-cache deletes every host's cache entry before the
    # run, so this play must see no facts at all and fail on the
    # undefined one rather than reading the warm cache.
    status2, _ = run(idle_playbook, ["--flush-cache"], cache_dir)
    status2.success?.must_equal(false)
    Dir.children(cache_dir).must_be_empty
  ensure
    File.delete(gathering_playbook) if gathering_playbook && File.exists?(gathering_playbook)
    File.delete(idle_playbook) if idle_playbook && File.exists?(idle_playbook)
    FileUtils.rm_rf(cache_dir) if cache_dir
  end
end
