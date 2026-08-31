require "../spec_helper"
require "file_utils"

# These specs drive the compiled `bin/krikri-playbook` binary against the
# example playbooks in testing/*.yml, in --check mode, using an inventory
# that defines no hosts. Fixtures targeting the "testservers" group therefore
# have their play skipped (no hosts match) rather than actually connecting
# anywhere; the "localhost" fixture runs for real, but every plugin it uses
# (shell/debug) refuses to act in check mode, so nothing on disk changes.
# This turns the manual fixtures into a regression net for free, without
# requiring SSH access or a target host.

private PROJECT_ROOT                 = File.expand_path("../..", __DIR__)
private BINARY                       = File.join(PROJECT_ROOT, "bin", "krikri-playbook")
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

private def write_notify_playbook(name : String, body : String) : String
  Dir.mkdir_p(File.join(PROJECT_ROOT, "spec", "tmp"))
  path = File.join(PROJECT_ROOT, "spec", "tmp", name)
  File.write(path, body)
  path
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

describe "krikri-playbook CLI (--check mode)" do
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
    # shell.cr's check-mode skip now sets skipped: true (matching real
    # Ansible's own recap - `skipped=1`, verified against ansible-core
    # 2.19.4's own `--check` output for this exact fixture) and populates
    # the full normal result shape (cmd/rc/stdout/stdout_lines/stderr/
    # stderr_lines/start/end/delta), so it displays as a genuine
    # "skipping:" line rather than a disguised "ok:" with the message
    # text inline - see VarSubstitutor::UndefinedVariableError's own
    # comment for why the result-shape fix mattered once module-arg
    # templating became strict (`test_result.stdout` must resolve to a
    # real empty string, not a missing key).
    output.should contain("skipping: [localhost]")
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
    output.should contain(%(nested item: ['a', 'x']))
    output.should contain(%(nested item: ['b', 'y']))
    output.should contain("sequence item: 1")
    output.should contain("sequence item: 3")
    output.should contain(%(indexed item: ['0', 'x']))
    output.should contain(%(indexed item: ['1', 'y']))
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
    FileUtils.rm_rf("/tmp/krikri-playbook-loop-count")
    status, output = run_playbook("test-loop-counting.yml", [] of String)

    status.success?.should be_true
    output.should contain(%(localhost            : ok=1  changed=1  unreachable=0  failed=0))
  end

  it "always prints all 7 PLAY RECAP counters, even when 0, matching real ansible-playbook" do
    # Real ansible-playbook's recap always prints ok=/changed=/
    # unreachable=/failed=/skipped=/rescued=/ignored= in that exact
    # order, never conditionally omitting a 0-valued counter - verified
    # directly against a real ansible-playbook run. This used to omit
    # skipped=/rescued=/ignored= whenever they were 0, and never printed
    # unreachable= at all - a purely cosmetic recap-line divergence from
    # real Ansible found repeatedly across benchmark rounds.
    status, output = run_playbook("test-loop-counting.yml", [] of String)

    status.success?.should be_true
    output.should contain(%(unreachable=0  failed=0  skipped=0  rescued=0  ignored=0))
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

    output.should contain("greeting target: krikri-playbook") # role invocation var overrides defaults/main.yml
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
    output.should contain(%(mount={'name': 'first'} item=a))
    output.should contain(%(mount={'name': 'first'} item=b))
    output.should contain(%(mount={'name': 'second'} item=a))
    output.should contain(%(mount={'name': 'second'} item=b))
    output.should contain("nested loop in include smoke test complete!")
  end

  it "runs include_role: once per loop item, applies invocation vars, and fires the role's handler exactly once even though the role (and its handler) were dynamically loaded twice" do
    status, output = run_playbook("test-include-role-quick.yml")

    status.success?.should be_true
    output.should contain("hello krikri-playbook, item=x")
    output.should contain("hello krikri-playbook, item=y")
    output.scan("HANDLER [dynamically included handler]").size.should eq(1)
    output.should contain("include_role smoke test complete!")
  end

  it "counts a non-looped include_role: task itself as one `ok` in the PLAY RECAP, matching real Ansible" do
    # Real bug found benchmarking andrewrothstein.terraform (round 154
    # v3): execute_include_tasks's run_include_tasks_once already
    # credited a non-looped include_tasks: with its own `ok`, but the
    # equivalent fix was never mirrored onto include_role:'s
    # run_include_role_once - every include_role: call silently
    # undercounted the recap's ok= tally by 1, verified against real
    # ansible-playbook (both give ok=5 changed=1 for this fixture: the
    # include_role: itself, its 2 tasks, the SUCCESS task, and the
    # notified handler).
    status, output = run_playbook("test-include-role-okcount-quick.yml")

    status.success?.should be_true
    output.should contain("ok=5  changed=1")
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

    it "fails (not skips) when no with_first_found candidate exists and skip: true is NOT given" do
      # Real bug found benchmarking robertdebock.release on Rocky 9.6:
      # real Ansible's first_found lookup plugin defaults `skip:` to
      # false - with no candidate found it raises and the include_vars:
      # task FAILS, it does not silently skip. Only explicit `skip: true`
      # (already covered by the specs above) tolerates a miss.
      status, output = run_playbook(
        "test-include-vars-noskip-fail.yml", [] of String, inventory: testservers
      )

      status.success?.should be_false
      output.should contain("The lookup plugin 'first_found' failed")
    end

    it "resolves query('first_found', ...) as a real include_vars: loop source, with a custom loop_var and a tasks/-relative paths: entry" do
      # Real bug found benchmarking buluma.confluence (round 165) -
      # three independent gaps in one common modern idiom:
      #  1. query(...) (real Ansible's lookup(..., wantlist=True)
      #     shorthand) was entirely unrecognized as a function call.
      #  2. parse_include_vars_task (a dedicated parser, not the
      #     general task-parsing path) never called #find_loop_template
      #     at all, so a TEMPLATED loop: (as opposed to a literal list
      #     or with_first_found:) left task.loop_template nil.
      #  3. The same dedicated parser never read loop_control: either,
      #     so a custom loop_var (`_loop_var` here) never got bound -
      #     Also: a `paths: ['../vars']` entry resolves against the
      #     including task file's own directory (tasks/), not just
      #     role_path itself.
      status, output = run_playbook(
        "test-query-first-found-loop.yml", [] of String, inventory: testservers
      )

      status.success?.should be_true
      output.should contain("confluence_marker=found-via-query")
    end

    it "resolves with_first_found: as an include_vars: loop source, with a custom loop_var" do
      # Real bug found benchmarking 13 different arillso.* roles
      # (docker, motd, ntp, openvpn, sshd, sudoers, ...), all sharing
      # this exact idiom: with_first_found: (the dedicated keyword, not
      # lookup()/query()) combined with loop_control: { loop_var:
      # loop_vars }. Unlike the loop:/query() path above (fixed for
      # buluma.confluence, round165), the DEDICATED with_first_found:
      # branch in TaskExecutor#execute_include_vars is a separate code
      # path that only ever bound the found candidate to the literal
      # name "item", ignoring loop_control entirely - `include_vars:
      # "{{ loop_vars }}"` always resolved to the literal text
      # "undefined" regardless of which candidate file actually
      # matched, failing "include_vars: file not found: undefined" on
      # every single one of these roles.
      status, output = run_playbook(
        "test-with-first-found-custom-loop-var.yml", [] of String, inventory: testservers
      )

      status.success?.should be_true
      output.should contain("arillso_marker=found-via-with-first-found")
    end
  end

  describe "strict-undefined module-arg templating" do
    testservers = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-testservers-local.ini")

    it "fails (not silently continues) when a bare module-arg reference is genuinely undefined" do
      # Real bug found benchmarking robertdebock.bios_update on Rocky 9.6
      # (round 161): real Ansible's module-arg templating is
      # strict-undefined by default - a debug: msg: inside a rescue:
      # block referencing a variable that's genuinely never set anywhere
      # fails the task ("Finalization of task args ... failed") rather
      # than silently rendering the literal text "undefined" and
      # continuing. Verified live against ansible-core 2.19.4: both
      # engines now fail at the same task with the same message.
      status, output = run_playbook(
        "test-strict-undefined-module-arg.yml", [] of String, inventory: testservers
      )

      status.success?.should be_false
      output.should contain("'some_var_never_set' is undefined")
    end
  end

  describe "template:/copy: src: with the subdir prefix already baked in" do
    testservers = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-testservers-local.ini")

    it "resolves src: against the role ROOT, not role_templates_dir again, when src: already bakes in the subdir prefix" do
      # Real bug found benchmarking buluma.confluence (round 165):
      # `src: "./templates/nested/dir/file.j2"` (the "templates/" subdir
      # prefix already baked into src: itself - real Ansible resolves
      # this against the role ROOT) previously always joined against
      # role_templates_dir directly, doubling the subdir
      # (".../templates/templates/nested/...", never existing) - "Template
      # file not found on controller" for every role using this idiom.
      status, output = run_playbook(
        "test-template-src-baked-in-prefix.yml", [] of String, inventory: testservers
      )

      status.success?.should be_true
      output.should_not contain("Template file not found")
      File.read("/tmp/template_src_prefix_test_output.txt").should contain("value=baked-in-prefix-works")
    ensure
      File.delete("/tmp/template_src_prefix_test_output.txt") if File.exists?("/tmp/template_src_prefix_test_output.txt")
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

    it "meta: end_host stops only the current host, not others" do
      # Real Ansible's own doc: "per-host variation of end_play... causes
      # the play to end for the current host without failing it." Was
      # rejected at parse time entirely before this - see git log.
      # Verified live against real ansible-playbook for both assertions
      # below (a 2nd host whose own when: skips this exact task keeps
      # running afterward; the ended host's own pending notified handler
      # is suppressed, matching a real failure's handler-skip behavior
      # exactly even though this is NOT a failure).
      status, output = run_playbook(
        "test-meta-end-host-quick.yml", [] of String, inventory: TWO_LOCAL_HOSTS_INVENTORY
      )

      status.success?.should be_true
      output.should contain("ran for hosttwo")
      output.should_not contain("ran for hostone")
      output.should_not contain("HANDLER [my end_host handler]")
    end

    it "meta: end_play stops every currently-active host, not just the one that triggers it" do
      # Real Ansible's own doc: "causes the play to end without failing
      # the host(s). Note that this affects all hosts." Verified live
      # against real ansible-playbook: genuinely global - hosttwo's own
      # when: skips this exact task entirely (never itself executes it)
      # but still gets blocked from the task after it, the moment
      # hostone's when: makes IT execute end_play.
      status, output = run_playbook(
        "test-meta-end-play-quick.yml", [] of String, inventory: TWO_LOCAL_HOSTS_INVENTORY
      )

      status.success?.should be_true
      output.should_not contain("should never print")
    end

    it "meta: clear_host_errors excludes a failed host from the rest of this play but not the next one" do
      # Real Ansible's own doc: "clears the failed state... available
      # for targeting in subsequent plays, but not continue execution in
      # the current play." Verified live against real ansible-playbook,
      # including the non-obvious part: clearing is global (acts on
      # every failed host in the play), not scoped to whichever host(s)
      # happen to still be active enough to individually execute this
      # meta task - the failed host itself is ALREADY excluded from this
      # task too, so scoping to the executing host alone would make the
      # feature unusable.
      status, output = run_playbook(
        "test-meta-clear-host-errors-quick.yml", [] of String, inventory: TWO_LOCAL_HOSTS_INVENTORY
      )

      status.success?.should be_true
      # Same play: only hosttwo (never failed) reaches the task after
      # clear_host_errors - hostone stays excluded from the REST of this
      # play despite its error being cleared.
      output.should contain("same play ran for hosttwo")
      output.should_not contain("same play ran for hostone")
      # Next play: both hosts are back, including hostone.
      output.should contain("next play ran for hostone")
      output.should contain("next play ran for hosttwo")
    end

    it "meta: noop does nothing and execution continues normally" do
      status, output = run_playbook("test-meta-noop-quick.yml", [] of String)

      status.success?.should be_true
      output.should contain("reached after noop")
    end

    it "reports an unsupported meta action instead of treating it as a no-op" do
      # A meta action this engine does not model is rejected at parse time
      # with a named error, rather than being accepted and silently doing
      # nothing - a `meta: reset_connection` that quietly did nothing
      # would change what the playbook means. (end_play/end_host/
      # clear_host_errors/noop/refresh_inventory are all real, supported
      # actions now - see PlaybookParser::SUPPORTED_META_ACTIONS and
      # TaskExecutor#execute_meta, each verified against real
      # ansible-playbook; reset_connection - persistent-connection
      # control - remains a documented scope cut.)
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
            - name: reset the connection
              ansible.builtin.meta: reset_connection
        YAML
      begin
        captured = IO::Memory.new
        Process.run(BINARY, ["-i", testservers, tmp], output: captured, error: captured)
        captured.to_s.should contain("meta: reset_connection is not supported")
        # and the task genuinely did not run
        captured.to_s.should_not contain("reset the connection")
      ensure
        File.delete(tmp) rescue nil
      end
    end

    it "meta: refresh_inventory re-reads a dynamic inventory script without adding hosts to the current play" do
      # Real Ansible's own doc, verified live: "neither refresh_inventory
      # nor add_host add hosts to the hosts the current play iterates
      # over" - only a LATER play's own hosts: pattern match sees newly-
      # appeared hosts. The dynamic inventory script here reports 1 host
      # normally, 2 once a marker file exists - play 1 creates that
      # marker then refreshes, but must still only see the original
      # host; play 2 must see both.
      script = File.tempname("dynamic-inventory-refresh", ".sh")
      marker = File.tempname("dynamic-inventory-refresh-marker")
      File.delete(marker) rescue nil
      File.write(script, <<-SH)
        #!/bin/sh
        if [ -f #{marker} ]; then
          echo '{"all":{"hosts":["hostone","hosttwo"]},"_meta":{"hostvars":{"hostone":{"ansible_connection":"local"},"hosttwo":{"ansible_connection":"local"}}}}'
        else
          echo '{"all":{"hosts":["hostone"]},"_meta":{"hostvars":{"hostone":{"ansible_connection":"local"}}}}'
        fi
        SH
      File.chmod(script, 0o755)

      tmp = File.tempname("meta-refresh-inventory", ".yml")
      File.write(tmp, <<-YAML)
        - hosts: all
          gather_facts: false
          tasks:
            - name: create marker
              ansible.builtin.file:
                path: #{marker}
                state: touch
              delegate_to: localhost
            - name: refresh
              ansible.builtin.meta: refresh_inventory
            - name: play1 saw it
              ansible.builtin.debug:
                msg: "play1 saw {{ inventory_hostname }}"
        - hosts: all
          gather_facts: false
          tasks:
            - name: play2 saw it
              ansible.builtin.debug:
                msg: "play2 saw {{ inventory_hostname }}"
        YAML
      begin
        captured = IO::Memory.new
        status = Process.run(BINARY, ["-i", script, tmp], output: captured, error: captured)
        output = captured.to_s

        status.success?.should be_true
        output.should contain("play1 saw hostone")
        output.should_not contain("play1 saw hosttwo")
        output.should contain("play2 saw hostone")
        output.should contain("play2 saw hosttwo")
      ensure
        File.delete(tmp) rescue nil
        File.delete(script) rescue nil
        File.delete(marker) rescue nil
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

  it "--forks 1 (one-host-at-a-time) produces the same content as the --forks 5 default's parallel fan-out" do
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

    # Compared as a multiset of lines, not byte-for-byte: since 0.9.579
    # the parallel path prints each host's block as that host FINISHES
    # (real ansible-playbook's completion order), so the two runs can
    # legitimately order two adjacent host lines differently. What must
    # not change with --forks is WHAT happened - every line, once.
    forks1_output.lines.sort!.should eq(default_output.lines.sort!)
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
    # Each host's own lines stay together, never interleaved mid-task by
    # the concurrent fan-out. The ORDER of the two is completion order
    # since 0.9.579 (matching real ansible-playbook, which reports the
    # host that finished first), so either arrangement is correct - what
    # must hold is that the two lines are adjacent, not split apart.
    adjacent = output.includes?("changed: [web1]\nchanged: [web2]") ||
               output.includes?("changed: [web2]\nchanged: [web1]")
    adjacent.should be_true
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
    (match || raise "unexpected nil")[1].should eq((match || raise "unexpected nil")[2])
    output.should contain("become smoke test complete!")

    # Real bug found benchmarking geerlingguy.solr's own "Ensure core
    # configuration directories exist." task (become_user: solr,
    # krikri-playbook installed under /root/...): execute_local_plugin
    # always ran the compiled plugin binary straight from wherever
    # krikri-playbook itself lives, which broke the moment that install
    # directory wasn't traversable by become_user (a root-owned
    # /root/... install is a common real-world case) - `sudo: Sorry,
    # user root is not allowed to execute '/root/.../plugins/command'
    # as solr`, really a plain EACCES on /root's own 0700 mode, not an
    # actual sudoers policy denial. A become: task must now stage a
    # world-traversable copy of the plugin binary at REMOTE_PLUGIN_DIR
    # before sudo-ing to it, exactly as this "become to the current
    # user" task (command:, become: true) already exercises above.
    staged_command_plugin = "/var/tmp/.krikri-playbook/plugins/command"
    File.exists?(staged_command_plugin).should be_true
    (File.info(staged_command_plugin).permissions.value & 0o777).should eq(0o755)
  end

  it "keeps register:/set_fact:/include_vars: visible across tasks, and role_defaults from leaking past their own role, through build_vars_context's per-host caching (SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #1)" do
    # build_vars_context now caches its per-host-invariant inputs (baseA:
    # play_vars/host.vars/registered_vars; baseB: included_vars/facts/
    # host-magic) behind a shared generation counter instead of
    # rebuilding them from scratch on every task - real risk here is
    # exactly this project's most-repeated bug class (stale/wrong
    # variable visibility), so this exercises every real invalidation
    # path in one sequence on one host: register: visible on the very
    # next task (baseA), set_fact: visible on the very next task (baseB,
    # via @facts), include_vars: visible on the very next task (baseB,
    # via @included_vars), a role's own role_defaults visible during
    # that role but gone again immediately afterward (role_defaults is
    # per-TASK, deliberately NOT part of either cached base), and all 3
    # of the earlier register/fact/include_vars values still correct
    # after the role ran (proving the role's own cache generation bumps
    # - if any - didn't leave a stale base_context_a/b for THIS host).
    hostvars_inventory = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-hostvars-local.ini")
    status, output = run_playbook(
      "test-vars-context-cache-quick.yml",
      [] of String,
      inventory: hostvars_inventory
    )

    status.success?.should be_true
    output.should contain("reg=registered-value")
    output.should contain("fact=from-set-fact")
    output.should contain("included=from-os-family-file")
    output.should contain("after_role_default=MISSING")
    output.should contain("still_visible=reg:registered-value fact:from-set-fact included:from-os-family-file")
    output.should contain("vars_context cache invalidation smoke test complete!")
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

  it "reflects a register:/set_fact:/meta: clear_facts done by one host in another host's hostvars[...] on the very next task" do
    # Regression for SUGGESTED_PERFORMANCE_IMPROVEMENTS.md item #16:
    # build_hostvars/build_groups got memoized per-TaskExecutor (a
    # generation counter bumped on every @facts/@registered_vars
    # mutation) since the unmemoized version was quadratic in host count.
    # This is the invalidation contract's own regression spec, not just a
    # feature test - a naive "cache once, never invalidate" version would
    # pass every OTHER hostvars spec (single-shot reads) but silently
    # serve a stale hostvars['h1'] snapshot here, missing h1's own
    # register:/set_fact:/clear_facts from earlier in the SAME play.
    hostvars_inventory = File.join(PROJECT_ROOT, "spec", "fixtures", "inventory-hostvars-local.ini")
    status, output = run_playbook(
      "test-hostvars-cache-invalidation-quick.yml",
      [] of String,
      inventory: hostvars_inventory
    )

    status.success?.should be_true
    output.should contain("got_register=dynamic_h1_value")
    output.should contain("got_fact=fact_value_one")
    output.should contain("cleared=True")
    output.should contain("hostvars cache invalidation smoke test complete!")
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
    output.should contain(%(multilocal_members=['web1', 'web2']))
    output.should contain(%(all_members=['web1', 'web2']))
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
    # first `cd`'d into the krikri-playbook checkout - unlike real
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
    # never actually read anywhere else - krikri-playbook ran hosts: all
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

  it "fires a handler notified by a block: itself when a nested task (with no notify: of its own) changes" do
    # Regression: execute_block/execute_block_multi never checked the
    # enclosing block: task's own notify: at all - only an individual
    # nested task's own notify: was ever forwarded to HandlerRunner.
    status, output = run_playbook("test-block-notify-quick.yml", [] of String)

    status.success?.should be_true
    output.should contain("RUNNING HANDLER")
    output.should contain("handler fired")
  end

  it "parses connection: on a task separately from delegate_to:, and exposes it as ansible_connection for that task" do
    # Regression: `connection:` (distinct from delegate_to: - it changes
    # HOW the task's module runs, not WHICH host's vars/facts apply) was
    # never parsed at all, so it had no effect - robertdebock.backup's
    # own "Create backup_directory" (writes to the controller's
    # filesystem via connection: local, no delegate_to:) silently ran
    # against the real remote target instead, live-reverified fixed on
    # a real Atlantic.net host pair (round 136). Both hosts here are
    # already local-connection either way, so this only proves
    # connection: local is parsed and threaded into the task's own
    # ansible_connection - not that it overrides an otherwise-remote
    # host, which would need a real second SSH-reachable target this
    # spec suite doesn't have (PluginManager's own eager per-play
    # plugin pre-upload pass - see its comment in plugin_manager.cr -
    # is scoped to hosts:, not individual tasks:, so a synthetic
    # unreachable host hangs there before ever reaching this task,
    # regardless of the override).
    status, output = run_playbook(
      "test-connection-local-quick.yml",
      [] of String,
      inventory: TWO_LOCAL_HOSTS_INVENTORY
    )

    status.success?.should be_true
    output.should contain("connection is local")
  end

  it "doesn't crash a task whose when: skips it, even when its own task-level vars: would raise if evaluated (render_task_vars laziness)" do
    # Real bug found benchmarking devsec.hardening.os_hardening: task-
    # level vars: were rendered unconditionally, before when: was even
    # checked, so a vars: expression that legitimately raises (`| first`
    # on a genuinely empty sequence, even with `| default(None)` right
    # after it) crashed the whole task even though when: would have
    # skipped it before real Ansible's own lazy per-key Jinja templating
    # ever touched that expression.
    status, output = run_playbook("test-task-vars-lazy-quick.yml", [] of String)

    status.success?.should be_true
    output.should contain("SUCCESS")
    output.should_not contain("should never print")
  end

  # Real Ansible aborts the run at the notifying task, prints one
  # "[ERROR]: The requested handler ... was not found in either the main
  # handlers list nor in the listening handlers list" line and exits 1
  # with no PLAY RECAP - but ONLY when the notification actually fires.
  # Every expectation here was verified against real ansible-core 2.19.4
  # running the equivalent playbook, including the exit codes.
  describe "notify: naming a nonexistent handler" do
    it "aborts the run with rc=1 when a CHANGED task notifies it" do
      write_notify_playbook("notify_missing_changed.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: changes and notifies a missing handler
              ansible.builtin.command: echo hi
              notify: no_such_handler
            - name: after
              ansible.builtin.debug:
                msg: should never be reached
          handlers:
            - name: real handler
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        File.join("..", "spec", "tmp", "notify_missing_changed.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.should eq(1)
      output.should contain("The requested handler 'no_such_handler' was not found in either the main handlers list nor in the listening handlers list")
      output.should_not contain("should never be reached")
      output.should_not contain("PLAY RECAP")
    end

    it "does not abort when the notifying task is unchanged - real Ansible notifies nothing" do
      write_notify_playbook("notify_missing_unchanged.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: does not change but notifies a missing handler
              ansible.builtin.debug:
                msg: nochange
              notify: no_such_handler
            - name: after
              ansible.builtin.debug:
                msg: reached
          handlers:
            - name: real handler
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        File.join("..", "spec", "tmp", "notify_missing_unchanged.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.should eq(0)
      output.should contain("reached")
      output.should_not contain("was not found in either")
    end

    it "does not abort when the notifying task is skipped by its when:" do
      write_notify_playbook("notify_missing_skipped.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: skipped, notifies a missing handler
              ansible.builtin.command: echo hi
              when: false
              notify: no_such_handler
            - name: after
              ansible.builtin.debug:
                msg: reached
          handlers:
            - name: real handler
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        File.join("..", "spec", "tmp", "notify_missing_skipped.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.should eq(0)
      output.should contain("reached")
      output.should_not contain("was not found in either")
    end

    it "catches a bad notify inside an include_tasks:-loaded file, which no parse-time sweep can see" do
      # The buluma.phpmyadmin shape (round 181): setup-Debian.yml is
      # pulled in via include_tasks: and notifies `restart apache`, a
      # handler nothing in the role's dependency chain defines. Must not
      # be swallowed into a per-task "Failed to load included tasks"
      # failure either - real Ansible aborts the whole run.
      write_notify_playbook("notify_missing_inner.yml", <<-YAML)
        - name: inner changes and notifies a missing handler
          ansible.builtin.command: echo hi
          notify: restart apache
        YAML

      write_notify_playbook("notify_missing_include.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: include it
              ansible.builtin.include_tasks: notify_missing_inner.yml
            - name: after
              ansible.builtin.debug:
                msg: should never be reached
          handlers:
            - name: Restart httpd
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        File.join("..", "spec", "tmp", "notify_missing_include.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.should eq(1)
      output.should contain("The requested handler 'restart apache' was not found")
      output.should_not contain("Failed to load included tasks")
      output.should_not contain("should never be reached")
    end

    it "accepts a notify: that matches a handler's listen: topic" do
      write_notify_playbook("notify_listen_topic.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: notify a listen topic
              ansible.builtin.command: echo hi
              notify: webserver restarted
          handlers:
            - name: restart httpd
              listen: webserver restarted
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        File.join("..", "spec", "tmp", "notify_listen_topic.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.should eq(0)
      output.should_not contain("was not found in either")
    end

    it "accepts a notify: whose matching handler's own name: is a template" do
      write_notify_playbook("notify_templated_handler.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          vars:
            svc: httpd
          tasks:
            - name: notify the rendered name
              ansible.builtin.command: echo hi
              notify: "Restart httpd"
          handlers:
            - name: "Restart {{ svc }}"
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        File.join("..", "spec", "tmp", "notify_templated_handler.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.should eq(0)
      output.should_not contain("was not found in either")
    end

    it "accepts the role-qualified '<qualifier> : <name>' notify: form" do
      write_notify_playbook("notify_role_qualified.yml", <<-YAML)
        - hosts: localhost
          connection: local
          gather_facts: false
          tasks:
            - name: notify role-qualified
              ansible.builtin.command: echo hi
              notify: "some_role : restart httpd"
          handlers:
            - name: restart httpd
              ansible.builtin.debug:
                msg: h
        YAML

      status, output = run_playbook(
        File.join("..", "spec", "tmp", "notify_role_qualified.yml"),
        mode_args: [] of String,
        inventory: EXPLICIT_LOCALHOST_INVENTORY,
      )

      status.exit_code.should eq(0)
      output.should_not contain("was not found in either")
    end
  end

  it "exits non-zero and reports the error for an invalid playbook" do
    Dir.mkdir_p(File.join(PROJECT_ROOT, "spec", "tmp"))
    bad_playbook = File.join(PROJECT_ROOT, "spec", "tmp", "invalid.yml")
    File.write(bad_playbook, "not: a: valid: playbook: [")

    status, output = run_playbook(File.join("..", "spec", "tmp", "invalid.yml"))

    status.success?.should be_false
    # Since 0.9.562 a YAML syntax error is reported in real
    # ansible-playbook's own shape rather than this engine's old
    # "Error parsing playbook:" wording - see YamlSyntaxError#render and
    # yaml_syntax_error_spec.cr, which byte-compares the whole block.
    output.should contain("[ERROR]: YAML parsing failed:")
    output.should contain("Origin: ")
    status.exit_code.should eq(4)

    File.delete(bad_playbook)
  end
end

# Found via a real-host geerlingguy.raspberry-pi round: once a host fails a
# task and gets halted, real ansible-playbook ends the play right there -
# it does not keep printing "TASK [...]" banners for the tasks that follow,
# since there is no host left to run them against.
describe "a notified handler with an empty loop: source" do
  it "is counted as skipped, not ok, matching real ansible-playbook" do
    # Real bug found benchmarking cloudalchemy.cortex's own "reload
    # cortex services" handler (`loop: "{{ cortex_services | dict2items
    # }}"`, empty when cortex_all_in_one: is set): real Ansible skips
    # the whole handler ("All items skipped") and counts it in the
    # recap's skipped= tally. execute_handler_loop previously fell
    # through its own empty loop silently - no "skipping:" line, and
    # record_handler_result's already_displayed branch counted the
    # no-op changed=false/failed=false result as ok instead, inflating
    # ok= by one and undercounting skipped= by one.
    write_notify_playbook("empty_loop_handler_skipped.yml", <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: notify a handler with nothing to loop over
            ansible.builtin.command: echo hi
            notify: reload things
        handlers:
          - name: reload things
            ansible.builtin.debug:
              msg: "{{ item }}"
            loop: "{{ [] }}"
      YAML

    status, output = run_playbook(
      File.join("..", "spec", "tmp", "empty_loop_handler_skipped.yml"),
      mode_args: [] of String,
      inventory: EXPLICIT_LOCALHOST_INVENTORY,
    )

    status.exit_code.should eq(0)
    output.should contain("HANDLER [reload things]")
    output.should contain("skipping: [localhost]")
    output.should contain("ok=1")
    output.should contain("skipped=1")
  end
end

describe "a task combining a module with a pre-2.0 legacy directive" do
  it "aborts the whole run with 'conflicting action statements', matching real ansible-playbook" do
    # Real bug found benchmarking nickjj.mariadb/.postgres/.phpfpm, all
    # three independently: an old task carrying both a real module key
    # and a pre-2.0 Ansible top-level attribute (always_run:, sudo_user:,
    # etc.) that was removed a long time ago. Real ansible-core's
    # ModuleArgsParser refuses to even START the run for this
    # ("[ERROR]: conflicting action statements: shell, always_run",
    # rc=1) - this engine previously just silently ignored the legacy
    # key (or, if it happened to appear first in the YAML, mistook it
    # for the module name outright) and ran the task normally instead.
    write_notify_playbook("conflicting_action_statements.yml", <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: an old task with a removed legacy directive
            shell: echo hi
            always_run: true
      YAML

    status, output = run_playbook(
      File.join("..", "spec", "tmp", "conflicting_action_statements.yml"),
      mode_args: [] of String,
      inventory: EXPLICIT_LOCALHOST_INVENTORY,
    )

    status.exit_code.should eq(1)
    output.should contain("[ERROR]: conflicting action statements: shell, always_run")
    output.should_not contain("PLAY RECAP")
  end
end

describe "a halted host after a task failure" do
  it "stops printing TASK banners for tasks after the failure, matching real ansible-playbook" do
    write_notify_playbook("halted_host_no_more_banners.yml", <<-YAML)
      - hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: this one fails
            ansible.builtin.fail:
              msg: boom
          - name: should never be reached
            ansible.builtin.debug:
              msg: should never be reached
      YAML

    status, output = run_playbook(
      File.join("..", "spec", "tmp", "halted_host_no_more_banners.yml"),
      mode_args: [] of String,
      inventory: EXPLICIT_LOCALHOST_INVENTORY,
    )

    status.exit_code.should eq(2)
    output.should contain("TASK [this one fails]")
    output.should_not contain("TASK [should never be reached]")
    output.should_not contain("should never be reached")
  end
end
