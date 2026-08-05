require "../spec_helper"
require "../../src/crystal_play/task_batcher"

private def task(name : String, register : String? = nil) : CrystalPlay::Task
  t = CrystalPlay::Task.new(name, "ansible.builtin.debug")
  t.register = register
  t
end

describe CrystalPlay::TaskBatcher do
  it "groups a run of fully independent tasks into a single batch" do
    tasks = [task("a"), task("b"), task("c")]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.size.should eq(1)
    groups.first.map(&.name).should eq(["a", "b", "c"])
  end

  it "splits a run right before a task that references an earlier register: (bare when:)" do
    a = task("a", register: "result_a")
    b = task("b")
    b.when_condition = "result_a.changed"
    tasks = [a, b]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"]])
  end

  it "splits a run right before a task that references an earlier register: in params: ({{ }} wrapped)" do
    a = task("a", register: "result_a")
    b = task("b")
    b.params["msg"] = "value is {{ result_a.stdout }}"
    tasks = [a, b]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

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

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b", "c"]])
  end

  it "does not split on a register: reference that isn't a real match (substring, not whole word)" do
    a = task("a", register: "result")
    b = task("b")
    b.when_condition = "result_extended.changed" # "result" is a substring but not a whole-word match
    tasks = [a, b]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.size.should eq(1)
  end

  it "ends the run at a block: task" do
    a = task("a")
    b = CrystalPlay::Task.new("b", "_block")
    b.block_tasks = [] of CrystalPlay::Task
    c = task("c")
    tasks = [a, b, c]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at an include_tasks: task" do
    a = task("a")
    b = CrystalPlay::Task.new("b", "_include_tasks")
    b.include_file = "x.yml"
    b.include_file_dir = "."
    c = task("c")
    tasks = [a, b, c]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at an include_role: task" do
    a = task("a")
    b = CrystalPlay::Task.new("b", "_include_role")
    b.include_role_name = "x"
    c = task("c")
    tasks = [a, b, c]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a looped task (loop_items)" do
    a = task("a")
    b = task("b")
    b.loop_items = [JSON::Any.new("x"), JSON::Any.new("y")]
    c = task("c")
    tasks = [a, b, c]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a task with until_condition" do
    a = task("a")
    b = task("b")
    b.until_condition = "result.rc == 0"
    c = task("c")
    tasks = [a, b, c]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at an async: task" do
    a = task("a")
    b = task("b")
    b.async_seconds = 60
    c = task("c")
    tasks = [a, b, c]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a delegate_to: task" do
    a = task("a")
    b = task("b")
    b.delegate_to = "localhost"
    c = task("c")
    tasks = [a, b, c]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a run_once: task" do
    a = task("a")
    b = task("b")
    b.run_once = true
    c = task("c")
    tasks = [a, b, c]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a changed_when: task" do
    a = task("a")
    b = task("b")
    b.changed_when = "false"
    c = task("c")
    tasks = [a, b, c]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "ends the run at a failed_when: task" do
    a = task("a")
    b = task("b")
    b.failed_when = "result.rc != 0"
    c = task("c")
    tasks = [a, b, c]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"], ["c"]])
  end

  it "every task appears in exactly one group, in original order" do
    c = task("c")
    c.when_condition = "r.changed"
    tasks = [task("a"), task("b", register: "r"), c]

    groups = CrystalPlay::TaskBatcher.plan(tasks)

    groups.flat_map(&.map(&.name)).should eq(["a", "b", "c"])
  end
end
