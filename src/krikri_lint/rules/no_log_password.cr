module Krikri
  module Lint
    # Upstream parity: ansible-lint's no-log-password (severity LOW, tags
    # autofix/opt-in/security/experimental). A looped task that takes a
    # password-carrying argument logs each iteration's value unless it
    # sets no_log, so upstream flags any such task that does not.
    #
    # The argument name is matched as a substring, not an exact key:
    # `user_password` and `url_password` count too. `passwd`, `secret`
    # and an unlooped password task are deliberately quiet upstream.
    class NoLogPasswordRule < Rule
      # Ansible parses these modules' free-form string into _raw_params, so
      # a `password=` token in one is part of a command line, never an
      # argument name. Everything else is k=v parsed into real parameters.
      RAW_PARAM_MODULES = %w[
        command raw script shell win_command win_shell
        ansible.builtin.command ansible.builtin.raw ansible.builtin.script
        ansible.builtin.shell ansible.windows.win_command
        ansible.windows.win_shell
      ]

      # ansible's BOOLEANS_TRUE/BOOLEANS_FALSE: the only values
      # convert_to_boolean accepts once lowercased.
      BOOLEAN_TRUE  = %w[t true yes on 1]
      BOOLEAN_FALSE = %w[f false no off 0]

      # YAML 1.1 plain scalars that resolve to None, and so reach Python's
      # boolean() as an unusable value.
      NULL_VALUES = %w[~ null]

      private enum NoLog
        Absent
        Falsy
        Truthy
        Jinja
        Unusable
      end

      def id : String
        "no-log-password"
      end

      def severity : Severity
        Severity::LOW
      end

      def tags : Array(String)
        ["autofix", "opt-in", "security", "experimental"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Task-oriented: violations belong to an enclosing task, so a
      # `# noqa:` anywhere in that task's body suppresses them.
      def task_scoped? : Bool
        true
      end

      def fixable? : Bool
        true
      end

      # Upstream's transform sets the task's no_log and marks the match
      # fixed, so no "not applied" is logged for it.
      def transformable? : Bool
        true
      end

      def marks_fixed?(violation : Violation) : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        matches = [] of Violation
        TaskWalker.each_task(file) do |task|
          next unless password_argument?(task)
          case no_log_state(task)
          when NoLog::Jinja, NoLog::Truthy
            next
          when NoLog::Unusable
            # convert_to_boolean raises on an unrecognized no_log value,
            # and upstream's runner discards every match matchtasks had
            # already produced, so the file reports none of them.
            return
          end
          next unless looped?(task)
          # Upstream reports this rule at the task line with no column.
          matches << Violation.new(file.path, task.line, 0, id, severity,
            "Password should not be logged.", task.line)
        end
        violations.concat(matches)
      end

      # Upstream appends `no_log: true` to the task, or overwrites the
      # falsy value already written there.
      def fix(buffer : FixBuffer, file : PositionedFile, violation : Violation) : Bool
        TaskWalker.each_task(file) do |task|
          next unless task.line == violation.line
          if entry = NodeUtil.entry(task.node, "no_log")
            return replace_no_log(buffer, entry[1])
          end
          last = task.end_line(YamlText.scalar_continuation_lines(file))
          return buffer.insert_after(last,
            "#{" " * (task.action_column - 1)}no_log: true")
        end
        false
      end

      private def replace_no_log(buffer : FixBuffer, value : YAML::Nodes::Node) : Bool
        line = NodeUtil.line(value)
        text = buffer.line_text(line) || return false
        span = FixSpan.scalar_span(text, NodeUtil.column(value)) || return false
        buffer.replace_span(line, span[0] + 1, span[1] - span[0], "true")
      end

      # Upstream's has_password: any action argument whose *name* contains
      # "password", unless ansible.builtin.user is given a truthy
      # password_lock and no password (password_lock's own name would
      # otherwise match).
      private def password_argument?(task : LintTask) : Bool
        arguments = arguments(task)
        if user_action?(task) &&
           arguments.fetch("password_lock", false) &&
           !arguments.fetch("password", false)
          return false
        end
        arguments.each_key.any? { |name| name.includes?("password") }
      end

      # The task's action arguments as upstream's normalized action dict
      # has them: the `args:` mapping first (lower priority), then the
      # module's own parameters. Values keep only their raw truthiness,
      # which is all the user/password_lock special case needs.
      private def arguments(task : LintTask) : Hash(String, Bool)
        arguments = {} of String => Bool
        if (args = task.args_node.as?(YAML::Nodes::Mapping))
          add_mapping(arguments, args)
        end
        case action = task.action_node
        when YAML::Nodes::Mapping
          NodeUtil.each_entry(action) do |key, value|
            name = NodeUtil.scalar_value(key) || next
            next if name == "module" && task.alias_action?
            arguments[name] = truthy_node?(value)
          end
        when YAML::Nodes::Scalar
          unless raw_param_module?(task)
            free_form_arguments(action.value || "").each do |name, truthy|
              arguments[name] = truthy
            end
          end
        end
        arguments
      end

      private def add_mapping(arguments : Hash(String, Bool), mapping : YAML::Nodes::Mapping) : Nil
        NodeUtil.each_entry(mapping) do |key, value|
          name = NodeUtil.scalar_value(key) || next
          arguments[name] = truthy_node?(value)
        end
      end

      # parse_kv's shape: `key=value` tokens name parameters, everything
      # else accumulates into _raw_params (which never contains
      # "password" as an argument name).
      private def free_form_arguments(text : String) : Hash(String, Bool)
        arguments = {} of String => Bool
        text.split(/\s+/).each do |token|
          position = token.index('=') || next
          next unless position > 0
          name = token[0...position].strip
          arguments[name] = !token[(position + 1)..].empty?
        end
        arguments
      end

      private def raw_param_module?(task : LintTask) : Bool
        RAW_PARAM_MODULES.includes?(task.module_name)
      end

      private def user_action?(task : LintTask) : Bool
        task.module_name == "ansible.builtin.user"
      end

      # Upstream's has_loop: a `loop:` key or any `with_*` key.
      private def looped?(task : LintTask) : Bool
        NodeUtil.each_entry(task.node) do |key, _value|
          name = NodeUtil.scalar_value(key) || next
          return true if name == "loop" || name.starts_with?("with_")
        end
        false
      end

      private def no_log_state(task : LintTask) : NoLog
        entry = NodeUtil.entry(task.node, "no_log") || return NoLog::Absent
        text = NodeUtil.scalar_value(entry[1]) || return NoLog::Unusable
        # Upstream never evaluates Jinja, so a templated no_log is simply
        # not a match.
        return NoLog::Jinja if text.starts_with?("{{") && text.ends_with?("}}")
        normalized = text.strip.downcase
        return NoLog::Truthy if BOOLEAN_TRUE.includes?(normalized)
        return NoLog::Falsy if BOOLEAN_FALSE.includes?(normalized)
        NoLog::Unusable
      end

      # Python truthiness of a raw YAML value (not Ansible's boolean
      # conversion): a quoted "false" is a non-empty string and therefore
      # truthy, which is how upstream's password_lock check reads it.
      private def truthy_node?(node : YAML::Nodes::Node) : Bool
        case node
        when YAML::Nodes::Scalar
          text = node.value || ""
          return !text.empty? unless node.style == YAML::ScalarStyle::PLAIN
          normalized = text.strip
          return false if normalized.empty? || NULL_VALUES.includes?(normalized.downcase)
          return false if BOOLEAN_FALSE.includes?(normalized.downcase)
          !zero_number?(normalized)
        when YAML::Nodes::Sequence
          !node.nodes.empty?
        when YAML::Nodes::Mapping
          !node.nodes.empty?
        else
          true
        end
      end

      # Plain floats parse to Python floats, whose zero is falsy.
      private def zero_number?(text : String) : Bool
        text == "0" || text == "0.0" || text == "-0" || text == "-0.0" ||
          text == "+0" || text == "+0.0"
      end
    end
  end
end
