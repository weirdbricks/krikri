require "../spec_helper"

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

  it "runs include_tasks: once per loop item with item: in scope, and skips the whole include (not per nested task) when its own when: is false" do
    status, output = run_playbook("test-include-tasks-quick.yml")

    status.success?.should be_true
    output.should contain("dynamic task ran, item=a")
    output.should contain("dynamic task ran, item=b")
    output.should contain("dynamic task ran, item=c")
    output.scan("skipping: [localhost]").size.should eq(1) # one skip for the whole `when: false` include, not one per nested task
    output.should contain("include_tasks smoke test complete!")
  end

  it "runs include_role: once per loop item, applies invocation vars, and fires the role's handler exactly once even though the role (and its handler) were dynamically loaded twice" do
    status, output = run_playbook("test-include-role-quick.yml")

    status.success?.should be_true
    output.should contain("hello crystal-ansible, item=x")
    output.should contain("hello crystal-ansible, item=y")
    output.scan("HANDLER [dynamically included handler]").size.should eq(1)
    output.should contain("include_role smoke test complete!")
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
    output.should contain("user_first=True user_idempotent=False")
    output.should contain("user_priv_changed=True user_removed=True db_removed=True")
    output.should contain("mysql plugins smoke test complete!")
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
