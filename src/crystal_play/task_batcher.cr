require "./playbook_parser"

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
        !!task.delegate_to || task.run_once || retroactive_verdict?(task)
    end

    private def self.structural_or_dynamic?(task : Task) : Bool
      task.block? || task.include_tasks? || task.include_role?
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
