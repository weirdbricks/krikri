module Krikri
  module Lint
    # Upstream parity: ansible-lint's risky-octal (severity VERY_HIGH,
    # tags formatting). Flags integer mode values that were meant as
    # octal (e.g. mode: 755) by checking the same sanity conditions
    # upstream's is_invalid_permission uses.
    class RiskyOctalRule < Rule
      # Upstream sees these as Python True after YAML 1.1 resolution
      # (PyYAML/ruamel's resolver has no single-letter y/n). A True mode
      # is 1, a False mode is 0 - both isinstance int to the rule.
      YAML11_BOOL_TRUE  = %w[yes Yes YES true True TRUE on On ON]
      YAML11_BOOL_FALSE = %w[no No NO false False FALSE off Off OFF]

      MODULES = %w[
        assemble copy file ini_file lineinfile replace synchronize
        template unarchive
      ]

      def id : String
        "risky-octal"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["formatting"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      # Task-oriented: violations belong to an enclosing task, so a
      # `# noqa:` anywhere in that task's body suppresses them.
      def task_scoped? : Bool
        true
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          next unless MODULES.includes?(task.bare_module)
          mode_node = mode_value_node(task) || next
          next unless mode_node.is_a?(YAML::Nodes::Scalar)
          resolved = resolve_mode(mode_node) || next
          mode = resolved[0]
          next unless invalid_permission?(mode)
          violations << Violation.new(
            file.path, task.line, 0, id, severity,
            "`mode: #{resolved[1]}` should have a string value with leading zero `mode: \"0#{mode.to_s(8)}\"` or use symbolic mode.",
            task.line
          )
        end
      end

      private def mode_value_node(task : LintTask) : YAML::Nodes::Node?
        action = task.action_node.as?(YAML::Nodes::Mapping) || return nil
        if (entry = NodeUtil.entry(action, "mode"))
          entry[1]
        end
      end

      # Resolves the scalar the way upstream's YAML loader (ruamel, YAML
      # 1.1 semantics) does before the rule sees it: an unquoted scalar
      # can become a bool (yes/no/true/false/on/off, never y/n) or an
      # integer (binary, hex, 0o- and leading-zero octal, decimal, and
      # the 1.1 sexagesimal "1:2:3" form), while quoted scalars, floats,
      # null and anything unparseable stay strings. The message renders
      # Python's str() of the value, so booleans print True/False and
      # '+622' prints as 622.
      private def resolve_mode(node : YAML::Nodes::Scalar) : {Int64, String}?
        return nil unless node.style == YAML::ScalarStyle::PLAIN
        value = node.value
        return nil unless value
        return {1i64, "True"} if YAML11_BOOL_TRUE.includes?(value)
        return {0i64, "False"} if YAML11_BOOL_FALSE.includes?(value)
        int = yaml11_int?(value) || return nil
        {int, int.to_s}
      end

      private def yaml11_int?(value : String) : Int64?
        sign = 1i64
        body = value
        if body.starts_with?('-')
          sign = -1i64
          body = body[1..]
        elsif body.starts_with?('+')
          body = body[1..]
        end
        body = body.delete('_')
        int = if body.starts_with?("0b") && body[2..].matches?(/^[01]+$/)
                body[2..].to_i64?(2)
              elsif body.starts_with?("0x") && body[2..].matches?(/^[0-9a-fA-F]+$/)
                body[2..].to_i64?(16)
              elsif body.starts_with?("0o") && body[2..].matches?(/^[0-7]+$/)
                body[2..].to_i64?(8)
              elsif body.starts_with?('0')
                body.matches?(/^[0-7]+$/) ? body.to_i64?(8) : nil
              elsif body.includes?(':') && body.matches?(/^[1-9][0-9]*(:[0-5]?[0-9])+$/)
                body.split(':').reduce(0i64) { |acc, part| acc * 60 + part.to_i64 }
              elsif body.matches?(/^(0|[1-9][0-9]*)$/)
                body.to_i64?
              end
        int ? sign * int : nil
      end

      private def invalid_permission?(mode : Int64) : Bool
        user = py_mod(mode >> 6, 8)
        group = py_mod(mode >> 3, 8)
        other = py_mod(mode, 8)
        user_odd = py_mod(mode >> 6, 2) == 1

        other_write_without_read = other != 0 && other < 4 &&
                                   !(other == 1 && user_odd)
        group_write_without_read = group != 0 && group < 4 &&
                                   !(group == 1 && user_odd)
        user_write_without_read = user != 0 && user < 4 && user != 1

        other_write_without_read || group_write_without_read ||
          user_write_without_read ||
          other > group || other > user || group > user
      end

      # Python's % never goes negative; Crystal's keeps the dividend's
      # sign, so a negative mode would otherwise classify differently.
      private def py_mod(value : Int64, modulus : Int64) : Int64
        ((value % modulus) + modulus) % modulus
      end
    end
  end
end
