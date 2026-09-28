require "../minitest_helper"

# Facts produced in an earlier play of the same run must be visible in
# later plays BOTH directly and through hostvars - with no fact cache
# configured. Real ansible-core keeps set_fact/registered/gathered facts
# in the in-memory host state for the whole run (ansible-core 2.19.11,
# verified live), while this engine used to scope them to the producing
# play's own TaskExecutor: cross-play reads only survived via a fact
# cache plugin (ANSIBLE_CACHE_PLUGIN), so a CI/dev run without one got
# `hostvars[...] = undefined` for exactly the data real Ansible still
# had. Every example here clears the ANSIBLE_* fact-cache/gathering env
# explicitly and was live-verified against real ansible-playbook 2.19.11
# before being pinned.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-multi-local.ini")

# Runs the playbook with every ANSIBLE_* cache/gathering variable
# stripped from the environment, so the in-memory path is what's under
# test - not whatever fact cache the developer's own shell has set.
# env: MERGES with the parent environment (clear_env defaults to
# false), so removal is spelled as a nil value - deleting the key from
# the hash would silently leave the parent's ambient ANSIBLE_* value
# in place (that bit this file's first draft and cost a debugging
# round: the child still ran under smart gathering).
private CLEARED_KEYS = ["ANSIBLE_GATHERING", "ANSIBLE_CACHE_PLUGIN", "ANSIBLE_CACHE_PLUGIN_CONNECTION", "ANSIBLE_PIPELINING"]

private def run_playbook(yaml : String, *, with_cache : Bool = false) : {Process::Status, String}
  playbook = File.tempname("cross-play-hostvars", ".yml")
  File.write(playbook, yaml)
  env = {} of String => String?
  ENV.to_h.each { |key, value| env[key] = value }
  CLEARED_KEYS.each { |key| env[key] = nil }
  cache_dir = PluginSpecHelper.tmp_path("fact-cache")
  FileUtils.mkdir_p(cache_dir)
  if with_cache
    env["ANSIBLE_CACHE_PLUGIN"] = "jsonfile"
    env["ANSIBLE_CACHE_PLUGIN_CONNECTION"] = cache_dir
  end
  output = IO::Memory.new
  status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, env: env)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
end

describe "cross-play hostvars without a fact cache" do
  it "shows a play-1 set_fact to play 2, directly and via hostvars" do
    status, output = run_playbook(<<-YAML)
      - name: play one
        hosts: web1
        gather_facts: false
        tasks:
          - name: produce
            ansible.builtin.set_fact:
              myfact: hello
      - name: play two
        hosts: web1
        gather_facts: false
        tasks:
          - name: consume
            ansible.builtin.debug:
              msg: "direct={{ myfact | default('MISSING') }} hv={{ hostvars['web1'].myfact | default('MISSING') }}"
      YAML

    status.success?.must_equal(true, output)
    output.must_include("direct=hello hv=hello", output)
    output.wont_include("MISSING", output)
  end

  it "shows a play-1 set_fact from ANOTHER host via hostvars in play 2" do
    status, output = run_playbook(<<-YAML)
      - name: play one on web1
        hosts: web1
        gather_facts: false
        tasks:
          - name: produce
            ansible.builtin.set_fact:
              myfact: hello
      - name: play two on web2 only - the producer never executes again
        hosts: web2
        gather_facts: false
        tasks:
          - name: consume
            ansible.builtin.debug:
              msg: "hv={{ hostvars['web1'].myfact | default('MISSING') }}"
      YAML

    status.success?.must_equal(true, output)
    output.must_include("hv=hello", output)
    output.wont_include("MISSING", output)
  end

  it "shows a play-1 registered result to play 2, cross-host via hostvars" do
    status, output = run_playbook(<<-YAML)
      - name: play one on web1
        hosts: web1
        gather_facts: false
        tasks:
          - name: produce
            ansible.builtin.command: echo produced
            register: reg
      - name: play two on web2 only - the producer never executes again
        hosts: web2
        gather_facts: false
        tasks:
          - name: consume
            ansible.builtin.debug:
              msg: "hv={{ hostvars['web1'].reg.stdout | default('MISSING') }}"
      YAML

    status.success?.must_equal(true, output)
    output.must_include("hv=produced", output)
    output.wont_include("MISSING", output)
  end

  it "keeps gathered facts visible in a later gather_facts: false play" do
    status, output = run_playbook(<<-YAML)
      - name: play one gathers
        hosts: web1
        tasks:
          - name: keep the play non-empty
            ansible.builtin.command: /bin/true
      - name: play two reads them
        hosts: web1
        gather_facts: false
        tasks:
          - name: consume
            ansible.builtin.debug:
              msg: "family={{ ansible_os_family | default('MISSING') }} hvf={{ hostvars['web1'].ansible_os_family | default('MISSING') }}"
      YAML

    status.success?.must_equal(true, output)
    output.must_include("family=", output)
    output.wont_include("MISSING", output)
  end

  it "does not depend on ANSIBLE_CACHE_PLUGIN being set" do
    # Same playbook, same expected output, with a live jsonfile fact
    # cache configured: the in-memory host state, not the cache, is what
    # later plays read, so both runs must agree.
    yaml = <<-YAML
      - name: play one
        hosts: web1
        gather_facts: false
        tasks:
          - name: produce
            ansible.builtin.set_fact:
              myfact: hello
      - name: play two
        hosts: web2
        gather_facts: false
        tasks:
          - name: consume
            ansible.builtin.debug:
              msg: "hv={{ hostvars['web1'].myfact | default('MISSING') }}"
      YAML

    without_cache_status, without_cache_output = run_playbook(yaml)
    with_cache_status, with_cache_output = run_playbook(yaml, with_cache: true)

    without_cache_status.success?.must_equal(true, without_cache_output)
    with_cache_status.success?.must_equal(true, with_cache_output)
    without_cache_output.must_include("hv=hello", without_cache_output)
    with_cache_output.must_include("hv=hello", with_cache_output)
  end
end
