require "./playbook_parser"

module CrystalPlay
  # `--start-at-task=NAME`: skip everything before the first task whose
  # name matches NAME, then run the rest of the playbook normally -
  # including every later play. Verified against ansible-core 2.19.4:
  #
  #   * tasks before the match are not run and are NOT counted in the
  #     recap (they are skipped outright, not reported as "skipping:")
  #   * the match is playbook-wide: once found, later plays run in full
  #   * a name that matches nothing runs no task at all and reports
  #     `[ERROR]: No matching task "X" found. Note: --start-at-task can
  #     only follow static includes.` - with exit code 0, not an error code
  module StartAtFilter
    # Returns the tasks to actually run, plus whether the match was found
    # in this play. The caller keeps its own "still looking" state across
    # plays and stops calling once matched.
    def self.apply(tasks : Array(Task), name : String) : {Array(Task), Bool}
      kept = Array(Task).new
      matched = false

      tasks.each do |task|
        if matched
          kept << task
          next
        end

        if task.block?
          # The match may sit INSIDE a block. Real Ansible flattens the
          # play into one task list, so starting at a task inside a block
          # runs the remainder of that block (and its rescue:/always:,
          # which are kept whole once the block is entered).
          nested, found = apply(task.block_tasks || Array(Task).new, name)
          if found
            task.block_tasks = nested
            kept << task
            matched = true
          end
          next
        end

        if task.name == name
          kept << task
          matched = true
        end
      end

      {kept, matched}
    end
  end
end
