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
        ["idiom"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
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

      # Upstream regex: r".*\{\{.*\}\}.*\w.*$" - a Jinja expression
      # followed by more word characters means templating is not at the
      # end of the name.
      private def templated_inside?(name : String) : Bool
        name =~ /.*\{\{.*\}\}.*\w.*$/ ? true : false
      end
    end
  end
end
