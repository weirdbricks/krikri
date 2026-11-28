module Krikri
  module Lint
    # Upstream parity: ansible-lint's loop-var-prefix rule (severity
    # MEDIUM, tags idiom). A loop in a role can silently shadow the
    # play's own `item`, so a project that opts in with
    # `loop_var_prefix:` in .ansible-lint expects every explicit
    # loop_control.loop_var in a role to match that (role-substituted)
    # regex. Only the [wrong] arm is implemented; the implicit-`item`
    # [missing] arm is tracked separately.
    class LoopVarPrefixRule < Rule
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
          value_node = loop_var_node(task) || next
          value = NodeUtil.scalar_value(value_node)
          # An absent/empty loop_var is the [missing] arm, not this one.
          next if value.nil? || value.empty?
          # Python's re.match anchors at the start but accepts a partial
          # match, unlike Crystal's Regex#matches?, which searches.
          next if pattern.match(value).try(&.begin(0)) == 0
          violations << Violation.new(file.path, NodeUtil.line(value_node),
            NodeUtil.column(value_node), "loop-var-prefix[wrong]", severity,
            "Loop variable name does not match /#{configured}/ regex, " \
            "where role=#{identifier}.", task.line)
        end
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

      private def loop_var_node(task : LintTask) : YAML::Nodes::Node?
        entry = NodeUtil.entry(task.node, "loop_control") || return nil
        mapping = entry[1].as?(YAML::Nodes::Mapping) || return nil
        NodeUtil.entry(mapping, "loop_var").try(&.[1])
      end

      # ansiblelint.text.toidentifier: whitespace and hyphens become
      # underscores before the role name is interpolated into the regex.
      private def to_identifier(role : String) : String
        role.gsub(/[\s-]+/, "_")
      end
    end
  end
end
