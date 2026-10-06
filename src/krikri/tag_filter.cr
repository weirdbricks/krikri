require "./playbook_parser"

module Krikri
  # Ansible's `--tags`/`--skip-tags` selection, including the four
  # special tag names and the two magic task tags. Previously this was a
  # single line in krikri-playbook.cr - `task.tags.any? { |t| tags.includes?(t) }`,
  # applied only when --tags was passed and only to TOP-LEVEL tasks -
  # which got five distinct things wrong (all verified against a
  # ansible-core 2.19.4):
  #
  #   * `tags: never` was ignored, so a task the author explicitly marked
  #     never-run-unless-asked RAN on an ordinary no-tags invocation. That
  #     tag exists precisely to guard destructive/manual-only tasks.
  #   * `tags: always` was ignored, so an always-task did NOT run under
  #     `--tags something-else`.
  #   * `--tags all` / `tagged` / `untagged` were treated as literal tag
  #     names, matching nothing - `--tags all` ran the entire play as
  #     zero tasks.
  #   * a block's tags were not inherited by its children, and children
  #     were never filtered at all: `--tags alpha` where alpha sits on a
  #     task INSIDE a block ran nothing, because the block itself did not
  #     carry `alpha`.
  #   * `--skip-tags` did not exist.
  module TagFilter
    # Selection rules, from Ansible's own semantics:
    #
    #   no --tags            -> everything EXCEPT `never`
    #   --tags all           -> everything EXCEPT `never`
    #   --tags tagged        -> every task carrying at least one tag
    #   --tags untagged      -> every task carrying no tags
    #   --tags X             -> tasks whose tags include X
    #   tags: always         -> runs regardless of --tags ...
    #   tags: never          -> runs ONLY when one of its own tags is
    #                           named explicitly (`never` itself counts)
    #
    # --skip-tags is applied AFTER the above and wins, including over
    # `always` (Ansible lets `--skip-tags always` drop those too).
    def self.apply(tasks : Array(Task), only : Array(String), skip : Array(String), play_tags : Array(String) = [] of String, keep_static_imports : Bool = false) : Array(Task)
      kept = Array(Task).new
      tasks.each do |task|
        if selected = filter(task, only, skip, play_tags, keep_static_imports)
          kept << selected
        end
      end
      kept
    end

    # Returns the task (with its nested lists filtered in place) if it
    # survives selection, or nil if it is filtered out. *inherited* is the
    # union of the play's own tags and every enclosing block's tags -
    # Ansible pushes a play's tags and a block's tags down onto
    # their children rather than treating the block as an atomic unit.
    private def self.filter(task : Task, only : Array(String), skip : Array(String), inherited : Array(String), keep_static_imports : Bool) : Task?
      # The task's own context for anything IT loads at run time
      # (include_tasks:/include_role: statements): everything outside the
      # task, never its own declared tags. Merged with whatever a previous
      # pass already recorded (a roles:/import_ * invocation's tags are
      # stamped onto its tasks before the play list is filtered), and
      # recomputed identically on every pass - the union is idempotent.
      context = (inherited + task.inherited_tags).uniq
      task.inherited_tags = context
      effective = (task.tags + context).uniq

      # A static import_role: is transparent when RUNNING: real Ansible
      # has no statement to select at all (its tags are pushed down onto
      # each role task at load time instead), so the statement itself
      # must never be dropped by --tags/--skip-tags - doing so used to
      # skip the ENTIRE role under any --tags the bare statement didn't
      # carry. The loaded role tasks are re-filtered at run time with
      # this context as their inherited set. --list-tasks keeps its old
      # statement-level selection (it cannot expand the role anyway), so
      # only the execution paths pass keep_static_imports: true.
      return task if keep_static_imports && task.include_role? && task.is_static_import?

      if task.block?
        block_tasks = filter_list(task.block_tasks, only, skip, effective, keep_static_imports)
        rescue_tasks = filter_list(task.rescue_tasks, only, skip, effective, keep_static_imports)
        always_tasks = filter_list(task.always_tasks, only, skip, effective, keep_static_imports)

        # A block with nothing left to run disappears entirely - keeping
        # it would print a banner for an empty block.
        return nil if block_tasks.nil? && rescue_tasks.nil? && always_tasks.nil?

        task.block_tasks = block_tasks
        task.rescue_tasks = rescue_tasks
        task.always_tasks = always_tasks
        return task
      end

      selected?(effective, only, skip) ? task : nil
    end

    private def self.filter_list(tasks : Array(Task)?, only : Array(String), skip : Array(String), inherited : Array(String), keep_static_imports : Bool) : Array(Task)?
      return nil unless tasks

      kept = Array(Task).new
      tasks.each do |task|
        if selected = filter(task, only, skip, inherited, keep_static_imports)
          kept << selected
        end
      end
      kept.empty? ? nil : kept
    end

    private def self.selected?(effective : Array(String), only : Array(String), skip : Array(String)) : Bool
      return false if skipped?(effective, skip)
      return true if effective.includes?("always")

      # `never` only runs when one of the task's own tags is asked for by
      # name - a bare `--tags all` (or no --tags at all) must not pull it in.
      if effective.includes?("never")
        return only.any? { |tag| effective.includes?(tag) }
      end

      return true if only.empty?
      return true if only.includes?("all")
      return true if only.includes?("tagged") && !effective.empty?
      return true if only.includes?("untagged") && effective.empty?

      only.any? { |tag| effective.includes?(tag) }
    end

    private def self.skipped?(effective : Array(String), skip : Array(String)) : Bool
      return false if skip.empty?
      return true if skip.includes?("all")
      return true if skip.includes?("tagged") && !effective.empty?
      return true if skip.includes?("untagged") && effective.empty?

      skip.any? { |tag| effective.includes?(tag) }
    end
  end
end
