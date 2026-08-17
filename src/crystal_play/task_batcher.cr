require "./playbook_parser"
require "./action_plugin_manager"

module CrystalPlay
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
    def self.plan(tasks : Array(Task)) : Array(Array(Task))
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
        if breaks_run?(task)
          flush.call
          groups << [task]
          next
        end

        flush.call if references_register?(task, seen_registers)

        current << task
        if (reg = task.register) && !reg.empty?
          seen_registers[reg] = /\b#{Regex.escape(reg)}\b/
        end
      end

      flush.call
      groups
    end

    # A task in any of these categories can never extend (or be extended
    # by) a batch run - it's always its own length-1 group:
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
    # - changed_when:/failed_when:: these can retroactively override a
    #   task's `failed:` verdict using data (the module's own result)
    #   that's only available after evaluating a Jinja expression
    #   controller-side. The batch script's own script-side fail-fast
    #   (task 2/design's protocol) can only see a step's raw exit code
    #   and its own JSON `"failed":true`/`false` - it has no way to know
    #   changed_when:/failed_when: would flip that verdict, so a task
    #   that should have halted the host (per failed_when:) could let
    #   later batch steps run anyway, executing real side effects on the
    #   target that should never have happened. Excluding these tasks
    #   from batches entirely avoids the whole class of bug.
    private def self.breaks_run?(task : Task) : Bool
      structural_or_dynamic?(task) || needs_controller_control_flow?(task) ||
        !!task.delegate_to || !!task.connection || task.run_once || retroactive_verdict?(task) ||
        produces_ansible_facts?(task) || runs_as_action_plugin?(task) ||
        reconfigures_firewall?(task)
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
    # Always its own group sidesteps the whole class of bug, the same
    # way produces_ansible_facts? does for getent:/set_fact:.
    private def self.runs_as_action_plugin?(task : Task) : Bool
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
      !!(task.loop_items || task.loop_fileglob || task.loop_template_kind ||
        task.until_condition || task.async_seconds)
    end

    private def self.retroactive_verdict?(task : Task) : Bool
      !!(task.changed_when || task.failed_when)
    end

    # Conservative (over-inclusive, never under-inclusive) whole-word
    # scan for whether *task* references any register: name introduced
    # earlier in the current run, whether the reference is `{{ }}`-
    # wrapped (params:) or bare (when: is a raw Jinja expression, no
    # `{{ }}` wrapper). A false positive here just ends the run one task
    # early (still correct, just slightly less batching); a false
    # negative would be a real data-dependency bug, so every place a
    # task's own text could plausibly reference a variable is scanned:
    # when_condition and every params: value (changed_when:/failed_when:
    # don't need scanning here since tasks that have either already end
    # the run via breaks_run? above).
    private def self.references_register?(task : Task, seen : Hash(String, Regex)) : Bool
      return false if seen.empty?

      haystacks = [] of String
      haystacks << task.when_condition.to_s if task.when_condition
      task.params.each_value { |v| haystacks << v }

      seen.each_value.any? do |pattern|
        haystacks.any?(&.matches?(pattern))
      end
    end
  end
end
