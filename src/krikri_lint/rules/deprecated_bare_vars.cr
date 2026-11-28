module Krikri
  module Lint
    # Upstream parity: ansible-lint's deprecated-bare-vars (severity
    # VERY_HIGH, tags deprecations). A `with_*` loop term written as a
    # bare name is a legacy string that Ansible hands to the lookup as-is
    # rather than resolving the variable, so upstream asks for the full
    # `{{ ... }}` syntax. Only `with_*` keywords are inspected: `loop:`
    # and `when:` are expressions, not loop terms, and never match.
    class DeprecatedBareVarsRule < Rule
      # Loops whose terms are a list of variables: upstream wraps a lone
      # term in a list and then examines only its first element (its loop
      # returns on the first iteration, so later terms are never checked).
      PER_ELEMENT = %w[with_nested with_together with_flattened with_filetree
        with_community.general.filetree]

      # Upstream leaves these loops alone entirely.
      SKIPPED = %w[with_sequence with_ini with_inventory_hostnames]

      # Python's `\w`, which RE_IS_FQCN_OR_NAME anchors: one word, or a
      # dotted name with at least two dots. `$` also matches before a
      # final newline, as it does in Python.
      FQCN_OR_NAME = /^\w+(?:\.\w+){2,100}$|^\w+$/

      # Upstream's RE_HAS_JINJA (with re.DOTALL) / RE_HAS_GLOB.
      HAS_JINJA = /(?s)\{[{%#].*[%#}]\}/
      HAS_GLOB  = /[][*?]/

      def id : String
        "deprecated-bare-vars"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["deprecations"]
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
          loop_key = first_loop_key(task) || next
          next if SKIPPED.includes?(loop_key)
          entry = NodeUtil.entry(task.node, loop_key) || next
          value = entry[1]
          next unless bare_term(loop_key, value)
          term = term_repr(value)
          message = "Possible bare variable '#{term}' used in a '#{loop_key}' " \
                    "loop. You should use the full variable syntax " \
                    "('{{ #{term} }}') or convert it to a list if that is " \
                    "not really a variable."
          violations << Violation.new(file.path, task.line, 0, id, severity,
            message, task.line)
        end
      end

      # Upstream iterates the task's keys and takes the first `with_*`
      # one, which is the only loop type Ansible accepts on a task.
      private def first_loop_key(task : LintTask) : String?
        NodeUtil.each_entry(task.node) do |key_node, _|
          key = NodeUtil.scalar_value(key_node)
          return key if key.try(&.starts_with?("with_"))
        end
        nil
      end

      # The post-PyYAML string upstream's _matchvar is handed, or nil
      # when it is anything else (a number, a bool, a mapping, ...).
      private def bare_term(loop_key : String, value : YAML::Nodes::Node) : String?
        text = if loop_key == "with_subelements"
                 subscript_zero(value)
               else
                 checked_term(loop_key, value)
               end
        return nil unless text
        return nil if text.matches?(HAS_JINJA) || !text.matches?(FQCN_OR_NAME)
        # A glob or a trailing directory separator is a path literal, not
        # a variable, for the two loops upstream treats that way.
        return nil if loop_key == "with_fileglob" && text.matches?(HAS_GLOB)
        return nil if loop_key == "with_filetree" && text.ends_with?('/')
        text
      end

      private def checked_term(loop_key : String, value : YAML::Nodes::Node) : String?
        return string_value(value) unless PER_ELEMENT.includes?(loop_key)
        list = value.as?(YAML::Nodes::Sequence)
        return string_value(value) unless list
        first = list.nodes.first? || return nil
        string_value(first)
      end

      # Upstream reads `task[loop_type][0]`: a term list's first element,
      # or a scalar string's first character.
      private def subscript_zero(value : YAML::Nodes::Node) : String?
        if list = value.as?(YAML::Nodes::Sequence)
          first = list.nodes.first? || return nil
          return string_value(first)
        end
        text = string_value(value) || return nil
        text.empty? ? nil : text[0].to_s
      end

      # PyYAML's YAML 1.1 resolution of a plain scalar is already modeled
      # by the args-module rule, so a plain `42`, `true` or `null` term is
      # a non-string here, exactly as upstream's isinstance(str) check
      # sees it. Quoted and block scalars are always strings.
      private def string_value(node : YAML::Nodes::Node) : String?
        return nil unless scalar = node.as?(YAML::Nodes::Scalar)
        value = scalar.value || ""
        return value unless scalar.style == YAML::ScalarStyle::PLAIN
        return nil if ArgsModuleRule::NULL_WORDS.includes?(value)
        return nil if ArgsModuleRule::BOOL_WORDS.includes?(value)
        return nil if value.matches?(ArgsModuleRule::INT_PATTERN) ||
                      value.matches?(ArgsModuleRule::FLOAT_PATTERN)
        value
      end

      # Upstream interpolates Python's str() of the whole loop term, so a
      # term list shows up as its repr: ['my_list', 'keys'].
      private def term_repr(value : YAML::Nodes::Node) : String
        if list = value.as?(YAML::Nodes::Sequence)
          return "[" + list.nodes.map { |item| item_repr(item) }.join(", ") + "]"
        end
        string_value(value) || ""
      end

      private def item_repr(node : YAML::Nodes::Node) : String
        if list = node.as?(YAML::Nodes::Sequence)
          return "[" + list.nodes.map { |item| item_repr(item) }.join(", ") + "]"
        end
        if mapping = node.as?(YAML::Nodes::Mapping)
          return "{" + mapping_repr(mapping) + "}"
        end
        scalar = node.as?(YAML::Nodes::Scalar) || return "None"
        scalar_repr(scalar)
      end

      private def mapping_repr(mapping : YAML::Nodes::Mapping) : String
        pairs = [] of String
        NodeUtil.each_entry(mapping) do |key, value|
          pairs << "#{item_repr(key)}: #{item_repr(value)}"
        end
        pairs.join(", ")
      end

      # Python repr: strings are quoted (single quotes unless the string
      # holds one), while a non-string scalar keeps its own spelling -
      # except bools and nulls, which repr spells True/False/None.
      private def scalar_repr(scalar : YAML::Nodes::Scalar) : String
        text = scalar.value || ""
        if value = string_value(scalar)
          quote(value)
        elsif ArgsModuleRule::NULL_WORDS.includes?(text)
          "None"
        elsif ArgsModuleRule::BOOL_WORDS.includes?(text)
          true_spelling?(text) ? "True" : "False"
        else
          text
        end
      end

      private def quote(value : String) : String
        return "'#{value}'" unless value.includes?('\'')
        return %("#{value}") unless value.includes?('"')
        "'#{value.gsub("'", "\\'")}'"
      end

      private def true_spelling?(text : String) : Bool
        %w[yes Yes YES true True TRUE on On ON].includes?(text)
      end
    end
  end
end
