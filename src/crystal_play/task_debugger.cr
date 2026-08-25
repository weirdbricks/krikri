require "json"
require "./playbook_parser"

module CrystalPlay
  # `debugger:` - drop into an interactive prompt when a task reaches the
  # configured condition (always / never / on_failed / on_skipped /
  # on_unreachable).
  #
  # Real Ansible's debugger reads from stdin even when it is NOT a
  # terminal, unlike vars_prompt (verified against ansible-core 2.19.4:
  # piping "c" continues the run; closing stdin yields "User interrupted
  # execution" and exit 99). Both are reproduced.
  #
  # Supported commands are the ones that do not require evaluating
  # arbitrary Python against a live task object: p/print to inspect,
  # r/redo to re-run the task, c/continue, and q/quit. Real Ansible also
  # lets you ASSIGN to task_vars/task args from the prompt; that is not
  # offered here rather than half-offered.
  module TaskDebugger
    # Exit code real Ansible uses when the debugger is left by EOF or
    # quit - its generic "user interrupted execution" code.
    INTERRUPTED_EXIT = 99

    enum Outcome
      Continue
      Redo
    end

    def self.triggered?(setting : String?, result : JSON::Any) : Bool
      return false unless setting

      case setting
      when "always" then true
      when "never"  then false
      when "on_failed"
        result["failed"]?.try(&.as_bool?) == true
      when "on_skipped"
        result["skipped"]?.try(&.as_bool?) == true
      when "on_unreachable"
        result["unreachable"]?.try(&.as_bool?) == true
      else false
      end
    end

    # Runs the prompt loop. Returns whether the caller should re-run the
    # task; quitting or EOF exits the process, as real Ansible does.
    def self.run(task_name : String, host_name : String,
                 result : JSON::Any, vars : Hash(String, JSON::Any)) : Outcome
      loop do
        print "[#{host_name}] TASK: #{task_name} (debug)> "

        line = STDIN.gets
        unless line
          # EOF - real Ansible prints exactly this and exits 99.
          puts "User interrupted execution"
          exit INTERRUPTED_EXIT
        end

        command, _, argument = line.strip.partition(' ')
        case command
        when "c", "continue" then return Outcome::Continue
        when "r", "redo"     then return Outcome::Redo
        when "q", "quit"
          puts "User interrupted execution"
          exit INTERRUPTED_EXIT
        when "", "h", "help"
          puts "p <name>  print a variable (or 'result')   r  redo the task"
          puts "c         continue                          q  quit"
        when "p", "print"
          puts describe(argument.strip, result, vars)
        else
          puts "Unknown command: #{command} (try h)"
        end
      end
    end

    private def self.describe(name : String, result : JSON::Any, vars : Hash(String, JSON::Any)) : String
      return result.to_json if name.empty? || name == "result" || name == "task.result"

      lookup = name.lchop("vars.").lchop("task_vars.")
      vars[lookup]?.try(&.to_json) || "undefined"
    end
  end
end
