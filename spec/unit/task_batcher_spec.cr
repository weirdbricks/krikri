require "../spec_helper"
require "../../src/krikri/inventory_parser"
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

private def plan_play(plays_yaml : String) : Array(Array(String))
  playbook = Krikri::PlaybookParser.parse_string(plays_yaml)
  Krikri::TaskBatcher.plan(playbook.plays[0].tasks).map { |group| group.map(&.name) }
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

  it "ends the run at a controller-only fetch: task" do
    # Regression (modules-data benchmark's "Remove fetched controller
    # copy"): fetch: reverses the direction of every other plugin - it
    # SSH-pulls a file from the target and writes it to the CONTROLLER's
    # filesystem. A batch group is one script run over the target's
    # connection, so a batched fetch ran ON the target and wrote the
    # pulled file into the target's /tmp instead. A later
    # `delegate_to: localhost` task then looked for it on the controller
    # and found nothing ("already absent") while real reported it removed
    # - and only on a long remote run that grouped it with neighbors (an
    # isolation repro used a local connection, which the runner already
    # sends solo, hiding the bug). It must break the run like delegate_to:
    # /reboot: do.
    a = task("a")
    fetch = Krikri::Task.new("pull", "ansible.builtin.fetch")
    c = task("c")
    tasks = [a, fetch, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["pull"], ["c"]])
  end

  it "ends the run at a controller-only wait_for_connection: task" do
    # Same category as fetch: above - wait_for_connection: retries the
    # SSH connection FROM the controller, so it can never run inside the
    # target-side batch script it would otherwise be grouped with.
    a = task("a")
    wait = Krikri::Task.new("wait", "ansible.builtin.wait_for_connection")
    c = task("c")
    tasks = [a, wait, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["wait"], ["c"]])
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

  it "keeps a changed_when:-only task batched with its neighbors" do
    # changed_when: only ever rewrites a member's `changed` field,
    # controller-side, after the batch's results come back
    # (execute_batch_group runs apply_changed_failed_when per member,
    # exactly like the solo path). The batch script/daemon fail-fast
    # reads only the raw `failed` field, which changed_when: never
    # touches, so there is nothing for the group to get wrong - forcing
    # it solo bought a whole extra SSH round trip for every
    # `changed_when: false` on a read-only command:/shell: step, one of
    # the most common idioms in real roles.
    a = task("a")
    b = task("b")
    b.changed_when = "false"
    c = task("c")
    tasks = [a, b, c]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a", "b", "c"]])
  end

  it "splits a run right before a changed_when: task that references an earlier register:" do
    # The one remaining hazard batching a changed_when: task still has:
    # execute_batch_group evaluates each member's changed_when: AFTER
    # the batch returns, against that member's batch-prep-time
    # vars_context - a register: an earlier group member produces only
    # reaches the controller's vars after the whole group has already
    # run, so the reference has to split the run the same way a when:
    # reference does (which then puts the registering task in its own
    # group and the changed_when: task in a fresh one whose prep-time
    # context already has the register).
    a = task("a", register: "result_a")
    b = task("b")
    b.changed_when = "result_a.stdout != ''"
    tasks = [a, b]

    groups = Krikri::TaskBatcher.plan(tasks)

    groups.map { |group| group.map(&.name) }.should eq([["a"], ["b"]])
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

  it "ends the run at a failed_when: task even when it also carries changed_when:" do
    # failed_when: is the hazard, not changed_when: - it can flip a raw
    # `failed: true` to a pass (or the reverse) before the batch
    # script's own fail-fast would have halted the group, letting later
    # members execute real side effects real Ansible never applies.
    # changed_when: riding along on the same task doesn't soften that.
    a = task("a")
    b = task("b")
    b.failed_when = "false"
    b.changed_when = "false"
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

  describe "template: action-plugin batching" do
    # runs_as_action_plugin? used to force every action-plugin task into
    # its own solo group unconditionally, because a .j2 file's content
    # is never scanned for register-name references at batch-planning
    # time. But that hazard only points backwards: the file can only
    # reference a register some EARLIER member of the group being built
    # produced. With no registers in the group yet, a template: is safe
    # to let join - this is the common real-role shape (template: tasks
    # far outnumber register:-then-template: pairs), so the solo rule
    # cost a whole extra SSH round trip per template: task for nothing.
    it "lets a template: task join the group while no earlier member has registered anything" do
      tpl = Krikri::Task.new("render", "ansible.builtin.template")
      b = task("b")
      c = task("c")
      tasks = [tpl, b, c]

      groups = Krikri::TaskBatcher.plan(tasks)

      groups.map { |group| group.map(&.name) }.should eq([["render", "b", "c"]])
    end

    it "still splits a template: task off after an earlier member registered something" do
      # The konstruktoid-hardening shape: an earlier task's register:
      # could be referenced from inside the .j2 file's own content
      # (invisible to references_register?, which only scans the task's
      # own YAML fields) - the old all-solo rule must survive here.
      a = task("a", register: "result_a")
      tpl = Krikri::Task.new("render", "ansible.builtin.template")
      c = task("c")
      tasks = [a, tpl, c]

      groups = Krikri::TaskBatcher.plan(tasks)

      groups.map { |group| group.map(&.name) }.should eq([["a"], ["render"], ["c"]])
    end

    it "re-splits on a second template: after the first one registered its result" do
      # The joining template:'s own register: is tracked like any other
      # task's for the members that follow it - so a later template:
      # (whose file could reference it) must split again.
      first = Krikri::Task.new("render1", "ansible.builtin.template")
      first.register = "rendered"
      second = Krikri::Task.new("render2", "ansible.builtin.template")
      tasks = [first, second]

      groups = Krikri::TaskBatcher.plan(tasks)

      groups.map { |group| group.map(&.name) }.should eq([["render1"], ["render2"]])
    end

    it "keeps other action plugins solo even with no registers in the group" do
      # The join exception is deliberately narrowed to template: - the
      # one action plugin whose controller-side input is an external
      # file. Everything else (debug:, assert:, ...) takes its input
      # from task params, which references_register? already scans, so
      # they keep the unconditional solo rule.
      a = task("a")
      dbg = Krikri::Task.new("dbg", "ansible.builtin.debug")
      c = task("c")
      tasks = [a, dbg, c]

      groups = Krikri::TaskBatcher.plan(tasks)

      groups.map { |group| group.map(&.name) }.should eq([["a"], ["dbg"], ["c"]])
    end
  end

  # Real bug found benchmarking gantsign.sdkman (round 74, 0.9.868): a
  # with_nested: task whose sources are `{{ var }}` references sets
  # loop_nested_sources (not loop_items/loop_template_kind), so it was
  # treated as an ordinary batchable step. Batched together with the next
  # unconditional task, execute_batch_group prepared the looped member's
  # step with `item` unbound, its strict `{{ item[1] }}` param
  # substitution raised, and the group's fail-fast halted the batch
  # before the next member was ever prepared - which then got no
  # batch-cache entry and printed "skipping:" (real Ansible: "ok:"),
  # silently dropping a real task's execution whenever an empty-list
  # templated loop task sat directly before a non-looped one.
  describe "runtime-resolved loop sources are never batched with their neighbors" do
    it "keeps an empty-list with_items: loop task out of the next task's group" do
      groups = plan_play(<<-YAML)
        - hosts: all
          gather_facts: false
          tasks:
            - name: empty loop
              ansible.builtin.debug:
                msg: '{{ item }}'
              with_items: []

            - name: download candidates
              ansible.builtin.uri:
                url: 'http://example.com/'
        YAML

      groups.map(&.size).should eq([1, 1])
      groups.first.first.should eq("empty loop")
      groups[1].first.should eq("download candidates")
    end

    it "keeps a templated with_nested: task (the gantsign.sdkman shape) out of the next task's group" do
      groups = plan_play(<<-YAML)
        - hosts: all
          gather_facts: false
          vars:
            sdkman_users: []
          tasks:
            - name: create the SDKMAN installation directories
              ansible.builtin.file:
                state: directory
                dest: '{{ item[1] }}'
              with_nested:
                - '{{ sdkman_users }}'
                - - /opt/sdkman
                  - /opt/sdkman/bin

            - name: download candidates
              ansible.builtin.uri:
                url: 'http://example.com/'
                return_content: yes
        YAML

      groups.map(&.size).should eq([1, 1])
      groups.first.first.should eq("create the SDKMAN installation directories")
      groups[1].first.should eq("download candidates")
    end

    it "keeps with_flattened:/with_subelements:/with_first_found:/with_file: tasks out of their neighbors' groups too" do
      groups = plan_play(<<-YAML)
        - hosts: all
          gather_facts: false
          tasks:
            - name: flattened
              ansible.builtin.debug:
                msg: '{{ item }}'
              with_flattened:
                - '{{ maybe_empty_list }}'

            - name: after flattened
              ansible.builtin.uri:
                url: 'http://example.com/'

            - name: subelements
              ansible.builtin.uri:
                url: 'http://example.com/'
              with_subelements:
                - '{{ users }}'
                - keys

            - name: after subelements
              ansible.builtin.uri:
                url: 'http://example.com/'

            - name: first found
              ansible.builtin.include_vars:
                file: '{{ item }}'
              with_first_found:
                - ../vars/packages/default.yml

            - name: after first found
              ansible.builtin.uri:
                url: 'http://example.com/'

            - name: with file
              ansible.builtin.copy:
                src: '{{ item }}'
                dest: /tmp/
              with_file:
                - some_file

            - name: after with file
              ansible.builtin.uri:
                url: 'http://example.com/'
        YAML

      groups.map(&.first).should eq([
        "flattened", "after flattened",
        "subelements", "after subelements",
        "first found", "after first found",
        "with file", "after with file",
      ])
    end
  end
end
