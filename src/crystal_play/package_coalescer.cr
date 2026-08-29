require "./playbook_parser"

module CrystalPlay
  # OPUS_PERFORMANCE_IMPROVEMENTS.md item 11 - "coalesce package tasks".
  # BREAKING, so reachable only from `crystal-ansible-fast`.
  #
  # Every `apt`/`dnf`/`yum`/`package` invocation carries seconds of fixed
  # cost - lock acquisition, cache read, dependency solve, trigger
  # processing - and roles routinely do five to fifteen of them. The
  # package modules already accept a comma-separated list and install it
  # as ONE transaction, so a run of consecutive installs can be merged
  # into a single call.
  #
  # ## What breaks, and why this cannot be the default
  #
  # - **Ordering.** Merged packages are installed in one solve, so a
  #   package that only works after an earlier one is configured may
  #   behave differently.
  # - **Per-task `changed`.** The whole group's work happens at the
  #   leader, so the followers report `ok`/unchanged even when their own
  #   package was in fact installed. The task COUNT is preserved (so the
  #   recap still has the same shape) but the changed attribution moves.
  # - **Handler firing granularity.** A follower that would have fired a
  #   handler by being `changed` no longer does - which is why any task
  #   carrying `notify:` is excluded outright below.
  #
  # ## What is excluded, and why
  #
  # The eligibility rules are deliberately as conservative as
  # `TaskBatcher.plan`'s: anything whose behaviour could depend on
  # running separately is left alone.
  module PackageCoalescer
    COALESCABLE_MODULES = %w[apt dnf yum package]

    # Params that must match across the whole group for a merge to mean
    # the same thing. Anything outside this set (and `name`) present on
    # a task disqualifies it - an unknown param might change semantics.
    SHARED_PARAMS = %w[state update_cache cache_valid_time install_recommends force]

    record Group, leader : Task, members : Array(Task), names : Array(String)

    # Maps every member of a coalescable run to its Group. The leader
    # maps to itself, so a caller can ask "am I the leader" by identity.
    def self.plan(tasks : Array(Task)) : Hash(Task, Group)
      result = Hash(Task, Group).new
      run = [] of Task

      flush = -> do
        # A run of one is not a merge - leave it entirely alone so the
        # ordinary path handles it unchanged.
        if run.size > 1
          names = [] of String
          run.each { |task| names.concat(package_names(task)) }
          names.uniq!
          group = Group.new(run.first, run.dup, names)
          run.each { |task| result[task] = group }
        end
        run = [] of Task
      end

      tasks.each do |task|
        if eligible?(task) && (run.empty? || compatible?(run.first, task))
          run << task
        else
          flush.call
          run << task if eligible?(task)
        end
      end
      flush.call

      result
    end

    def self.eligible?(task : Task) : Bool
      COALESCABLE_MODULES.includes?(task.module_name.split('.').last) &&
        !observable_on_its_own?(task) && plain_literal_install?(task) &&
        only_shared_params?(task)
    end

    # Anything that makes the task's execution conditional, repeated, or
    # individually observable - every one of these is a way the merge
    # could change what the play does, not just when it does it.
    private def self.observable_on_its_own?(task : Task) : Bool
      result_observed?(task) || control_flow_sensitive?(task)
    end

    # The task's own verdict is looked at by something: registered into
    # a variable, used to fire a handler, or rewritten by
    # changed_when:/failed_when:. A follower reports unchanged, so any
    # of these would silently change the play's behaviour.
    private def self.result_observed?(task : Task) : Bool
      return true if task.register
      return true if (notify = task.notify) && !notify.empty?
      !!(task.changed_when || task.failed_when || task.ignore_errors)
    end

    # The task might not run, might run more than once, or might run
    # somewhere else - so "the leader already did it" is not true.
    private def self.control_flow_sensitive?(task : Task) : Bool
      return true if task.when_condition
      return true if task.loop_items || task.loop || task.loop_fileglob
      return true if task.until_condition || task.async_seconds
      return true if task.delegate_to || task.connection || task.run_once
      !!(task.block_tasks || task.rescue_tasks || task.always_tasks)
    end

    # A templated name is resolved per host at run time, so merging text
    # that has not been rendered yet would produce nonsense. And only
    # plain installs merge - absent/latest carry their own ordering
    # hazards and are rarer in the hot path.
    private def self.plain_literal_install?(task : Task) : Bool
      names = task.params["name"]? || task.params["pkg"]?
      return false unless names
      return false if names.includes?("{{")

      state = task.params["state"]? || "present"
      state == "present" || state == "installed"
    end

    # An unrecognised param might change semantics, so its presence
    # disqualifies rather than being ignored.
    private def self.only_shared_params?(task : Task) : Bool
      task.params.each_key.all? do |key|
        key == "name" || key == "pkg" || SHARED_PARAMS.includes?(key)
      end
    end

    # Two eligible tasks can share a transaction only if every shared
    # param agrees and they are the same module and privilege.
    private def self.compatible?(a : Task, b : Task) : Bool
      return false unless a.module_name.split('.').last == b.module_name.split('.').last
      return false unless a.become == b.become && a.become_user == b.become_user
      SHARED_PARAMS.all? { |key| a.params[key]? == b.params[key]? }
    end

    def self.package_names(task : Task) : Array(String)
      raw = task.params["name"]? || task.params["pkg"]? || ""
      raw.split(',').map(&.strip).reject(&.empty?)
    end
  end
end
