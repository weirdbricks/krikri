require "../spec_helper"
require "../../src/krikri/task_batcher"

private def task(name : String, register : String? = nil) : Krikri::Task
  # ansible.builtin.command: a plain module with no action plugin - was
  # ansible.builtin.debug until debug: itself became a (batching-
  # excluded) controller-side action plugin, which broke every "generic
  # batchable task" fixture in this file for reasons unrelated to what
  # each spec actually tests (register:/when: run-splitting logic, not
  # debug: semantics specifically).
  t = Krikri::Task.new(name, "ansible.builtin.command")
  t.register = register
  t
end

describe Krikri::TaskBatcher do
  it "groups a run of fully independent tasks into a single batch" do
    tasks = [task("a"), task("b"), task("c")]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.size.should eq(1)
    groups.first.map(&.name).should eq(["a", "b", "c"])
  end

  it "ends the batch after a task whose notify: is certain to abort the run" do
    # Real Ansible aborts at the notifying task, having run nothing
    # after it; a batch group would already have executed every
    # remaining step in the same SSH round trip, applying side effects
    # real Ansible never applies (verified live over SSH - round 181).
    a = task("a")
    b = task("b")
    b.notify = ["no_such_handler"]
    c = task("c")

    groups = Krikri::TaskBatcher.plan([a, b, c], ->(t : Krikri::Task) { t.notify == ["no_such_handler"] })

    groups.map(&.map(&.name)).should eq([["a", "b"], ["c"]])
  end

  it "keeps batching a notify: that can be answered - the ordinary case pays nothing" do
    a = task("a")
    b = task("b")
    b.notify = ["real handler"]
    c = task("c")

    groups = Krikri::TaskBatcher.plan([a, b, c], ->(_t : Krikri::Task) { false })

    groups.size.should eq(1)
    groups.first.map(&.name).should eq(["a", "b", "c"])
  end

  it "splits a run right before a task that references an earlier register: (bare when:)" do
    a = task("a", register: "result_a")
    b = task("b")
    b.when_condition = "result_a.changed"
    tasks = [a, b]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"]])
  end

  it "splits a run right before a task that references an earlier register: in params: ({{ }} wrapped)" do
    a = task("a", register: "result_a")
    b = task("b")
    b.params["msg"] = "value is {{ result_a.stdout }}"
    tasks = [a, b]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"]])
  end

  it "does not split when a later task references a register: from a task that already ended its own run" do
    # a registers result_a but is itself in a length-1 group (loop:), so
    # by the time b/c run, result_a is already known controller-side -
    # no reason to split b/c apart from each other.
    a = task("a", register: "result_a")
    a.loop_items = [JSON::Any.new("x")]
    b = task("b")
    b.when_condition = "result_a.changed"
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b", "c"]])
  end

  it "does not split on a register: reference that isn't a real match (substring, not whole word)" do
    a = task("a", register: "result")
    b = task("b")
    b.when_condition = "result_extended.changed" # "result" is a substring but not a whole-word match
    tasks = [a, b]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.size.should eq(1)
  end

  it "ends the run at a service_facts: task, even with no register: for a later task to reference" do
    # Real bug found benchmarking geerlingguy.ntp: its own "Disable
    # systemd-timesyncd if it's running but ntp is enabled." task reads
    # the bare `services` fact (service_facts:'s own top-level
    # registered var, no register: name at all) in a `when:` right
    # after "Populate service facts." - produces_ansible_facts? already
    # had this exact guard for getent:/package_facts:/set_fact:, which
    # write facts with no register: name either, but service_facts:
    # itself was missing from that list. Batched together, the later
    # task's `when:` got rendered against pre-batch (still-undefined)
    # `services`, always silently skipping - a real behavioral
    # divergence from real Ansible, not just wasted batching.
    a = task("a")
    b = Krikri::Task.new("b", "ansible.builtin.service_facts")
    c = task("c")
    c.when_condition = "\"foo.service\" in services"
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a block: task" do
    a = task("a")
    b = Krikri::Task.new("b", "_block")
    b.block_tasks = [] of Krikri::Task
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at an include_tasks: task" do
    a = task("a")
    b = Krikri::Task.new("b", "_include_tasks")
    b.include_file = "x.yml"
    b.include_file_dir = "."
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at an include_role: task" do
    a = task("a")
    b = Krikri::Task.new("b", "_include_role")
    b.include_role_name = "x"
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a looped task (loop_items)" do
    a = task("a")
    b = task("b")
    b.loop_items = [JSON::Any.new("x"), JSON::Any.new("y")]
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a task with until_condition" do
    a = task("a")
    b = task("b")
    b.until_condition = "result.rc == 0"
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at an async: task" do
    a = task("a")
    b = task("b")
    b.async_seconds = 60
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a delegate_to: task" do
    a = task("a")
    b = task("b")
    b.delegate_to = "localhost"
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at an ansible.builtin.reboot task" do
    # Regression: reboot: has no plugin binary at all (TaskExecutor#
    # execute_reboot handles it entirely on the controller, over its own
    # direct SSH calls) - batching it alongside other tasks would run it
    # inside a shared SSH batch script, killing that whole connection
    # mid-script (and everything else in the same batch) the moment the
    # target actually reboots, instead of the single dedicated
    # connection execute_reboot expects to control itself.
    a = task("a")
    b = Krikri::Task.new("reboot", "ansible.builtin.reboot")
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["reboot"], ["c"]])
  end

  it "ends the run at a run_once: task" do
    a = task("a")
    b = task("b")
    b.run_once = true
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a changed_when: task" do
    a = task("a")
    b = task("b")
    b.changed_when = "false"
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a failed_when: task" do
    a = task("a")
    b = task("b")
    b.failed_when = "result.rc != 0"
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "every task appears in exactly one group, in original order" do
    c = task("c")
    c.when_condition = "r.changed"
    tasks = [task("a"), task("b", register: "r"), c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.flat_map(&.map(&.name)).should eq(["a", "b", "c"])
  end
end
