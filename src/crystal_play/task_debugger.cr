require "json"
require "./playbook_parser"
require "./variable_substitutor"

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
  # Commands: p/print, r/redo, c/continue, q/quit, u/update_task, EOF,
  # and ASSIGNMENT to `task.args[...]` / `task_vars[...]`.
  #
  # Real Ansible implements assignment by `exec`-ing the typed line as
  # Python against a live scope dict, which this engine has no equivalent
  # of. What it does instead is parse the two assignment SHAPES that make
  # the debugger useful - `task.args['x'] = <literal>` and
  # `task_vars['y'] = <literal>` - and apply them to the real task/vars,
  # so the documented workflow (fix a wrong argument, `r`, watch it pass)
  # works. Arbitrary Python beyond that shape is still refused rather
  # than silently ignored: an unparseable assignment says so.
  #
  # The interaction between the two, verified against real ansible-core
  # 2.19.4 rather than assumed, is subtle and reproduced exactly:
  #
  #   * `task.args[...] = v` takes effect on the very next `r`.
  #   * `task_vars[...] = v` does NOT, on its own, change the task's
  #     arguments - a redo right after it re-runs the ORIGINAL command
  #     (real Ansible's task object is already templated by then). Only
  #     `u`/`update_task` re-templates the task from the updated vars,
  #     which is exactly what real Ansible's own `do_update_task`
  #     ("Recreate the task from task._ds, and template with updated
  #     task_vars") does.
  module TaskDebugger
    # Exit code real Ansible uses when the debugger is left by EOF or
    # quit - its generic "user interrupted execution" code.
    INTERRUPTED_EXIT = 99

    enum Outcome
      Continue
      Redo
    end

    # An assignment shape this understands: `task.args['key'] = value` or
    # `task_vars['key'] = value`, with either quote style, and with or
    # without the brackets' surrounding whitespace.
    REGEX_ASSIGNMENT = /\A(task\.args|task_vars)\s*\[\s*(?:'([^']*)'|"([^"]*)")\s*\]\s*=\s*(.+)\z/

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
    #
    # *task* is mutated in place for `task.args[...] =` assignments (its
    # `params` are this engine's equivalent - the raw, pre-substitution
    # module arguments). *var_overrides* is the caller's own hash for
    # `task_vars[...] =` assignments: entries land in it only once
    # `u`/`update_task` promotes them, so the caller can merge it into
    # the vars context it builds for a redo and get real Ansible's
    # semantics for free.
    def self.run(task_name : String, host_name : String,
                 result : JSON::Any, vars : Hash(String, JSON::Any),
                 task : Task? = nil,
                 var_overrides : Hash(String, JSON::Any)? = nil) : Outcome
      pending_vars = Hash(String, JSON::Any).new

      loop do
        print "[#{host_name}] TASK: #{task_name} (debug)> "

        line = STDIN.gets
        unless line
          # EOF - real Ansible prints exactly this and exits 99.
          puts "User interrupted execution"
          exit INTERRUPTED_EXIT
        end

        stripped = line.strip
        command, _, argument = stripped.partition(' ')

        case command
        when "c", "continue" then return Outcome::Continue
        when "r", "redo"     then return Outcome::Redo
        when "q", "quit"
          puts "User interrupted execution"
          exit INTERRUPTED_EXIT
        when "u", "update_task"
          # Real Ansible's do_update_task: re-template the task with the
          # updated task_vars. This engine keeps a task's params RAW
          # (substitution happens per execution), so "re-templating" is
          # simply making the pending task_vars edits visible to the next
          # execution - the caller merges var_overrides into the context
          # it builds for the redo.
          if overrides = var_overrides
            pending_vars.each { |key, value| overrides[key] = value }
          end
          pending_vars.each { |key, value| vars[key] = value }
          pending_vars.clear
        when "", "h", "help"
          puts "p <name>  print a variable (or 'result'/'task.args')   r  redo the task"
          puts "c         continue                                     q  quit"
          puts "u         re-template the task from updated task_vars"
          puts "task.args['k'] = <value>   set a module argument"
          puts "task_vars['k'] = <value>   set a variable (needs u)"
        when "p", "print"
          puts describe(argument.strip, result, vars, task)
        else
          unless try_assignment(stripped, task, pending_vars)
            puts "Unknown command: #{command} (try h)"
          end
        end
      end
    end

    # Applies `task.args['k'] = v` / `task_vars['k'] = v`. Returns false
    # when *line* is not an assignment at all (the caller then reports an
    # unknown command), and true once it has been handled - including
    # when the VALUE could not be parsed, which reports its own error
    # rather than being silently dropped.
    private def self.try_assignment(line : String, task : Task?,
                                    pending_vars : Hash(String, JSON::Any)) : Bool
      match = REGEX_ASSIGNMENT.match(line)
      return false unless match

      target = match[1]
      key = match[2]? || match[3]? || ""
      raw_value = match[4].strip

      value = parse_literal(raw_value)
      unless value
        # Real Ansible would raise a Python exception here; this reports
        # the same refusal in this engine's own terms rather than
        # pretending the assignment took.
        puts "***ValueError: cannot parse #{raw_value} (expected a quoted string, number, boolean, None, or JSON)"
        return true
      end

      if target == "task.args"
        if real_task = task
          # A task's params are raw strings here (the executor
          # substitutes them per execution), so a structured value is
          # stored in its JSON form - the same text the parser would
          # have produced for that literal in YAML.
          real_task.params[arg_key_for(real_task, key)] = value.as_s? || value.to_json
        else
          puts "***RuntimeError: no task in scope"
        end
      else
        pending_vars[key] = value
      end

      true
    end

    # Real Ansible calls a command:/shell: task's free-form argument
    # `_raw_params`, which is what someone at this prompt will type from
    # muscle memory (and what its own `p task.args` shows). This engine
    # stores that same argument under `cmd` for the RAW_COMMAND_MODULES
    # (see PlaybookParser.parse_adhoc_params), so an assignment to
    # `_raw_params` would otherwise set a key the command plugin never
    # reads - the assignment appearing to work while changing nothing.
    # Aliased rather than renamed: the engine's own key still works too,
    # and only a task that actually HAS `cmd` (and no `_raw_params` of
    # its own) is redirected.
    private def self.arg_key_for(task : Task, key : String) : String
      return key unless key == "_raw_params"
      return key if task.params.has_key?("_raw_params")
      task.params.has_key?("cmd") ? "cmd" : key
    end

    # The literal forms real playbook authors actually type at this
    # prompt: a quoted string (either quote style), an integer, a float,
    # a boolean in Python's or YAML's spelling, None/null, and any JSON
    # array/object. Anything else returns nil and is refused.
    private def self.parse_literal(text : String) : JSON::Any?
      if (text.starts_with?('\'') && text.ends_with?('\'') && text.size >= 2) ||
         (text.starts_with?('"') && text.ends_with?('"') && text.size >= 2)
        return JSON::Any.new(text[1..-2])
      end

      case text
      when "True", "true"   then return JSON::Any.new(true)
      when "False", "false" then return JSON::Any.new(false)
      when "None", "null"   then return JSON::Any.new(nil)
      end

      if int_value = text.to_i64?
        return JSON::Any.new(int_value)
      end

      if float_value = text.to_f64?
        return JSON::Any.new(float_value)
      end

      if text.starts_with?('[') || text.starts_with?('{')
        return (JSON.parse(text) rescue nil)
      end

      nil
    end

    private def self.describe(name : String, result : JSON::Any,
                              vars : Hash(String, JSON::Any), task : Task? = nil) : String
      return result.to_json if name.empty? || name == "result" || name == "task.result"

      if name == "task.args" || name == "task.params"
        params = task.try(&.params) || Hash(String, String).new
        # Real Ansible's `p task.args` shows the TEMPLATED arguments (its
        # task object is already post-validated by the time the debugger
        # opens). This engine keeps params raw and substitutes per
        # execution, so they are rendered here against the same vars the
        # next redo would use - otherwise `p task.args` after a
        # `task_vars[...] =` + `u` would still show `{{ msg_text }}`
        # where real Ansible shows the value it just picked up, making
        # the one command whose whole purpose is to confirm the edit
        # unable to confirm it.
        substitutor = VarSubstitutor.new(vars: vars)
        rendered = params.transform_values { |value| (substitutor.substitute(value) rescue value) }
        return rendered.to_json
      end

      lookup = name.lchop("vars.").lchop("task_vars.")
      vars[lookup]?.try(&.to_json) || "undefined"
    end
  end
end
