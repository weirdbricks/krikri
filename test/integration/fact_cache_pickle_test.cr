require "file_utils"
require "../minitest_helper"
require "../../src/krikri/fact_cache_pickle"

# Runs the compiled binary against real playbooks: the
# `community.general.pickle` fact cache (issue #1838) is persisted
# cross-PROCESS state, so it can't be observed from a single in-process
# unit spec. The codec itself (including an ansible-core 2.21.6-written
# fixture and a python3 cross-check) is covered by
# test/unit/fact_cache_pickle_test.cr.
private PICKLE_PROJECT_ROOT = File.expand_path("../..", __DIR__)
private PICKLE_BINARY       = File.join(PICKLE_PROJECT_ROOT, "bin", "krikri-playbook")
private PICKLE_INVENTORY    = File.join(PICKLE_PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_pickle_cache(playbook : String, extra_args : Array(String), cache_dir : String, prefix : String? = nil) : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(
    PICKLE_BINARY,
    ["-i", PICKLE_INVENTORY] + extra_args + [playbook],
    output: output,
    error: output,
    env: {
      "ANSIBLE_CACHE_PLUGIN"            => "community.general.pickle",
      "ANSIBLE_CACHE_PLUGIN_CONNECTION" => cache_dir,
      "ANSIBLE_CACHE_PLUGIN_PREFIX"     => prefix,
      "ANSIBLE_CACHE_PLUGIN_TIMEOUT"    => nil,
      "ANSIBLE_GATHERING"               => nil,
    }
  )
  {status, output.to_s}
end

private def gathering_playbook(dir : String, name : String) : String
  path = File.join(dir, name)
  File.write(path, <<-YAML)
    - hosts: localhost
      connection: local
      tasks:
        - name: trigger
          ansible.builtin.debug:
            msg: hi
    YAML
  path
end

private def idle_playbook(dir : String, name : String) : String
  path = File.join(dir, name)
  File.write(path, <<-YAML)
    - hosts: localhost
      connection: local
      gather_facts: false
      tasks:
        - name: show a cached fact
          ansible.builtin.debug:
            msg: "os is {{ ansible_facts.system }}"
    YAML
  path
end

describe "ANSIBLE_CACHE_PLUGIN=community.general.pickle fact caching" do
  it "writes a protocol-2 pickle file named after the host" do
    work = PluginSpecHelper.tmp_path("fact-cache-pickle-write")
    FileUtils.mkdir_p(work)
    cache_dir = File.join(work, "cache")
    playbook = gathering_playbook(work, "gather.yml")

    status, output = run_pickle_cache(playbook, [] of String, cache_dir)
    status.success?.must_equal(true)
    output.must_include("TASK [Gathering Facts]")

    files = Dir.children(cache_dir)
    files.must_equal(["localhost"])
    bytes = File.read(File.join(cache_dir, "localhost")).to_slice
    # PROTO 2 then the dict opcode - not the jsonfile backend's text.
    bytes[0].must_equal(0x80_u8)
    bytes[1].must_equal(2_u8)
    bytes[2].must_equal(0x7d_u8)
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "skips re-gathering on a warm rerun under --gathering smart" do
    work = PluginSpecHelper.tmp_path("fact-cache-pickle-smart")
    FileUtils.mkdir_p(work)
    cache_dir = File.join(work, "cache")
    playbook = gathering_playbook(work, "gather.yml")

    status1, output1 = run_pickle_cache(playbook, ["--gathering", "smart"], cache_dir)
    status1.success?.must_equal(true)
    output1.must_include("TASK [Gathering Facts]")

    status2, output2 = run_pickle_cache(playbook, ["--gathering", "smart"], cache_dir)
    status2.success?.must_equal(true)
    output2.wont_include("TASK [Gathering Facts]")
    output2.must_include("ok=1")
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "makes cached facts available to a play that sets gather_facts: false" do
    work = PluginSpecHelper.tmp_path("fact-cache-pickle-usable")
    FileUtils.mkdir_p(work)
    cache_dir = File.join(work, "cache")
    gathering = gathering_playbook(work, "gather.yml")
    idle = idle_playbook(work, "idle.yml")

    status1, _ = run_pickle_cache(gathering, [] of String, cache_dir)
    status1.success?.must_equal(true)

    status2, output2 = run_pickle_cache(idle, [] of String, cache_dir)
    status2.success?.must_equal(true)
    output2.must_match(/os is \S+/)
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "reads a cache entry ansible wrote with a cacheable set_fact (data-tagged value)" do
    work = PluginSpecHelper.tmp_path("fact-cache-pickle-tagged")
    FileUtils.mkdir_p(work)
    cache_dir = File.join(work, "cache")
    FileUtils.mkdir_p(cache_dir)
    # A real ansible-core 2.21.6 entry: a gathered fact set merged with a
    # `set_fact: ... cacheable: true` of a templated string, which ansible
    # stores as _AnsibleTaggedStr (GLOBAL/NEWOBJ/BUILD in the pickle).
    FileUtils.cp(File.join(PICKLE_PROJECT_ROOT, "test", "fixtures", "fact_cache",
      "ansible-2.21.6-tagged-set-fact.pickle"), File.join(cache_dir, "localhost"))
    playbook = File.join(work, "tagged.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        tasks:
          - name: read the warm entry
            ansible.builtin.debug:
              msg: "tagged={{ fixture_tagged_value }} sys={{ ansible_system }}"
      YAML

    status, output = run_pickle_cache(playbook, ["--gathering", "smart"], cache_dir)
    status.success?.must_equal(true)
    output.must_include("tagged=from-template sys=Linux")
    # The entry carries _ansible_facts_gathered, so smart gathering skips.
    output.wont_include("TASK [Gathering Facts]")
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "gathers over a warm entry without the gather marker, like ansible's smart" do
    work = PluginSpecHelper.tmp_path("fact-cache-pickle-nomarker")
    FileUtils.mkdir_p(work)
    cache_dir = File.join(work, "cache")
    FileUtils.mkdir_p(cache_dir)
    # A host with plenty of facts but no `_ansible_facts_gathered`: ansible's
    # _facts_gathered_for_host returns False and smart gathers anyway.
    File.write(File.join(cache_dir, "localhost"), Krikri::FactCache::Pickle.encode({
      "ansible_system"       => JSON::Any.new("Linux"),
      "ansible_distribution" => JSON::Any.new("Cached"),
    }))
    playbook = gathering_playbook(work, "gather.yml")

    status, output = run_pickle_cache(playbook, ["--gathering", "smart"], cache_dir)
    status.success?.must_equal(true)
    output.must_include("TASK [Gathering Facts]")
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "honors ANSIBLE_CACHE_PLUGIN_PREFIX in the cache file name" do
    work = PluginSpecHelper.tmp_path("fact-cache-pickle-prefix")
    FileUtils.mkdir_p(work)
    cache_dir = File.join(work, "cache")
    playbook = gathering_playbook(work, "gather.yml")

    status, _ = run_pickle_cache(playbook, [] of String, cache_dir, prefix: "pfx-")
    status.success?.must_equal(true)
    Dir.children(cache_dir).must_equal(["pfx-localhost"])

    # A warm rerun must find the prefixed entry too, not re-gather.
    status2, output2 = run_pickle_cache(playbook, ["--gathering", "smart"], cache_dir, prefix: "pfx-")
    status2.success?.must_equal(true)
    output2.wont_include("TASK [Gathering Facts]")
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "treats a cache file it cannot parse as a miss instead of failing the run" do
    work = PluginSpecHelper.tmp_path("fact-cache-pickle-corrupt")
    FileUtils.mkdir_p(work)
    cache_dir = File.join(work, "cache")
    FileUtils.mkdir_p(cache_dir)
    # A jsonfile-shaped entry left behind by switching backends: ansible's
    # own pickle plugin would raise on it; krikri must re-gather.
    File.write(File.join(cache_dir, "localhost"), %({"ansible_system": "Linux"}))
    playbook = gathering_playbook(work, "gather.yml")

    status, output = run_pickle_cache(playbook, ["--gathering", "smart"], cache_dir)
    status.success?.must_equal(true)
    output.must_include("TASK [Gathering Facts]")
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "persists the gather marker ansible's smart gathering needs, without exposing it top-level" do
    work = PluginSpecHelper.tmp_path("fact-cache-pickle-marker")
    FileUtils.mkdir_p(work)
    cache_dir = File.join(work, "cache")
    playbook = File.join(work, "marker.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        tasks:
          - name: inspect the marker
            ansible.builtin.debug:
              msg: "top={{ _ansible_facts_gathered | default('UNSET') }} nested={{ ansible_facts['_ansible_facts_gathered'] | default('UNSET') }} hv={{ hostvars[inventory_hostname]['_ansible_facts_gathered'] | default('UNSET') }}"
      YAML

    status, output = run_pickle_cache(playbook, [] of String, cache_dir)
    status.success?.must_equal(true)
    # ansible-core 2.21.6: nested in the ansible_facts dict, stripped from
    # the top-level fact vars and from a hostvars entry's top level
    # (clean_facts -> strip_internal_keys).
    output.must_include("top=UNSET nested=True hv=UNSET")

    facts = Krikri::FactCache::Pickle.decode(File.read(File.join(cache_dir, "localhost")).to_slice)
    facts["_ansible_facts_gathered"].as_bool.must_equal(true)
  ensure
    FileUtils.rm_rf(work) if work
  end

  it "drops the persisted entry on meta: clear_facts" do
    work = PluginSpecHelper.tmp_path("fact-cache-pickle-clear")
    FileUtils.mkdir_p(work)
    cache_dir = File.join(work, "cache")
    gathering = gathering_playbook(work, "gather.yml")
    clearing = File.join(work, "clear.yml")
    File.write(clearing, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: clear
            ansible.builtin.meta: clear_facts
      YAML

    status1, _ = run_pickle_cache(gathering, [] of String, cache_dir)
    status1.success?.must_equal(true)
    Dir.children(cache_dir).wont_be_empty

    status2, _ = run_pickle_cache(clearing, [] of String, cache_dir)
    status2.success?.must_equal(true)
    Dir.children(cache_dir).must_be_empty
  ensure
    FileUtils.rm_rf(work) if work
  end
end
