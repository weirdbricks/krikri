require "../spec_helper"
require "file_utils"

# These specs drive the compiled `bin/crystal-ansible` binary against the
# example playbooks in testing/*.yml, in --check mode, using an inventory
# that defines no hosts. Fixtures targeting the "testservers" group therefore
# have their play skipped (no hosts match) rather than actually connecting
# anywhere; the "localhost" fixture runs for real, but every plugin it uses
# (shell/debug) refuses to act in check mode, so nothing on disk changes.
# This turns the manual fixtures into a regression net for free, without
# requiring SSH access or a target host.

private PROJECT_ROOT                 = File.expand_path("../..", __DIR__)
private BINARY                       = File.join(PROJECT_ROOT, "bin", "crystal-ansible")
private INVENTORY                    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory.ini")
private EXPLICIT_LOCALHOST_INVENTORY = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-explicit-localhost.ini")
private TWO_LOCAL_HOSTS_INVENTORY    = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-two-local-hosts.ini")
private FIXTURES_DIR                 = File.join(PROJECT_ROOT, "testing")

Spec.before_suite do
  needs_build = !File.exists?(BINARY) || !Dir.exists?(File.join(PROJECT_ROOT, "bin", "plugins"))
  next unless needs_build

  status = Process.run("./build.sh", chdir: PROJECT_ROOT, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
  raise "build.sh failed while preparing integration specs" unless status.success?
end

private def run_playbook(
  fixture : String,
  mode_args : Array(String) = ["--check"],
  chdir : String? = nil,
  inventory : String = INVENTORY,
) : {Process::Status, String}
  output = IO::Memory.new
  status = Process.run(
    BINARY,
    mode_args + ["-i", inventory, File.join(FIXTURES_DIR, fixture)],
    output: output,
    error: output,
    chdir: chdir
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
    output.should contain("var loop item: red")
    output.should contain("var loop item: green")
    output.should contain("var loop item: blue")
    output.should contain("var dict: one=1")
    output.should contain("var dict: two=2")
    output.should contain("max_requests=500")
    output.should contain("idx=0 item=red")
    output.should contain("idx=1 item=green")
    output.should contain("idx=2 item=blue")
  end

  it "counts a looped task once in the recap (not once per item), matching Ansible" do
    # Real ansible-playbook aggregates a looped task into a single recap
    # line: a 3-item create loop reports ok=1 changed=1, never ok=3.
    # This guards the loop-aggregation parity fix in finish_looped_task.
    FileUtils.rm_rf("/tmp/crystal-play-loop-count")
    status, output = run_playbook("test-loop-counting.yml", [] of String)

    status.success?.should be_true
    output.should contain(%(localhost            : ok=1  changed=1  failed=0))
  end

  it "runs a role: meta dependency first, applies defaults/vars/invocation-var precedence, resolves src: relative to the role's files/ dir, fires role handlers, then runs the play's own tasks" do
    status, output = run_playbook("test-roles-quick.yml")

    status.success?.should be_true
    task_order = output.lines.select(&.starts_with?("TASK ["))
    base_index = task_order.index(&.includes?("base role task runs first"))
    default_index = task_order.index(&.includes?("show the default var"))
    base_index.should_not be_nil
    default_index.should_not be_nil
    base_index.as(Int32).should be < default_index.as(Int32)

    output.should contain("greeting target: crystal-ansible") # role invocation var overrides defaults/main.yml
    output.should contain("greeting style: friendly")         # from vars/main.yml
    output.should contain("Would copy")
    output.should contain("testing/roles/greeter/files/greeting.txt")
    output.should contain("announce greeting") # role handler fired (copy task reported changed)
    output.should contain("SUCCESS: play task ran after role tasks")
  end

  it "set_fact sets vars visible to later tasks (string/bool/int, when: gating, and overwrite)" do
    status, output = run_playbook("test-set-fact-quick.yml")

    status.success?.should be_true
    output.should contain("greeting is hello from set_fact")
    output.should contain("retry_count is 3")
    output.should contain("is_ready gated task ran")
    output.should contain("greeting is updated greeting")
  end

  it "runs the Gathering Facts task and exposes ansible_* facts when gather_facts: true" do
    status, output = run_playbook("test-gather-facts-true-quick.yml", [] of String)

    status.success?.should be_true
    output.should contain("TASK [Gathering Facts]")
    output.should_not contain("hostname is {{ ansible_hostname }}") # substitution actually happened
  end

  it "skips the Gathering Facts task entirely when gather_facts: false" do
    status, output = run_playbook("test-gather-facts-false-quick.yml", [] of String)

    status.success?.should be_true
    output.should_not contain("TASK [Gathering Facts]")
    output.should contain("no facts needed here")
  end

  it "runs include_tasks: once per loop item with item: in scope, and skips the whole include (not per nested task) when its own when: is false" do
    status, output = run_playbook("test-include-tasks-quick.yml")

    status.success?.should be_true
    output.should contain("dynamic task ran, item=a")
    output.should contain("dynamic task ran, item=b")
    output.should contain("dynamic task ran, item=c")
    output.scan("skipping: [localhost]").size.should eq(1) # one skip for the whole `when: false` include, not one per nested task
    output.should contain("include_tasks smoke test complete!")

    # Regression: the when:-false include_tasks: used to increment
    # recap "ok" unconditionally BEFORE checking its own when:, then
    # "skipped" again once the check failed - double-counted as both
    # ok=8 and skipped=1 instead of the correct ok=7 skipped=1 (3 loop
    # iterations x (include + nested task) = 6, plus the final debug = 7).
    output.should contain("ok=7")
    output.should contain("skipped=1")
  end

  it "batches a top-level include_tasks: across every host sharing the same resolved file, instead of running it one whole host at a time" do
    # Real bug found benchmarking a real 2-node geerlingguy.kubernetes
    # cluster bring-up (round 37, 0.9.383): every task reached through a
    # top-level include_tasks: used to run against host 1 to completion,
    # then host 2 to completion - fully serial, bypassing --forks
    # parallelism for everything inside (which is most of a typical
    # role: geerlingguy.containerd/geerlingguy.kubernetes both gate
    # their OS-family setup this way). Measured as a consistent ~1.8x
    # cold-run wall-time regression on a real 2-host cluster playbook.
    status, output = run_playbook(
      "test-multihost-include-tasks-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.should be_true
    output.should contain("included task ran on web1")
    output.should contain("included task ran on web2")
    # One shared "included: <path> for web1, web2" line - not two
    # separate single-host include resolutions.
    output.should contain("for web1, web2")
    output.should contain("multi-host include_tasks smoke test complete!")
  end

  it "batches a top-level block: across hosts too, still honoring per-host when: skips correctly" do
    status, output = run_playbook(
      "test-multihost-block-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.should be_true
    output.should contain("block task ran on web1")
    output.should_not contain("block task ran on web2")
    output.should contain("skipping: [web2]")
    output.should contain("multi-host block smoke test complete!")
  end

  it "forks a LOOPED top-level include_tasks: across hosts too, still threading each iteration's loop_var correctly per host" do
    # Round 37 (0.9.383) fixed the non-looped include_tasks: case above
    # but deliberately left a looped one (loop:/with_items: on the
    # include statement itself - rare, e.g. robertdebock.users' "Loop
    # over users_groups") on the original single-host path, since it
    # doesn't share execute_include_tasks_multi's per-file host grouping.
    # This exercises that looped case now being forkable via
    # task_forkable? too - each host still runs its own full loop
    # independently (not batched per-item across hosts like the
    # non-looped case), just concurrently with other hosts instead of
    # one host's whole loop finishing before the next host starts.
    status, output = run_playbook(
      "test-multihost-looped-include-tasks-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.should be_true
    output.should contain("included task ran on web1 for fruit apple")
    output.should contain("included task ran on web1 for fruit banana")
    output.should contain("included task ran on web2 for fruit apple")
    output.should contain("included task ran on web2 for fruit banana")
    output.should contain("multi-host looped include_tasks smoke test complete!")
  end

  it "keeps a nested loop's own item bound inside a looped include_tasks:, not the outer include's item" do
    # Real bug found benchmarking robertdebock.diskspace: execute_looped_
    # task's per-iteration re-application of task.vars (needed so a task-
    # level vars: block recomputes against each item) blindly re-applied
    # EVERY task.vars key, including "item"/loop_var - which
    # execute_include_tasks had already propagated from the OUTER
    # iteration into task.vars for a NON-looped included task's benefit.
    # For an included task that ALSO loops, this silently clobbered the
    # correct inner-loop item with the stale outer one on every single
    # inner iteration.
    status, output = run_playbook("test-nested-loop-in-include-quick.yml")

    status.success?.should be_true
    output.should contain("mount={\"name\":\"first\"} item=a")
    output.should contain("mount={\"name\":\"first\"} item=b")
    output.should contain("mount={\"name\":\"second\"} item=a")
    output.should contain("mount={\"name\":\"second\"} item=b")
    output.should contain("nested loop in include smoke test complete!")
  end

  it "runs include_role: once per loop item, applies invocation vars, and fires the role's handler exactly once even though the role (and its handler) were dynamically loaded twice" do
    status, output = run_playbook("test-include-role-quick.yml")

    status.success?.should be_true
    output.should contain("hello crystal-ansible, item=x")
    output.should contain("hello crystal-ansible, item=y")
    output.scan("HANDLER [dynamically included handler]").size.should eq(1)
    output.should contain("include_role smoke test complete!")
  end

  it "propagates ansible_parent_role_names through a role's own include_tasks: -> include_role: chain" do
    # Real bug found benchmarking prometheus.prometheus.node_exporter (a
    # real Ansible Collection): its own tasks/main.yml reaches a nested
    # include_role: (with tasks_from:) via an intermediate include_tasks:
    # call, not directly. ansible_parent_role_names previously only got
    # set on tasks loaded straight from RoleLoader - propagate_role_context
    # (which threads role context through include_tasks:) never carried
    # role_name/role_parent_names at all, so the nested include_role:
    # call had no enclosing-role context to extend, and the target role's
    # own "don't invoke me directly" guard assert failed regardless of
    # the real (indirect) invocation path.
    status, output = run_playbook("test-nested-role-parent-chain-quick.yml")

    status.success?.should be_true
    output.should contain("nested role chain complete! parent=outer_role")
    output.should contain("nested role parent-chain smoke test complete!")
  end

  it "continues the play past a failed task when ignore_errors: yes, and does not fail the process" do
    status, output = run_playbook("test-error-handling-quick.yml", [] of String)

    status.success?.should be_true
    output.should contain("ignore_errors let the play continue")
  end

  it "overrides changed/failed via changed_when:/failed_when:" do
    status, output = run_playbook("test-changed-when-quick.yml", [] of String)

    status.success?.should be_true
    lines = output.lines

    status_after = ->(task_line : String) {
      task_index = lines.index(&.includes?(task_line))
      task_index.should_not be_nil
      status_line = lines[(task_index.as(Int32) + 1)..].find { |line| line.starts_with?("ok:") || line.starts_with?("changed:") || line.starts_with?("failed:") }
      status_line.should_not be_nil
      status_line.as(String)
    }

    status_after.call("a command that would normally report changed, forced to ok").should start_with("ok:")
    status_after.call("a command whose changed status is derived from its own rc").should start_with("ok:")
    status_after.call("a command downgraded from failed to ok via failed_when").should start_with("changed:")

    output.should contain("failed_when: false let the play continue")
    output.should contain("changed_when / failed_when smoke test complete!")
    output.should_not contain("failed=1")
  end

  it "runs run_once: only on the first host but still exposes its register: to every host, and keeps delegate_to: vars attributed to the delegating host" do
    status, output = run_playbook(
      "test-delegate-run-once-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.should be_true
    # run_once: only actually executes (and is displayed/counted) for the
    # first host in the play.
    output.should contain("changed: [web1]")
    output.should_not contain("changed: [web2]")
    # but its registered result is still visible from both hosts.
    output.scan("once_result changed=True").size.should eq(2)
    # delegate_to: redirects the connection, not the variables - each
    # host's own inventory_hostname still shows through.
    output.should contain("inventory_hostname=web1")
    output.should contain("inventory_hostname=web2")
    output.should contain("delegate_to / run_once smoke test complete!")
  end

  it "re-resolves a templated delegate_to: per loop iteration instead of once before the loop binds item" do
    status, output = run_playbook(
      "test-delegate-loop-item-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.should be_true
    # run_once: true picks web1 as the sole executor; its delegated loop
    # (delegate_to: "{{ item }}") sets loop_delegate_marker="web1" onto
    # BOTH web1 and web2 via delegate_facts - if delegate_to resolved
    # against an unbound "item" (the bug), the task would have crashed
    # trying to SSH to a host literally named "undefined" instead of
    # ever reaching here.
    output.should contain("host=web1 marker=web1")
    output.should contain("host=web2 marker=web1")
    output.should_not contain("marker=undefined")
    output.should contain("delegate_to templated on loop item smoke test complete!")
  end

  describe "include_vars: / with_first_found:" do
    testservers = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-testservers-local.ini")

    it "loads a file chosen by with_first_found into a named dict, and merges without name:" do
      status, output = run_playbook(
        "test-include-vars-quick.yml", [] of String, inventory: testservers
      )

      status.success?.should be_true
      # `name:` stages the whole file under one variable...
      output.should contain("named=from-os-family-file")
      # ...while the bare form merges its keys into the context.
      output.should contain("merged=from-os-family-file")
    end

    it "keeps set_fact: winning over include_vars:" do
      status, output = run_playbook(
        "test-include-vars-quick.yml", [] of String, inventory: testservers
      )

      status.success?.should be_true
      # include_vars sits below set_fact in real Ansible's precedence
      # ladder, and @included_vars is applied before facts for that reason.
      output.should contain("precedence=from-set-fact")
    end

    it "skips rather than fails when no with_first_found candidate exists and skip: true" do
      status, output = run_playbook(
        "test-include-vars-quick.yml", [] of String, inventory: testservers
      )

      status.success?.should be_true
      output.should contain("skipping:")
      output.should_not contain("file not found")
    end

    it "resolves a with_first_found candidate that bakes vars/ into the filename against the role root" do
      # Real bug found benchmarking geerlingguy.mysql: a candidate like
      # "vars/Linux.yml" (the vars/ prefix baked into the filename itself,
      # rather than relying on a separate paths:) previously only ever
      # got joined against the role's vars/ dir directly - producing a
      # nonexistent doubled "vars/vars/Linux.yml" - so this always
      # silently resolved to zero candidates via skip: true.
      status, output = run_playbook(
        "test-include-vars-quick.yml", [] of String, inventory: testservers
      )

      status.success?.should be_true
      output.should contain("prefixed=from-os-family-file")
    end
  end

  describe "magic variables" do
    magicvars = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-ansible-host.ini")

    it "are visible to bare when:/assert:/changed_when:/failed_when: conditions" do
      status, output = run_playbook(
        "test-magic-vars-quick.yml", [] of String, inventory: magicvars
      )

      status.success?.should be_true
      # Each of these used to fail: a bare condition was evaluated
      # against vars_context, which never had the magic variables added -
      # only the {{ }} substitution path did. `when:` therefore skipped
      # silently, which is the worst shape for this bug.
      output.should contain("BARE-WHEN-RAN")
      output.should contain("CHANGED-WHEN=False")
      output.should contain("FAILED-WHEN-SURVIVED")
      output.should_not contain("failed=1")
    end

    it "does not overwrite an inventory ansible_host with the inventory name" do
      status, output = run_playbook(
        "test-magic-vars-quick.yml", [] of String, inventory: magicvars
      )

      status.success?.should be_true
      # ansible_host is the connection address, not the inventory name.
      # Overwriting it also mislead PluginManager#get_connection_host.
      # ansible-core 2.19.4 reports the inventory's value here.
      output.should contain("inv=web1 ahost=127.0.0.1")
    end

    it "prefers the gathered ansible_hostname fact over the inventory name" do
      status, output = run_playbook(
        "test-magic-vars-quick.yml", [] of String, inventory: magicvars
      )

      status.success?.should be_true
      # ansible_hostname is a fact - the target's own hostname, which is
      # usually not the inventory name. Only used as a fallback when no
      # facts were gathered.
      real_hostname = System.hostname
      output.should_not contain("ahostname=web1")
      # sanity: the fixture's inventory name and the real hostname differ,
      # otherwise this assertion proves nothing.
      real_hostname.should_not eq("web1")
    end
  end

  describe "--gathering" do
    testservers = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-testservers-local.ini")

    it "defaults to implicit: every play re-gathers facts" do
      status, output = run_playbook(
        "test-gathering-smart-quick.yml", [] of String, inventory: testservers
      )

      status.success?.should be_true
      output.scan("TASK [Gathering Facts]").size.should eq(3)
    end

    it "smart: gathers each host at most once per run" do
      status, output = run_playbook(
        "test-gathering-smart-quick.yml", ["--gathering", "smart"], inventory: testservers
      )

      status.success?.should be_true
      output.scan("TASK [Gathering Facts]").size.should eq(1)
    end

    it "smart: later plays still see the facts gathered by the first" do
      status, output = run_playbook(
        "test-gathering-smart-quick.yml", ["--gathering", "smart"], inventory: testservers
      )

      status.success?.should be_true
      # The whole point: skipping the round trip must not mean skipping
      # the facts. All three plays resolve ansible_kernel, none falls
      # back to the default('MISSING').
      output.should_not contain("MISSING")
      output.scan(/play\d kernel=/).size.should eq(3)
    end

    it "smart and implicit produce the same task results, differing only in gathering" do
      _, implicit_output = run_playbook(
        "test-gathering-smart-quick.yml", [] of String, inventory: testservers
      )
      _, smart_output = run_playbook(
        "test-gathering-smart-quick.yml", ["--gathering", "smart"], inventory: testservers
      )

      %w[play1 play2 play3].each do |play|
        implicit_line = implicit_output.lines.find(&.includes?("#{play} kernel="))
        smart_line = smart_output.lines.find(&.includes?("#{play} kernel="))
        smart_line.should eq(implicit_line)
      end
    end

    it "explicit: gathers only for plays that actually wrote gather_facts: true" do
      status, output = run_playbook(
        "test-gathering-smart-quick.yml", ["--gathering", "explicit"], inventory: testservers
      )

      status.success?.should be_true
      # Every play in that fixture writes `gather_facts: true`, so
      # explicit gathers for all three - the mode differs from implicit
      # only for plays that leave gather_facts unset.
      output.scan("TASK [Gathering Facts]").size.should eq(3)
    end

    it "explicit: does not gather for a play that leaves gather_facts unset" do
      status, output = run_playbook(
        "test-meta-clear-facts-quick.yml", ["--gathering", "explicit"], inventory: testservers
      )

      status.success?.should be_true
      # Plays 1 and 3 leave gather_facts unset; play 2 sets it to false.
      output.should_not contain("TASK [Gathering Facts]")
    end

    it "meta: clear_facts forces a re-gather in the next play under smart" do
      status, output = run_playbook(
        "test-meta-clear-facts-quick.yml", ["--gathering", "smart"], inventory: testservers
      )

      status.success?.should be_true
      # Without the clear_facts this would be 1; the clear in play 2 makes
      # play 3 gather again. Matches ansible-core 2.19.4 exactly.
      output.scan("TASK [Gathering Facts]").size.should eq(2)
      output.should_not contain("MISSING")
    end

    it "meta: produces no per-host output line and no recap credit" do
      status, output = run_playbook(
        "test-meta-clear-facts-quick.yml", ["--gathering", "smart"], inventory: testservers
      )

      status.success?.should be_true
      # ansible-core prints the TASK banner for a meta task but no `ok:`
      # beneath it, and excludes it from the recap total - 2 gathers plus
      # 2 debug tasks is 4, not 5.
      output.should contain("TASK [clear the gathered facts]")
      output.should match(/ok=4\b/)
    end

    it "meta: flush_handlers runs pending handlers immediately, not just at end-of-play" do
      # Real bug found benchmarking robertdebock's own roles (round 18):
      # `ansible.builtin.meta: flush_handlers` was rejected at parse time
      # entirely (a documented scope cut) - several real roles
      # (mysql, selinux, zabbix_repository, zabbix_server,
      # core_dependencies) use it deliberately mid-role so a later task
      # can rely on a handler's side effect (e.g. an apt cache refresh)
      # having already happened - skipping it silently deferred every
      # notified handler to the very end of the play instead, which for
      # zabbix_server caused a genuine functional divergence from real
      # ansible-playbook: a package install task failed "Unable to
      # locate package" because the repo-add handler's own cache refresh
      # hadn't run yet.
      status, output = run_playbook("test-meta-flush-handlers-quick.yml", [] of String)

      status.success?.should be_true
      task_order = output.lines.select { |line| line.starts_with?("TASK [") || line.starts_with?("HANDLER [") }
      handler_index = task_order.index(&.includes?("HANDLER [my flush handler]"))
      after_index = task_order.index(&.includes?("TASK [after the flush]"))
      handler_index.should_not be_nil
      after_index.should_not be_nil
      handler_index.as(Int32).should be < after_index.as(Int32)

      # The handler fired exactly once - the mid-play flush picked it up,
      # and the implicit end-of-play flush must not re-run it a second
      # time (real ansible-playbook's own flush_handlers semantics: only
      # handlers notified SINCE the last flush are pending).
      output.scan("HANDLER [my flush handler]").size.should eq(1)
    end

    it "reports an unsupported meta action instead of treating it as a no-op" do
      # A meta action this engine does not model is rejected at parse time
      # with a named error, rather than being accepted and silently doing
      # nothing - a `meta: end_play` that quietly did nothing would change
      # what the playbook means.
      #
      # It surfaces as a warning and the task is dropped, which is how the
      # parser handles *every* parse error (see PlaybookParser.parse_tasks'
      # rescue) - not as a non-zero exit. An earlier version of this spec
      # asserted a failing exit code and passed for the wrong reason: the
      # resulting task-less play then hit a crash in show_recap, which is
      # what actually produced the non-zero status. That crash is fixed,
      # so this now asserts the behavior that is really there.
      tmp = File.tempname("meta-unsupported", ".yml")
      File.write(tmp, <<-YAML)
        - name: unsupported meta
          hosts: testservers
          gather_facts: false
          tasks:
            - name: end the play early
              ansible.builtin.meta: end_play
        YAML
      begin
        captured = IO::Memory.new
        Process.run(BINARY, ["-i", testservers, tmp], output: captured, error: captured)
        captured.to_s.should contain("meta: end_play is not supported")
        # and the task genuinely did not run
        captured.to_s.should_not contain("end the play early")
      ensure
        File.delete(tmp) rescue nil
      end
    end

    it "rejects an unknown gathering mode" do
      status, output = run_playbook(
        "test-gathering-smart-quick.yml", ["--gathering", "bogus"], inventory: testservers
      )

      status.success?.should be_false
      output.should contain("--gathering must be 'implicit', 'explicit' or 'smart'")
    end
  end

  it "--forks 1 (one-host-at-a-time) is byte-identical to the --forks 5 default's parallel fan-out" do
    default_status, default_output = run_playbook(
      "test-forks-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-multi-local.ini")
    )
    forks1_status, forks1_output = run_playbook(
      "test-forks-quick.yml",
      ["--forks", "1"],
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-multi-local.ini")
    )

    default_status.success?.should be_true
    forks1_status.success?.should be_true
    forks1_output.should eq(default_output)
  end

  it "--forks N runs every host per task, still runs run_once: only on the first host, and keeps each host's output un-interleaved" do
    status, output = run_playbook(
      "test-forks-quick.yml",
      ["--forks", "5"],
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.should be_true
    # Every host actually ran the plain (non-run_once) task.
    output.should contain("changed: [web1]")
    output.should contain("changed: [web2]")
    # run_once: still only executes on the first host under --forks -
    # task_forkable? excludes it from the parallel fan-out entirely.
    output.scan("changed: [web1]").size.should eq(2) # the plain task + run_once
    output.scan("changed: [web2]").size.should eq(1) # the plain task only
    # ...but its registered result is still visible from both hosts.
    output.scan("once_result changed=True").size.should eq(2)
    output.scan("cmd_result changed=True").size.should eq(2)
    # Each host's own lines stay together, in host order, never
    # interleaved mid-task by the concurrent fan-out.
    output.should contain("changed: [web1]\nchanged: [web2]")
    output.should contain("forks smoke test complete!")
  end

  it "loads group_vars/all.yml, group_vars/<group>.yml, and host_vars/<host>.yml from beside the inventory file" do
    status, output = run_playbook(
      "test-group-host-vars-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "group_host_vars", "inventory.ini")
    )

    status.success?.should be_true
    output.should contain("datacenter=dc1 role=webserver app_version=1.2.3")
    output.should contain("group_vars / host_vars smoke test complete!")
  end

  it "runs async: tasks in the background, blocks for poll: > 0, and lets async_status: poll a poll: 0 job to completion" do
    status, output = run_playbook(
      "test-async-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-testservers-local.ini")
    )

    status.success?.should be_true
    # poll: > 0 blocks and returns the real (finished) module result.
    output.should contain("polled_result finished=1 changed=True")
    # poll: 0 returns immediately with a job id, not the real result yet.
    output.should match(/Job started: \S+/)
    # async_status: eventually sees the fire-and-forget job finish.
    output.should contain("job_result finished=1")
    output.should contain("async / poll / async_status smoke test complete!")
  end

  it "detects an executable inventory file as a dynamic inventory script and uses its --list JSON output" do
    status, output = run_playbook(
      "test-dynamic-inventory-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "dynamic_inventory", "inventory.sh")
    )

    status.success?.should be_true
    output.should contain("ok: [dynhost1]")
    output.should contain("connection=local")
    output.should contain("dynamic inventory smoke test complete!")
  end

  it "manages a Docker image/network/container end to end with correct idempotency (requires a real Docker/Podman daemon)" do
    status, output = run_playbook(
      "test-docker-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-testservers-local.ini")
    )

    status.success?.should be_true
    output.should contain("image_first=False image_idempotent=False")
    output.should contain("network_first=True network_idempotent=False")
    output.should contain("container_first=True container_idempotent=False")
    output.should contain("container_stopped=True container_removed=True")
    output.should contain("network_removed=True")
    output.should contain("docker plugins smoke test complete!")
  end

  it "manages a MySQL/MariaDB database and user (with privilege diffing) end to end (requires a real server at 127.0.0.1:13306)" do
    status, output = run_playbook(
      "test-mysql-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-testservers-local.ini")
    )

    status.success?.should be_true
    output.should contain("db_first=True db_idempotent=False")
    output.should contain("db_import=True db_dump=True db_import_gz=True")
    output.should contain("restored_count=2")
    output.should contain("db_dump_zst=True")
    output.should contain("db_import_zst=True")
    output.should contain("restored_count_zst=2")
    output.should contain("db_dump_knobs=True")
    output.should contain("db_import_knobs=True")
    output.should contain("knobs_tables=t,")
    output.should contain("user_first=True user_idempotent=False")
    output.should contain("user_priv_changed=True user_removed=True db_removed=True")
    output.should contain("mysql plugins smoke test complete!")
  end

  it "manages a PostgreSQL database and role (with attribute flag diffing) end to end (requires a real server at 127.0.0.1:15432)" do
    status, output = run_playbook(
      "test-postgresql-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-testservers-local.ini")
    )

    status.success?.should be_true
    output.should contain("db_first=True db_idempotent=False")
    output.should contain("db_restore=True db_dump=True db_restore_gz=True")
    output.should contain("restored_count=2")
    output.should contain("db_dump_pgc=True")
    output.should contain("db_restore_pgc=True")
    output.should contain("restored_count_pgc=2")
    output.should contain("user_first=True user_idempotent=False")
    output.should contain("user_flags_changed=True user_removed=True db_removed=True")
    output.should contain("postgresql plugins smoke test complete!")
  end

  it "wraps a task's plugin execution in sudo -n -u <user> when become: is set, and rejects an invalid become_user without shelling out" do
    status, output = run_playbook(
      "test-become-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-testservers-local.ini")
    )

    status.success?.should be_true
    output.should contain("bad_user_failed=True")

    # become_user: "{{ current_user.stdout }}" - sudo to the same user
    # already running this process, which every sudo/PAM default allows
    # without a password since it's not a real privilege change (the same
    # "don't require real root on whatever machine runs this" convention
    # spec/integration/user_spec.cr/group_spec.cr use). sudo always sets
    # SUDO_USER in the child's environment when it actually wraps a
    # command, so this only passes if become: really executed the plugin
    # through sudo - not a no-op that happened to not error.
    match = output.match(/current_user=(\S+) became_sudo_user=(\S+)/)
    match.should_not be_nil
    match.not_nil![1].should eq(match.not_nil![2])
    output.should contain("become smoke test complete!")

    # Real bug found benchmarking geerlingguy.solr's own "Ensure core
    # configuration directories exist." task (become_user: solr,
    # crystal-ansible installed under /root/...): execute_local_plugin
    # always ran the compiled plugin binary straight from wherever
    # crystal-ansible itself lives, which broke the moment that install
    # directory wasn't traversable by become_user (a root-owned
    # /root/... install is a common real-world case) - `sudo: Sorry,
    # user root is not allowed to execute '/root/.../plugins/command'
    # as solr`, really a plain EACCES on /root's own 0700 mode, not an
    # actual sudoers policy denial. A become: task must now stage a
    # world-traversable copy of the plugin binary at REMOTE_PLUGIN_DIR
    # before sudo-ing to it, exactly as this "become to the current
    # user" task (command:, become: true) already exercises above.
    staged_command_plugin = "/var/tmp/.crystal-play/plugins/command"
    File.exists?(staged_command_plugin).should be_true
    (File.info(staged_command_plugin).permissions.value & 0o777).should eq(0o755)
  end

  it "resolves hostvars['other_host'] to that OTHER host's own inventory vars, both bracket and dot syntax" do
    # Real bug found benchmarking a real geerlingguy.glusterfs 3-node
    # cluster: hostvars wasn't populated in the vars_context at all, so
    # `gluster peer probe {{ hostvars['node2'].ansible_host }}` ran as
    # `gluster peer probe undefined` - silently probing a bogus hostname
    # instead of the real peer's IP. hostvars is also real Ansible's
    # standard way to reference ANY inventory host's own vars from a
    # play that doesn't even target it, not just the current one - a
    # naive fix that only populated hostvars from the current play's
    # own @hosts (rather than the whole inventory) would still miss
    # this exact case, since only node1 runs the peer-probe play in the
    # real playbook that found this bug.
    hostvars_inventory = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-hostvars-local.ini")
    status, output = run_playbook(
      "test-hostvars-quick.yml",
      [] of String,
      inventory: hostvars_inventory
    )

    status.success?.should be_true
    output.should contain("h2_via_bracket=from_h2")
    output.should contain("h2_via_dot=from_h2")
    output.should contain("h1_via_hostvars=from_h1")
    output.should contain("hostvars smoke test complete!")
  end

  it "resolves groups['group_name'] to that group's member host names, incl. the synthesized 'all'" do
    # Real bug found benchmarking geerlingguy.kubernetes (round 35):
    # `groups` was entirely unpopulated in the vars_context, so ANY
    # `groups[...]` access resolved "undefined" - the role's own "Set
    # the kubeadm join command globally." task (`loop: "{{ groups['all']
    # }}", delegate_to: "{{ item }}"`) turned into a single-item loop
    # whose one item was the literal string "undefined", and the
    # templated delegate_to then tried to SSH to a host literally named
    # "undefined" instead of broadcasting to every real inventory host.
    status, output = run_playbook(
      "test-groups-quick.yml",
      [] of String,
      inventory: File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-multi-local.ini")
    )

    status.success?.should be_true
    output.should contain("multilocal_members=[\"web1\",\"web2\"]")
    output.should contain("all_members=[\"web1\",\"web2\"]")
    output.should contain("groups smoke test complete!")
  end

  it "recovers a failed block: via rescue:, always runs always:, and the play continues" do
    status, output = run_playbook("test-error-handling-quick.yml", [] of String)

    status.success?.should be_true
    output.should contain("block was rescued")
    output.should contain("always runs whether the block failed or not")
    output.should contain("play continues past a rescued block")
    output.should contain("error handling smoke test complete!")
    output.should_not contain("SHOULD NOT APPEAR")
    # A successfully-rescued failure shouldn't count against the play.
    output.should contain("rescued=1")
    output.should_not contain("failed=1")
  end

  it "halts the rest of the play when a block: fails with no rescue:, but always: still runs, and the process exits non-zero" do
    status, output = run_playbook("test-error-handling-unrescued.yml", [] of String)

    status.success?.should be_false
    output.should contain("always runs regardless")
    output.should_not contain("SHOULD NOT APPEAR")
    output.should contain("failed=1")
  end

  it "finds its plugins when invoked from a directory other than its own checkout" do
    # Regression test: PluginManager used to resolve plugins via the
    # cwd-relative path "./bin/plugins/<name>", which only worked if you
    # first `cd`'d into the crystal-ansible checkout - unlike real
    # ansible-playbook, which can be run from anywhere. Running with an
    # unrelated chdir (using absolute paths for everything else) is exactly
    # the scenario that broke.
    Dir.mkdir_p(File.join(PROJECT_ROOT, "spec", "tmp"))

    status, output = run_playbook("test-debug-quick.yml", ["--check"], chdir: File.join(PROJECT_ROOT, "spec", "tmp"))

    status.success?.should be_true
    output.should_not contain("Plugin binary not found")
    output.should contain("PLAY RECAP")
  end

  it "runs a plugin against a host with no explicit ansible_user= (regression: Host.from_json crashed on a JSON-null user)" do
    # spec/fixtures/inventory.ini is empty, so "localhost" always takes the
    # separate "implicit localhost" path in InventoryParser#get_hosts,
    # which unconditionally defaults a non-nil user - it never exercises a
    # Host whose user is genuinely nil. An explicitly-declared
    # `localhost ansible_connection=local` (no ansible_user=) does, and is
    # a completely ordinary, common inventory line in the real world.
    status, output = run_playbook("test-debug-quick.yml", [] of String, inventory: EXPLICIT_LOCALHOST_INVENTORY)

    status.success?.should be_true
    output.should_not contain("Cast from Nil to String failed")
    output.should_not contain("Failed to parse plugin output")
  end

  it "skips plays whose hosts pattern matches nothing in the inventory" do
    status, output = run_playbook("test-command.yml")

    status.success?.should be_true
    output.should contain("Skipping play - no hosts match pattern: testservers")
  end

  it "--limit restricts a hosts: all play to just the named host, not every matching host" do
    # Regression: --limit's value was parsed into a variable that was
    # never actually read anywhere else - crystal-ansible ran hosts: all
    # against the WHOLE inventory regardless of --limit, silently
    # ignoring the flag entirely.
    status, output = run_playbook(
      "test-limit-hosts.yml",
      ["--limit", "hosttwo"],
      inventory: TWO_LOCAL_HOSTS_INVENTORY
    )

    status.success?.should be_true
    output.should contain("ran on hosttwo")
    output.should_not contain("ran on hostone")
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
