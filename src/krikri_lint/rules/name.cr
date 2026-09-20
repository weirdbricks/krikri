module Krikri
  module Lint
    # Upstream parity: ansible-lint's `name` rule family
    # (severity MEDIUM, tags idiom), implemented as three sub-rules
    # matching upstream's message tags:
    #  - name[missing]: task has no name
    #  - name[casing]:  name does not start with an uppercase letter
    #  - name[template]: Jinja expression not at the end of the name
    class NameRule < Rule
      def id : String
        "name"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["autofix", "idiom"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        check_plays(file, violations)
        TaskWalker.each_task(file) do |task|
          name = task.name
          if name.nil? || name.empty?
            # Upstream reports name[missing] at the task line with no column.
            violations << Violation.new(file.path, task.line, 0,
              "name[missing]", severity, "All tasks should be named.", task.line)
            next
          end
          name_value = task.name_node
          line = name_value ? NodeUtil.line(name_value) : task.line
          column = name_value ? NodeUtil.column(name_value) : NodeUtil.column(task.node)
          if name[0].letter? && name[0].lowercase?
            violations << Violation.new(file.path, line, column,
              "name[casing]", severity,
              "All names should start with an uppercase letter.", task.line)
          end
          if templated_inside?(name)
            violations << Violation.new(file.path, line, column,
              "name[template]", severity,
              "Jinja templates should only be at the end of 'name'", task.line)
          end
        end
      end

      # Plays are checked like tasks but missing names get the
      # name[play] tag and point at the play mapping.
      private def check_plays(file : PositionedFile, violations : Array(Violation)) : Nil
        return unless TaskWalker.playbook_root?(file)
        root = file.root
        list = root.try(&.as?(YAML::Nodes::Sequence)) || return
        list.nodes.each do |item|
          play = item.as?(YAML::Nodes::Mapping) || next
          name = NodeUtil.entry(play, "name").try do |entry|
            NodeUtil.scalar_value(entry[1])
          end
          if name.nil? || name.empty?
            violations << Violation.new(file.path, NodeUtil.line(play),
              NodeUtil.column(play), "name[play]", severity,
              "All plays should be named.", NodeUtil.line(play))
            next
          end
          name_value = NodeUtil.entry(play, "name").try(&.[1])
          line = name_value ? NodeUtil.line(name_value) : NodeUtil.line(play)
          column = name_value ? NodeUtil.column(name_value) : NodeUtil.column(play)
          if name[0].letter? && name[0].lowercase?
            violations << Violation.new(file.path, line, column,
              "name[casing]", severity,
              "All names should start with an uppercase letter.", NodeUtil.line(play))
          end
        end
      end

      def fixable? : Bool
        true
      end

      # Mirrors upstream's name[casing] transform: capitalize the first
      # character of the name (prefix "file | " names keep their prefix)
      # and update any handler notify references using the old name.
      def fix(buffer : FixBuffer, file : PositionedFile, violation : Violation) : Bool
        return false unless violation.rule_id == "name[casing]"
        line = buffer.line_text(violation.line) || return false
        span = FixSpan.scalar_span(line, violation.column) || return false

        task_name = name_at(file, violation) || return false
        updated = update_task_name(task_name)
        return false if updated == task_name

        replacement = quoted_replacement(line, violation.column, span, updated)
        return false unless buffer.replace_span(violation.line,
                              span[0] + 1, span[1] - span[0], replacement)

        sync_notify(buffer, file, task_name, updated)
        true
      end

      private def name_at(file : PositionedFile, violation : Violation) : String?
        root = file.root || return nil
        found = nil
        NodeUtil.walk(root) do |node|
          next unless node.is_a?(YAML::Nodes::Mapping)
          entry = NodeUtil.entry(node, "name")
          next unless entry
          value = entry[1]
          next unless NodeUtil.line(value) == violation.line &&
                      NodeUtil.column(value) == violation.column
          found = NodeUtil.scalar_value(value)
        end
        found
      end

      # Upstream's update_task_name: only the first character is
      # uppercased; a "prefix | name" keeps the prefix as-is.
      private def update_task_name(task_name : String) : String
        if task_name.includes?("|")
          file_name, _, rest = task_name.partition("|")
          stripped = rest.strip
          return task_name if stripped.empty?
          return "#{file_name.strip} | #{stripped[0].upcase}#{stripped[1..]}"
        end
        "#{task_name[0].upcase}#{task_name[1..]}"
      end

      private def quoted_replacement(line : String, column : Int32,
                                     span : {Int32, Int32}, value : String) : String
        quote = FixSpan.quote_char(line, column)
        quote ? "#{quote}#{value}#{quote}" : value
      end

      # Upstream also rewrites notify entries whose value equals the
      # original task name (string or list form).
      private def sync_notify(buffer : FixBuffer, file : PositionedFile,
                              old_name : String, new_name : String) : Nil
        TaskWalker.collect_tasks(file).each do |task|
          notify_entry = NodeUtil.entry(task.node, "notify") || next
          rewrite_scalar(buffer, notify_entry[1], old_name, new_name)
          notify_entry[1].as?(YAML::Nodes::Sequence).try do |seq|
            seq.nodes.each { |item| rewrite_scalar(buffer, item, old_name, new_name) }
          end
        end
      end

      private def rewrite_scalar(buffer : FixBuffer, node : YAML::Nodes::Node,
                                 old_name : String, new_name : String) : Nil
        return unless NodeUtil.scalar_value(node) == old_name
        line_no = NodeUtil.line(node)
        line = buffer.line_text(line_no) || return
        span = FixSpan.scalar_span(line, NodeUtil.column(node)) || return
        replacement = quoted_replacement(line, NodeUtil.column(node), span, new_name)
        buffer.replace_span(line_no, span[0] + 1, span[1] - span[0], replacement)
      end

      # Upstream regex: r".*\{\{.*\}\}.*\w.*$" - a Jinja expression
      # followed by more word characters means templating is not at the
      # end of the name.
      private def templated_inside?(name : String) : Bool
        name =~ /.*\{\{.*\}\}.*\w.*$/ ? true : false
      end
    end
  end
end
