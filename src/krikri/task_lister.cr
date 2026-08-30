require "./playbook_parser"
require "./tag_filter"

module Krikri
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
      # A parse failure never reaches here - krikri-playbook.cr's own parse
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

    # --list-tags: one line per play with the sorted union of every tag
    # on every task in it (block tags included, via the same inheritance
    # --list-tasks uses).
    def self.list_tags(playbook : Playbook, only : Array(String), skip : Array(String)) : Nil
      puts ""
      puts "playbook: #{playbook.path}"

      playbook.plays.each_with_index do |play, index|
        puts ""
        puts "  play ##{index + 1} (#{host_pattern(play)}): #{play.name}\tTAGS: [#{play.tags.sort.join(", ")}]"

        tags = [] of String
        TagFilter.apply(play.tasks, only, skip).each do |task|
          collect_tags(task, [] of String, tags)
        end
        puts "      TASK TAGS: [#{tags.uniq.sort!.join(", ")}]"
      end
    end

    # --list-hosts: the play's host pattern, then the hosts it matches,
    # sorted. *resolve* is handed in rather than an Inventory so this
    # module keeps its single dependency on the parser.
    def self.list_hosts(playbook : Playbook, & : Play -> Array(String)) : Nil
      puts ""
      puts "playbook: #{playbook.path}"

      playbook.plays.each_with_index do |play, index|
        puts ""
        puts "  play ##{index + 1} (#{host_pattern(play)}): #{play.name}\tTAGS: [#{play.tags.sort.join(", ")}]"
        # Real Ansible prints the pattern as a Python list repr, e.g.
        # `pattern: ['web']` - verified against ansible-core 2.19.4.
        puts "    pattern: [#{pattern_list(play).map { |entry| "'#{entry}'" }.join(", ")}]"

        names = yield(play)
        puts "    hosts (#{names.size}):"
        names.sort.each { |name| puts "      #{name}" }
      end
    end

    private def self.pattern_list(play : Play) : Array(String)
      hosts = play.hosts
      hosts.is_a?(Array) ? hosts : hosts.split(",").map(&.strip).reject(&.empty?)
    end

    private def self.collect_tags(task : Task, inherited : Array(String), into : Array(String)) : Nil
      effective = (task.tags + inherited).uniq

      if task.block?
        (task.block_tasks || [] of Task).each { |nested| collect_tags(nested, effective, into) }
        (task.rescue_tasks || [] of Task).each { |nested| collect_tags(nested, effective, into) }
        (task.always_tasks || [] of Task).each { |nested| collect_tags(nested, effective, into) }
        return
      end

      effective.each { |tag| into << tag }
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
