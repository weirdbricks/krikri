require "../minitest_helper"
require "file_utils"

# Runs the compiled binary against a real playbook - the skip DISPLAY for
# a with_first_found: include_vars: happens on the executor's
# single-invocation include_vars path (execute_include_vars), whose
# when:-false/first_found interplay only shows end to end.
private PROJECT_ROOT = File.expand_path("../..", __DIR__)
private BINARY       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
private INVENTORY    = File.join(PROJECT_ROOT, "test", "fixtures", "inventory-explicit-localhost.ini")

describe "include_vars: with with_first_found: skipped by a false when:" do
  it "prints the resolved item's skipping line before the bare trailing skip, still counting skipped=1 per task" do
    # Real bug confirmed with a minimal repro against ansible-core
    # 2.19.11 (geerlingguy.certbot's own "Load a variable file" shape,
    # issue #256): `include_vars: "{{ item }}"` with `with_first_found:`
    # and `when: false` used to print ONLY the bare itemless
    # `skipping: [localhost]` line, because execute_include_vars checked
    # when: before resolve_first_found ever ran - the item was never
    # known when the skip printed. Real resolves the first_found loop
    # first (the per-item conditional verdict can only exist per resumed
    # loop item), so both the scalar candidate form and the
    # files:/paths: dict form display identically:
    #   skipping: [localhost] => (item=<found path>)
    #   skipping: [localhost]
    # with skipped=1 per task in the recap, exactly as the itemless skip
    # counted before.
    src_dir = PluginSpecHelper.tmp_path("first-found-when-false-skip")
    vars_dir = File.join(src_dir, "vars")
    Dir.mkdir_p(vars_dir)
    Dir.mkdir_p(src_dir) unless Dir.exists?(src_dir)
    File.write(File.join(vars_dir, "default.yml"), "certbot_first_found_marker: yes\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Load a variable file
            include_vars: "{{ item }}"
            with_first_found:
              - "#{File.join(vars_dir, "Nope.yml")}"
              - "#{File.join(vars_dir, "default.yml")}"
            when: false
          - name: Load a variable file via files
            include_vars: "{{ item }}"
            with_first_found:
              - files:
                  - "Nope.yml"
                  - "default.yml"
                paths:
                  - #{vars_dir}
            when: false
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    found = File.join(vars_dir, "default.yml")
    # Trailing space exactly as real's own `=> (item=...) ` suffix.
    output.to_s.must_include("skipping: [localhost] => (item=#{found}) \n")
    lines = output.to_s.lines
    # The bare trailing line lands once per task, AFTER its item-labelled
    # line - two tasks, two of each, skipped=2 total.
    lines.count(&.==("skipping: [localhost]")).must_equal(2)
    # Real's `=> (item=...) ` suffix keeps its trailing space (the -v dump
    # slot, empty here), so match through the rstrip'd line.
    lines.count(&.rstrip.ends_with?("=> (item=#{found})")).must_equal(2)
    output.to_s.must_include("skipped=2")
    output.to_s.wont_include("ok: [localhost]")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "falls back to the itemless single skip when the first_found source cannot resolve" do
    # Real defers ONLY AnsibleUndefinedVariable out of the loop source
    # (run()'s `items = None; self._loop_eval_error` bookkeeping): a
    # strict-undefined scalar candidate is that shape, so the plain
    # itemless when:-false skip still decides the task (the saved loop
    # error never raises for a clean False verdict) - the same precedence
    # resolve_loop_items_or_raise already encodes for general loop:
    # sources. Real-verified vs 2.19.11: in this shape, the skip is bare
    # `skipping: [localhost]` (rc=0), not a fatal.
    src_dir = PluginSpecHelper.tmp_path("first-found-when-false-fallback")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Load a variable file
            include_vars: "{{ item }}"
            with_first_found: "{{ definitely_undefined_var }}"
            when: false
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    output.to_s.must_include("skipping: [localhost]\n")
    output.to_s.wont_include("=> (item=")
    output.to_s.must_include("skipped=1")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "matches real's -v dump: the per-item cleaned skip result and the All items skipped trailing line" do
    # Both -v dumps verified against ansible-core 2.19.11 with the same -
    # minimal repro: the item line carries the full cleaned skip result
    # (ansible_loop_var + item appended, identical to every other looped
    # task's item skip), and the trailing bare line closes with real's
    # all-items-skipped aggregate dump.
    src_dir = PluginSpecHelper.tmp_path("first-found-when-false-verbose")
    vars_dir = File.join(src_dir, "vars")
    Dir.mkdir_p(vars_dir)
    Dir.mkdir_p(src_dir) unless Dir.exists?(src_dir)
    File.write(File.join(vars_dir, "default.yml"), "certbot_first_found_marker: yes\n")
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Load a variable file
            include_vars: "{{ item }}"
            with_first_found:
              - "#{File.join(vars_dir, "Nope.yml")}"
              - "#{File.join(vars_dir, "default.yml")}"
            when: false
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-v", "-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(true)
    found = File.join(vars_dir, "default.yml")
    output.to_s.must_include(%("ansible_loop_var": "item", "changed": false, "false_condition": false, "item": "#{found}", "skip_reason": "Conditional result was False"))
    output.to_s.must_include(%(skipping: [localhost] => {"changed": false, "msg": "All items skipped"}))
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end

  it "fails the task on a no-candidate list even under when: false (lookup runs before the conditional)" do
    # Real's run() resolves the with_first_found: lookup FIRST: only
    # AnsibleUndefinedVariable is deferred into the `items is None` path
    # where the when: still decides; the first_found plugin's own
    # exhaustion ("No file was found when using first_found.") is a
    # non-undefined lookup error that propagates straight to a fatal -
    # live-verified vs 2.19.11 with this exact playbook shape (issue
    # #256): when: false -> fatal, failed=1, rc=2.
    # The old when:-first order printed the plain skip instead.
    src_dir = PluginSpecHelper.tmp_path("first-found-when-false-no-match")
    Dir.mkdir_p(src_dir)
    playbook = File.join(src_dir, "pb.yml")
    File.write(playbook, <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Load a variable file
            include_vars: "{{ item }}"
            with_first_found:
              - "nonexistent_candidate_a.yml"
              - "nonexistent_candidate_b.yml"
            when: false
          - name: show
            debug:
              msg: done
      YAML

    output = IO::Memory.new
    status = Process.run(BINARY, ["-i", INVENTORY, playbook], output: output, error: output, chdir: src_dir)

    status.success?.must_equal(false)
    output.to_s.must_include("The lookup plugin 'first_found' failed: No file was found when using first_found.")
    # Not the when:-first order's skip, and the host halted before the
    # follow-up task ever ran.
    output.to_s.wont_include("skipping: [localhost]")
    output.to_s.wont_include("msg: done")
    output.to_s.must_include("skipped=0")
    output.to_s.must_include("failed=1")
  ensure
    FileUtils.rm_rf(src_dir) if src_dir
  end
end
