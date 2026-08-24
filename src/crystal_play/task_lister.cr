require "./playbook_parser"
require "./tag_filter"

module CrystalPlay
  # `--list-tasks` and `--syntax-check`, reproducing real
  # ansible-playbook's own output shape. Every detail below was captured
  # from a real ansible-core 2.19.4 run rather than invented:
  #
  #     \nplaybook: p.yml\n
  #     \n  play #1 (localhost): First play\tTAGS: []
  #         tasks:
  #           plain task\tTAGS: []
  #           tagged task\tTAGS: [alpha, beta]
  #           inner task\tTAGS: [inner, outer]
  #
  # Non-obvious specifics it matches:
  #   * tags are sorted alphabetically, not listed in source order, and a
  #     task's own tags are unioned with every enclosing block's
  #   * a task inside a block IS listed, but tasks under that block's
  #     `always:` are NOT
  #   * a role's tasks are listed as "rolename : taskname"
  #   * --tags/--skip-tags filter the listing, and a play left with no
  #     tasks still prints its header and its bare "tasks:" line
  #   * the separator between the name and TAGS is a literal TAB
  module TaskLister
    def self.syntax_check(playbook : Playbook) : Nil
      # A parse failure never reaches here - crystal-play.cr's own parse
      # rescue has already reported it and exited 4, which is exactly
      # what real ansible-playbook does for --syntax-check on a broken
      # playbook. So reaching this point IS the success case.
      puts ""
      puts "playbook: #{playbook.path}"
    end

    def self.list_tasks(playbook : Playbook, only : Array(String), skip : Array(String)) : Nil
      puts ""
      puts "playbook: #{playbook.path}"

      playbook.plays.each_with_index do |play, index|
        puts ""
        puts "  play ##{index + 1} (#{host_pattern(play)}): #{play.name}\tTAGS: [#{play.tags.sort.join(", ")}]"
        puts "    tasks:"

        TagFilter.apply(play.tasks, only, skip).each do |task|
          emit(task, [] of String)
        end
      end
    end

    private def self.host_pattern(play : Play) : String
      hosts = play.hosts
      hosts.is_a?(Array) ? hosts.join(",") : hosts
    end

    private def self.emit(task : Task, inherited : Array(String)) : Nil
      effective = (task.tags + inherited).uniq

      if task.block?
        # Real Ansible lists a block's body but NOT its always: tasks
        # (verified: an `always:` entry never appears in --list-tasks
        # output). rescue: is likewise absent from the listing.
        (task.block_tasks || [] of Task).each { |nested| emit(nested, effective) }
        return
      end

      puts "      #{display_name(task)}\tTAGS: [#{effective.sort.join(", ")}]"
    end

    private def self.display_name(task : Task) : String
      if (role_name = task.role_name) && !role_name.empty?
        "#{role_name} : #{task.name}"
      else
        task.name
      end
    end
  end
end
