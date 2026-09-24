require "./playbook_parser"
require "./action_plugin_manager"
require "./plugin_manager"

module Krikri
  # Pure planning logic for task batching (on by default; --no-batching
  # disables it) - groups a flat
  # task list into consecutive "batchable runs" with no I/O, no
  # host/vars dependency, and no knowledge of connection type.
  # TaskExecutor decides separately
  # (per host, at run time) whether a given run of size >= 1 is actually
  # worth/eligible for a real batched SSH round trip; a size-1 run here
  # just means "this task can't extend a run on either side" and behaves
  # exactly like today's one-task-at-a-time path.
  #
  # A task can only safely share a batch with its neighbors if nothing
  # about executing it needs data that only exists once an earlier task
  # in the SAME run has actually executed remotely - see the reasoning
  # behind each condition below.
  module TaskBatcher
    # Groups *tasks* (one flat list - a play's top-level tasks, or one
    # block:/rescue:/always:'s own nested list; this does not recurse
    # into block_tasks/rescue_tasks/always_tasks itself - call it
    # separately for each nested list you also want grouped) into
    # consecutive runs, preserving order. Every task in *tasks* appears
    # in exactly one returned group.
    # *aborts_on_notify* (supplied by TaskExecutor, which owns the play's
    # handler list) answers "if this task fires its notify:, will the run
    # abort with HandlerNotFoundError?" - real Ansible stops right there,
    # having run nothing after it, while a batch group would already have
    # executed every remaining step in the same SSH round trip, applying
    # real side effects on the target that real Ansible never applies.
    # Such a task therefore ENDS its group (it may still run batched with
    # what precedes it - the abort happens after it, not before). Only a
    # notify: that is CERTAIN to abort breaks the run, so an ordinary
    # playbook loses no batching at all.
    def self.plan(tasks : Array(Task), aborts_on_notify : Proc(Task, Bool)? = nil) : Array(Array(Task))
      groups = [] of Array(Task)
      current = [] of Task
      # Compiled once per register name, when it's added below - not
      # once per (task, name) pair inside references_register?, which
      # used to recompile the same pattern for every later task in the
      # run that needed checking against it.
      seen_registers = Hash(String, Regex).new

      flush = -> {
        groups << current unless current.empty?
        current = [] of Task
        seen_registers = Hash(String, Regex).new
      }

      tasks.each do |task|
        if breaks_run?(task, group_has_registers: !seen_registers.empty?)
          flush.call
          groups << [task]
          next
        end

        flush.call if references_register?(task, seen_registers)

        current << task

        if aborts_on_notify && aborts_on_notify.call(task)
          flush.call
          next
        end

        if (reg = task.register) && !reg.empty?
          seen_registers[reg] = /\b#{Regex.escape(reg)}\b/
        end
      end

      flush.call
      groups
    end

    # A task in any of these categories can never extend (or be extended
    # by) a batch run - it's always its own length-1 group (the one
    # exception: a template: joining a register-free group, see
    # runs_as_action_plugin? below):
    #
    # - block?/include_tasks?/include_role?: structural/dynamic, handled
    #   by TaskExecutor's own recursive block/include machinery, not by
    #   sending a flattened script.
    # - looped (loop_items/loop_fileglob/loop_template_kind): each
    #   iteration already goes through its own execute_task_once call;
    #   batching N *iterations* of one task is a distinct, separate
    #   opportunity from batching N *different* tasks (out of scope for
    #   this v1).
    # - until_condition/async_seconds: fundamentally sequential/local
    #   (retry-until-condition and detached-background-process both need
    #   controller-side control flow between attempts/polls).
    # - delegate_to: may target a different exec_host than its neighbors;
    #   conservative - not attempting to prove two delegate_to: values
    #   are equal (they may be templated and only resolvable at runtime).
    # - run_once: only the play's first host actually executes it; other
    #   hosts skip it via TaskExecutor#copy_run_once_register *before*
    #   reaching any batching decision at all. If a run_once: task were
    #   left inside a batch group, a non-first host reaching the *group's
    #   first* task would still trigger the whole group's remote script -
    #   including the run_once: step it should never have run for that
    #   host.
    # - failed_when:: this can retroactively override a task's `failed:`
    #   verdict using data (the module's own result) that's only
    #   available after evaluating a Jinja expression controller-side.
    #   The batch script's own script-side fail-fast (task 2/design's
    #   protocol) can only see a step's raw exit code and its own JSON
    #   `"failed":true`/`false` - it has no way to know failed_when:
    #   would flip that verdict, so a task that should have halted the
    #   host (per failed_when:) could let later batch steps run anyway,
    #   executing real side effects on the target that should never have
    #   happened. Excluding these tasks from batches entirely avoids the
    #   whole class of bug.
    #   changed_when: is deliberately NOT here: it only ever rewrites the
    #   `changed` field, which the script/daemon fail-fast never reads
    #   (it halts on raw `failed` alone), and execute_batch_group already
    #   applies apply_changed_failed_when per member after the batch's
    #   results come back - the same per-member rewrite the solo path
    #   does. Forcing every changed_when:-bearing task solo cost whole
    #   round trips for nothing (changed_when: false on read-only
    #   command:/shell: steps is one of the most common idioms in real
    #   roles). Its one remaining hazard - a changed_when: referencing
    #   an earlier group member's register: - is a data dependency, owned
    #   by references_register? below, which now scans the changed_when:
    #   text itself.
    # - unavailable_module: a role-private `library/*.py` module (see
    #   PythonModuleRunner) dispatches through the py_module plugin with
    #   its OWN uploaded source, not a compiled plugin binary named
    #   after the module - the batch script builder assumes every step
    #   maps to a normal uploaded plugin binary and has no such
    #   resolution, so a batched sr_fingerprint:/blivet: task failed
    #   outright with "Plugin binary not found: sr_fingerprint" instead
    #   of ever reaching python_module_source_for's dispatch. Found
    #   re-testing linux-system-roles.storage after fixing that
    #   resolution's own role_files_dir bug - the module was finally
    #   found, but batching got in the way before dispatch ever saw it.
    # *group_has_registers* reports whether the group being built has
    # already registered anything (see runs_as_action_plugin? below -
    # the only condition that depends on group state, not just the task
    # alone).
    private def self.breaks_run?(task : Task, group_has_registers : Bool) : Bool
      structural_or_dynamic?(task) || needs_controller_control_flow?(task) ||
        runs_off_the_target?(task) || runs_on_the_controller?(task) ||
        task.run_once? || retroactive_verdict?(task) ||
        produces_ansible_facts?(task) || runs_as_action_plugin?(task, group_has_registers) ||
        reconfigures_firewall?(task) || resolves_module_at_runtime?(task) ||
        !!task.unavailable_module ||
        # group_by:/set_stats: - same category as reboot: above: no
        # uploaded plugin binary at all, handled entirely controller-side
        # (group_by: mutates the shared Inventory; set_stats: writes into
        # a controller-side accumulator for the final recap) - neither
        # can run as a remote batch script step.
        {"ansible.builtin.reboot", "ansible.builtin.group_by", "ansible.builtin.set_stats"}.includes?(task.module_name)
    end

    # A templated action:/local_action: (see Task#templated_action)
    # resolves its real module name only at execution - the batch script
    # path has no such resolution, and a module name that is still a raw
    # `{{ }}` template would fail plugin lookup there.
    private def self.resolves_module_at_runtime?(task : Task) : Bool
      !!task.templated_action
    end

    # delegate_to: may execute against a different host than the batch
    # group's shared connection; connection: re-routes the task the same
    # way. Both always run solo.
    private def self.runs_off_the_target?(task : Task) : Bool
      !!task.delegate_to || !!task.connection
    end

    # fetch: and wait_for_connection: (PluginManager::CONTROLLER_ONLY_PLUGINS)
    # must run on the CONTROLLER regardless of the target: fetch reverses
    # the direction of every other plugin (it SSH-pulls a file FROM the
    # target and writes it to the controller's own filesystem), and
    # wait_for_connection: retries the connection attempt from the
    # controller. A batch group is a single script executed over the
    # target's SSH connection, so a controller-only member emitted as a
    # remote step runs ON THE TARGET - fetch then writes the pulled file
    # into the target's /tmp instead of the controller's, and any later
    # `delegate_to: localhost` task looking for it on the controller finds
    # nothing (found on the modules-data benchmark's "Remove fetched
    # controller copy", where the pull landed in the container, not the
    # controller, only under a long remote run that batched it - an
    # isolation repro used a local connection, which the runner already
    # sends solo). Breaks the run so it never joins a remote group; the
    # runner's own controller-only guard sends its size-1 group back down
    # the solo path where PluginManager dispatches it correctly.
    private def self.runs_on_the_controller?(task : Task) : Bool
      PluginManager.controller_only?(task.module_name)
    end

    # ufw: (community.general.ufw) applies live firewall rules - real
    # Ansible runs every task as its own separate SSH connection, so a
    # transient connectivity blip from one rule taking effect (a brief
    # conntrack table flush/reset, a rule that momentarily touches the
    # control connection's own path) only ever risks *that* task's
    # connection, which reconnects fresh for the next one. Batching
    # holds one continuous SSH session open across every task in the
    # group - if a firewall rule anywhere in the middle of a long batch
    # causes even a brief interruption, the *entire* batch's single
    # shared connection can drop and never recover, failing every
    # remaining step in that group along with it (observed running
    # konstruktoid-hardening's UFW rule section: the whole host went
    # unreachable partway through a batched run of consecutive `ufw:`
    # tasks, at a point real ansible-playbook's own one-connection-per-
    # task run had already gotten past cleanly). Always its own group
    # trades a little round-trip efficiency for the same safety
    # property real Ansible has here unconditionally.
    private def self.reconfigures_firewall?(task : Task) : Bool
      # ufw: applies live firewall rules; sysctl: (ansible.posix.sysctl)
      # can just as easily disrupt live networking when the setting
      # touches netfilter/conntrack state - konstruktoid-hardening's own
      # "Configure conntrack sysctl" task (a `with_dict:` loop over
      # `net.netfilter.nf_conntrack_*` settings, immediately after its
      # UFW rule section) reproduced the identical batched-connection-
      # drop failure mode ufw: tasks already needed this same fix for.
      task.module_name.ends_with?("ufw") || task.module_name.ends_with?("sysctl")
    end

    # template: (and any future action plugin) renders on the
    # *controller*, at batch-*preparation* time - before the single SSH
    # round trip that actually executes any group member remotely. A
    # template referencing an earlier group member's `register:`ed
    # result (konstruktoid-hardening's own "Check if ssh_config.d
    # exits" -> "Configure ssh client" pair, both inside the same
    # `block:`) would render against a vars_context that doesn't have it
    # yet - `references_register?` below can't catch this the way it
    # catches an ordinary task's params/when: referencing it, because
    # the reference lives inside the *template file's own content*
    # (a separate file, never scanned for register-name references at
    # batch-planning time), not in any of the task's own YAML fields.
    #
    # That hazard only points backwards, though: the file can only
    # reference a register some EARLIER member of the group being built
    # produced. When that group has registered nothing yet, there is
    # nothing from THIS group for the file to reference, so a template:
    # is safe to let JOIN the current run - and its own register:, if
    # any, is tracked like any other task's for the members that follow
    # it (a later template: then sees a non-empty register set and
    # splits again). Every other action plugin keeps the unconditional
    # solo rule: their controller-side inputs (copy: content:, assert:'s
    # that:, pause:'s prompt handling, ...) all live in the task's own
    # YAML fields, which `references_register?` already scans, so
    # narrowing the exception to the one plugin whose input is an
    # unscannable external file keeps the rest of the class conservative.
    private def self.runs_as_action_plugin?(task : Task, group_has_registers : Bool) : Bool
      return false if !group_has_registers && task.module_name.ends_with?("template")
      ActionPluginManager.has_action_plugin?(task.module_name)
    end

    # getent:/package_facts:/service_facts:/set_fact: (unlike a plain
    # register:, which references_register? below already guards) write
    # new ansible_facts/variables as a normal part of *every* run, with
    # no register: name for a later group member's params to be caught
    # referencing. A batch group's member params are all rendered up
    # front, before the single SSH round trip that actually runs any of
    # them - a later member referencing one of these facts (dev-sec
    # os_hardening's own molecule test: `getent: {database: passwd}`
    # immediately followed by tasks reading `ansible_facts.getent_passwd`)
    # would render against whatever that fact was *before* this task ran,
    # not after. Always its own group avoids the whole class of bug, the
    # same way structural_or_dynamic?'s pseudo-modules are.
    #
    # service_facts: was missing from this list entirely - real bug
    # found benchmarking geerlingguy.ntp's own "Disable systemd-
    # timesyncd if it's running but ntp is enabled." task, which reads
    # the bare `services` fact (`service_facts:`'s own registered
    # top-level var) in a `when:` immediately after a "Populate service
    # facts." task. Batched together, `services` was still undefined
    # when the `when:` got rendered, so the task always silently skipped
    # - a real behavioral divergence (real Ansible correctly ran it),
    # not just wasted work.
    private def self.produces_ansible_facts?(task : Task) : Bool
      %w[getent package_facts service_facts set_fact].any? { |name| task.module_name.ends_with?(name) }
    end

    private def self.structural_or_dynamic?(task : Task) : Bool
      # include_vars: and meta: are controller-side pseudo-modules (they
      # read YAML / act on execution flow - no plugin binary, nothing runs on
      # the target), so like include_tasks/include_role they must never be
      # folded into a batched SSH script. Previously an include_vars: task
      # was treated as batchable, the batch script tried to execute
      # `_include_vars` as a plugin binary on the target, and the whole
      # batch (and run) failed with "Plugin binary not found: _include_vars".
      task.block? || task.include_tasks? || task.include_role? ||
        task.include_vars? || task.meta? || task.validate_argument_spec?
    end

    private def self.needs_controller_control_flow?(task : Task) : Bool
      # loop_nested_sources/loop_flattened/loop_subelements_list/
      # loop_first_found/loop_file: loop keywords whose SOURCE LIST only
      # resolves once the variable context exists (a with_nested: whose
      # entries are `{{ var }}` references, a with_flattened:/with_
      # subelements:/with_first_found:/with_file: source) set none of the
      # three fields originally checked here - so the task was treated as
      # an ordinary batchable step. Real bug found benchmarking
      # gantsign.sdkman: its "create the SDKMAN installation directories"
      # with_nested: over an empty sdkman_users was batched together with
      # the next task ("download candidates", a plain unconditional uri:);
      # execute_batch_group then prepared the looped member's step with
      # `item` unbound, its strict `{{ item[1] }}` param substitution
      # raised, and the group's fail-fast halted the whole batch BEFORE
      # the next member was ever prepared - which then got no batch-cache
      # entry and printed "skipping:" (real Ansible: "ok:"), silently
      # dropping a real task's execution. Any empty-list templated
      # with_nested:/with_flattened: task immediately followed by a
      # non-looped task hits this.
      !!(task.loop_items || task.loop_fileglob || task.loop_template_kind ||
        task.loop_nested_sources || task.loop_together_sources || task.loop_flattened ||
        task.loop_subelements_list || task.loop_first_found || task.loop_file ||
        task.until_condition || task.async_seconds)
    end

    # failed_when: alone (with or without changed_when:) - see
    # breaks_run?'s reasoning for why changed_when: alone batches fine.
    private def self.retroactive_verdict?(task : Task) : Bool
      !!task.failed_when
    end

    # Conservative (over-inclusive, never under-inclusive) whole-word
    # scan for whether *task* references any register: name introduced
    # earlier in the current run, whether the reference is `{{ }}`-
    # wrapped (params:) or bare (when: is a raw Jinja expression, no
    # `{{ }}` wrapper). A false positive here just ends the run one task
    # early (still correct, just slightly less batching); a false
    # negative would be a real data-dependency bug, so every place a
    # task's own text could plausibly reference a variable is scanned:
    # when_condition, every params: value, and the changed_when: text
    # (execute_batch_group evaluates a member's changed_when: AFTER the
    # batch returns, against that member's batch-prep-time vars_context
    # - so a changed_when: referencing an earlier group member's
    # register: would hit an undefined name there and strictly fail the
    # task where real Ansible resolves it. failed_when: keeps no such
    # scan: a failed_when:-bearing task never shares a group - see
    # retroactive_verdict? - so its expression can only ever reference
    # registers from before the run started).
    private def self.references_register?(task : Task, seen : Hash(String, Regex)) : Bool
      return false if seen.empty?

      haystacks = [] of String
      haystacks << task.when_condition.to_s if task.when_condition
      haystacks << task.changed_when.to_s if task.changed_when
      task.params.each_value { |v| haystacks << v }
      # A templated action:/local_action: carries its whole free-form
      # string here instead of in params - a `{{ r.stdout }}` reference
      # to an earlier member's register: lives in that raw text.
      haystacks << task.templated_action.to_s if task.templated_action

      seen.each_value.any? do |pattern|
        haystacks.any?(&.matches?(pattern))
      end
    end
  end
end
