module Krikri
  module Lint
    # Upstream parity: ansible-lint's loop-var-prefix rule (severity
    # MEDIUM, tags idiom; profiles.yml never lists it, so it only runs at
    # the production profile). A loop in a role can silently shadow the
    # play's own `item`, so a project that opts in with
    # `loop_var_prefix:` in .ansible-lint expects every role loop to use a
    # loop_control.loop_var matching that (role-substituted) regex. Two
    # arms: [missing] for a loop with no loop_var at all, [wrong] for one
    # that names a loop_var the pattern rejects. Upstream's default is
    # disabled (the key is unset), which is why no project gained new
    # failures when the rule landed.
    class LoopVarPrefixRule < Rule
      # Upstream's messages quote the configured template verbatim, not
      # the compiled regex (`{role}` stays unexpanded).
      MISSING_MESSAGE = "Replace unsafe implicit `item` loop variable by " \
                        "adding a `loop_var` that is matching /%s/ regex."
      WRONG_MESSAGE = "Loop variable name does not match /%s/ regex, " \
                      "where role=%s."
      # Upstream's own sub-tag for each arm; matches carry it, while the
      # rule registers (and skips) as the `loop-var-prefix` family.
      MISSING_TAG = "loop-var-prefix[missing]"
      WRONG_TAG   = "loop-var-prefix[wrong]"

      # Upstream reads `loop_control.get("loop_var", "")` and takes the
      # missing arm whenever that value is falsy, so an unquoted `false`,
      # `0` or `null` counts as no loop_var at all while a quoted string
      # (a template included) counts as one.
      FALSEY_PLAIN = %w[~ null Null NULL false False FALSE no No NO off Off OFF]

      def id : String
        "loop-var-prefix"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["idiom"]
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
        configured = config.loop_var_prefix
        return if configured.nil? || configured.empty?
        # Upstream reaches this rule only through a lintable whose
        # Lintable.role is set, i.e. a file under a roles/ directory.
        role = FileType.role_name(file.path) || return
        identifier = to_identifier(role)
        pattern = Regex.new(configured.gsub("{role}", identifier))
        TaskWalker.each_task(file) do |task|
          next unless looped?(task)
          if loop_var_set?(task)
            write_wrong(file, task, pattern, configured, identifier, violations)
          else
            write_missing(file, task, configured, violations)
          end
        end
      end

      # Python's re.match anchors at the start but accepts a partial
      # match, unlike Crystal's Regex#matches?, which searches.
      private def write_wrong(file : PositionedFile, task : LintTask,
                              pattern : Regex, configured : String,
                              identifier : String,
                              violations : Array(Violation)) : Nil
        value_node = loop_var_node(task) || return
        value = NodeUtil.scalar_value(value_node) || ""
        return if pattern.match(value).try(&.begin(0)) == 0
        violations << Violation.new(file.path, NodeUtil.line(value_node),
          NodeUtil.column(value_node), WRONG_TAG, severity,
          WRONG_MESSAGE % {configured, identifier}, task.line)
      end

      # Upstream hands create_matcherror the loop VALUE (or, for a
      # `with_<lookup>` loop, the key's own name) as the match data, so
      # the match sits at that node's first token: the first entry's dash
      # for a block sequence, the `[` for a flow one, or the scalar.
      private def write_missing(file : PositionedFile, task : LintTask,
                                configured : String,
                                violations : Array(Violation)) : Nil
        position = loop_position(task) || return
        violations << Violation.new(file.path, NodeUtil.line(position),
          NodeUtil.column(position), MISSING_TAG, severity,
          MISSING_MESSAGE % configured, task.line)
      end

      # Upstream treats a task as a loop when it carries `loop` or any
      # `with_*` key.
      private def looped?(task : LintTask) : Bool
        return true if task.has_task_key?("loop")
        found = false
        NodeUtil.each_entry(task.node) do |key_node, _|
          key = NodeUtil.scalar_value(key_node)
          found = true if key.try(&.starts_with?("with_"))
        end
        found
      end

      private def loop_position(task : LintTask) : YAML::Nodes::Node?
        if entry = NodeUtil.entry(task.node, "loop")
          return entry[1]
        end
        NodeUtil.each_entry(task.node) do |key_node, _|
          key = NodeUtil.scalar_value(key_node)
          return key_node if key.try(&.starts_with?("with_"))
        end
        nil
      end

      private def loop_var_node(task : LintTask) : YAML::Nodes::Node?
        entry = NodeUtil.entry(task.node, "loop_control") || return nil
        mapping = entry[1].as?(YAML::Nodes::Mapping) || return nil
        NodeUtil.entry(mapping, "loop_var").try(&.[1])
      end

      private def loop_var_set?(task : LintTask) : Bool
        node = loop_var_node(task) || return false
        python_truthy?(node)
      end

      # Python truthiness of the value PyYAML resolves the node to.
      private def python_truthy?(node : YAML::Nodes::Node) : Bool
        case node
        when YAML::Nodes::Mapping  then !node.nodes.empty?
        when YAML::Nodes::Sequence then !node.nodes.empty?
        when YAML::Nodes::Scalar   then scalar_truthy?(node)
        else                            true
        end
      end

      private def scalar_truthy?(scalar : YAML::Nodes::Scalar) : Bool
        value = scalar.value || ""
        # Quoted and block scalars are strings, so only "" is falsy.
        return !value.empty? unless scalar.style == YAML::ScalarStyle::PLAIN
        return false if value.empty? || FALSEY_PLAIN.includes?(value)
        !zero_number?(value)
      end

      # An unquoted number is a Python int/float after parsing, so 0/0.0
      # is falsy; anything that is not a number stays a truthy string.
      private def zero_number?(value : String) : Bool
        number = value.to_f?
        !number.nil? && number == 0.0
      end

      # ansiblelint.text.toidentifier: whitespace and hyphens become
      # underscores before the role name is interpolated into the regex.
      private def to_identifier(role : String) : String
        role.gsub(/[\s-]+/, "_")
      end
    end
  end
end
