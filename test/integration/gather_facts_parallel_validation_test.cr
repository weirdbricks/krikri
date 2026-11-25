require "../minitest_helper"
require "file_utils"

# ansible-core 2.19.11's gather_facts ACTION plugin (live-verified in this
# repo's output-parity sweep, issue #760):
#
# - the action pops `parallel` off the task args -
#   `task_vars.pop('ansible_facts_parallel', self._task.args.pop('parallel',
#   None))`, so the var wins over the task arg when both exist - and runs the
#   survivor through convert_bool.boolean() with its strict=True default
#   BEFORE any fact module runs. A value outside Ansible's BOOLEANS set fails
#   the whole task with "The value '<x>' is not a valid boolean. Valid
#   booleans include: ..." (a plain TypeError: the fatal msg carries the
#   "Task failed: " brief prefix, the [ERROR] block is the single collapsed
#   segment - the same shape set_fact's strict `cacheable:` conversion
#   produces).
# - an explicit YAML null (`parallel:`) hits the action's `parallel is None`
#   branch and takes the module-count default WITHOUT converting, so it does
#   NOT fail - boolean(None) errors, but the pop already returned None.
# - the float 1.0/0.0 are in Ansible's BOOLEANS set (a quoted "1.0" string is
#   not - but a whole-span `{{ }}` demoted literal keeps its native float).
# - `parallel` is popped before the module hand-off, so a direct `setup:`
#   task never goes through this path at all: its `parallel:` arg reaches the
#   setup module's own argspec and fails there with Unsupported parameters.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

private def run_playbook(yaml : String, args : Array(String) = [] of String,
                         env : Hash(String, String)? = nil)
  playbook = File.tempname("gather-facts-parallel", ".yml")
  File.write(playbook, yaml)
  # A truthy `parallel:` leaves the gather's async job file in
  # ~/.ansible_async, which must never be the developer's real one - point
  # the child at a per-run directory instead.
  async_dir = File.join(Dir.tempdir, "krikri-gather-parallel-async-#{Random::Secure.hex(4)}")
  output = IO::Memory.new
  child_env = {"ANSIBLE_ASYNC_DIR" => async_dir}.merge(env || {} of String => String)
  status = Process.run(BINARY, ["-i", INVENTORY, *args, playbook],
    output: output, error: output, env: child_env)
  {status, output.to_s}
ensure
  File.delete(playbook) if playbook && File.exists?(playbook)
  FileUtils.rm_rf(async_dir) if async_dir
end

describe "gather_facts parallel matches Ansible 2.19.11 strict boolean conversion" do
  it "fails a non-boolean parallel string with Ansible's strict message" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gf bad
            gather_facts:
              parallel: gedqpg
            register: r
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("[ERROR]: Task failed: The value 'gedqpg' is not a valid boolean. Valid booleans include: " +
                        "'off', 1, 'true', 'y', 0, 'false', 'on', 'no', '1', 'yes', '0', 'n', 'f', 't'")
    output.must_include("fatal: [localhost]: FAILED! => {\"changed\": false, \"msg\": \"Task failed: The value 'gedqpg' is not a valid boolean.")
    output.must_include("...ignoring")
    output.must_include("ignored=1")
    # the collapsed shape: no second segment for this failure class
    output.wont_include("<<< caused by >>>")
  end

  it "fails a non-0/1 native int parallel and accepts the float 1.0 like real" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gf int
            gather_facts:
              parallel: 5
            register: r1
            ignore_errors: true
          - name: gf float
            gather_facts:
              parallel: 1.0
            register: r2
          - name: results
            debug:
              msg: "{{ r1.failed | default(false) }} {{ r2.ansible_facts.gather_subset | default('none') }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("The value '5' is not a valid boolean.")
    output.must_include("msg\": \"True ['all']")
  end

  it "takes the module-count default on an explicit null parallel without failing" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gf null
            gather_facts:
              parallel:
            register: r
      YAML

    status.success?.must_equal(true)
    output.wont_include("not a valid boolean")
    output.must_include("ok=1")
  end

  it "lets the ansible_facts_parallel var win over a bad task arg, and fails a bad var" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gf var wins
            vars:
              ansible_facts_parallel: true
            gather_facts:
              parallel: gedqpg
            register: r1
          - name: gf bad var
            vars:
              ansible_facts_parallel: bogusvar
            gather_facts:
            register: r2
            ignore_errors: true
          - name: results
            debug:
              msg: "{{ r1.failed | default(false) }} {{ r2.failed | default(false) }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("The value 'bogusvar' is not a valid boolean.")
    output.must_include("msg\": \"False True")
  end

  it "still leaves a direct setup task's parallel arg to the setup argspec" do
    status, output = run_playbook(<<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: setup parallel
            setup:
              parallel: gedqpg
            register: r
            ignore_errors: true
      YAML

    status.success?.must_equal(true)
    output.must_include("Unsupported parameters for (setup) module: parallel.")
    output.wont_include("is not a valid boolean")
  end

  # Regression for issues #1809 and #1808: real ansible's gather_facts
  # ACTION runs the fact module under async_wrapper when `parallel:` is
  # truthy, and under --check too the wrapper's finished job file
  # (~/.ansible_async/<jid>.<pid>, 0644, the whole facts payload) is left
  # behind - the kpg check-mode oracle's entire diff. krikri must leave the
  # same artifact; the random name and per-host payload are what
  # KNOWN_MISSING records, not something either engine can match.
  it "leaves the parallel gather's async job file, even under --check" do
    async_dir = PluginSpecHelper.tmp_path("async-dir")
    Dir.mkdir_p(async_dir)

    status, output = run_playbook(<<-YAML, ["--check"], {"ANSIBLE_ASYNC_DIR" => async_dir})
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: gf parallel
            gather_facts:
              parallel: true
            register: r
          - name: facts shape
            debug:
              msg: "{{ r.ansible_facts.gather_subset }} {{ r.ansible_facts.module_setup }}"
      YAML

    status.success?.must_equal(true)
    output.must_include("msg\": \"['all'] True")
    output.must_include("ok=2")
    jobs = Dir.children(async_dir)
    jobs.size.must_equal(1, "one fact module, one job file - check mode does not suppress async_wrapper")
    path = File.join(async_dir, jobs.first)
    # async_wrapper's own name: the action's "j<digits>" jid plus the pid
    # of the process it forked.
    jobs.first.must_match(/\Aj\d+\.\d+\z/)
    (File.info(path).permissions.value & 0o777).must_equal(0o644)
    # The module's own result - the action's failed/changed backfill and
    # the discovery stamp are controller-side.
    File.read(path).must_include("\"gather_subset\"")
  end
end
