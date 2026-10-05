require "../minitest_helper"
require "file_utils"

# groupby's result shape and its variable-storage warning. Jinja2
# 3.x do_groupby yields _GroupTuple namedtuples: json.dumps (debug:) shows
# each group as a [grouper, list] ARRAY, item.0/item.1 indexing works, and
# .grouper/.list attribute access works (namedtuple fields). Real
# ansible-core 2.19.11 also warns "Type 'GroupTuple' is unsupported in
# variable storage, converting to 'list'." whenever the pairs land in
# storage (task-arg finalization, set_fact) - but NOT when a | map(...)
# converted them all away. Byte-compared via scripts/output_parity.sh.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

# The classic suite pre-created a shared spec/tmp in before_suite; the
# minitest suite gives every test its own tmp_path subtree instead.
private def tmp_path(name : String) : String
  PluginSpecHelper.tmp_path(name)
end

describe "groupby pair shape and GroupTuple storage warning" do
  it "renders [grouper, list] pairs, keeps .grouper access, warns on storage only" do
    # The playbook lives in this test's OWN scratch subtree, never in the
    # process-wide /tmp: krikri resolves playbook-adjacent paths (group_vars/,
    # host_vars/, roles/, filter_plugins/, library/) from the playbook's
    # directory, so a playbook parked directly in /tmp picks up whatever
    # /tmp/group_vars, /tmp/filter_plugins or /tmp/library happens to exist -
    # from another spec running at the same time, from another worktree, or
    # from an earlier run's leftovers. tmp_path() is per-test, and the
    # run_one hook in minitest_helper.cr removes the subtree afterwards.
    playbook = tmp_path("groupby-pairs.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        gather_facts: false
        vars:
          items:
            - {color: "red", n: 1}
            - {color: "blue", n: 2}
            - {color: "red", n: 3}
        tasks:
          - debug: msg="{{ items | groupby('color') | map('first') | list }}"
          - debug: msg="{{ items | groupby('color') }}"
            ignore_errors: true
      YAML

    # stdout and stderr into SEPARATE buffers: the warning goes to stderr
    # (like Ansible's Display) and the play to stdout, and both arrive through
    # two independent pipes drained by two fibers. Merging them into one
    # IO::Memory lets a stderr chunk land between two stdout chunks, which
    # makes "this substring came from stdout" a property of the schedule
    # instead of of the output. Asserting each stream on its own buffer
    # also pins the real split (warning on stderr, nothing extra on stdout).
    stdout = IO::Memory.new
    stderr = IO::Memory.new
    Process.run(BINARY, ["-i", INVENTORY, playbook],
      output: stdout, error: stderr, chdir: File.dirname(playbook))
    out = stdout.to_s
    warnings = stderr.to_s

    # map('first') extracts the groupers (converted pairs: no warning)
    out.must_include("msg\": [\n        \"blue\",\n        \"red\"\n    ]")
    # the bare groupby result renders as an array of [grouper, list] pairs
    out.must_include("[\n        [\n            \"blue\",")
    # and warns exactly once, at the second debug's msg param
    warnings.scan("Type 'GroupTuple' is unsupported in variable storage").size.must_equal(1)
    warnings.must_include("Origin: #{playbook}:10:14")
  end
end
