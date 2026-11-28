module Krikri
  module Lint
    # Upstream's parser-error: the AnsibleParserError ansible-core's
    # ModuleArgsParser raises while it normalizes a task, i.e. a task the
    # playbook loader itself rejects. ansible-lint raises it out of the
    # task pipeline its matchtask rules share, so a file with one reports
    # this match plus whatever its YAML-level rules find, and nothing
    # from any task-level rule (verified against ansible-lint 25.2.1).
    # Separate from load-failure, which is the YAML load itself failing.
    # The runner emits the match; this class carries the rule's identity
    # and the detection.
    class ParserErrorRule < Rule
      # Only a lintable ansible-lint loads as a task list reaches
      # ModuleArgsParser: a role's tasks/handlers files (a playbook's
      # tasks are covered by its own syntax check, which reports
      # syntax-check[specific] instead). A loose yaml file is never
      # parsed for tasks, so it can hold neither error.
      TASK_LIST_TYPES = [FileType::TASKS, FileType::HANDLERS]

      def id : String
        "parser-error"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["core"]
      end

      def applies_to : Array(FileType)
        TASK_LIST_TYPES
      end

      # Upstream builds a `# noqa` skip from a task's normalized form, and
      # the rejected task never gets one; the rule's category tag in the
      # skip list does not reach it either, since the match is raised
      # outside the per-rule skip pipeline. Only a skip_list entry naming
      # the rule itself drops the match (verified against ansible-lint
      # 25.2.1).
      def suppressible? : Bool
        false
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        if match = self.class.violation(file)
          violations << match
        end
      end

      # The first ModuleArgsParser failure in the file, positioned where
      # upstream reports it: the offending task mapping's own start (a
      # named task points at `name`, column 3 under a `- `), carrying
      # Ansible's own message. The walk follows the loader's own statement
      # order, and ansible stops at the first failure, so a file never
      # reports more than one.
      def self.violation(file : PositionedFile) : Violation?
        return nil unless TASK_LIST_TYPES.includes?(file.file_type)
        TaskWalker.each_statement(file) do |node|
          if message = ModuleArgsParser.failure(node)
            return Violation.new(file.path, NodeUtil.line(node),
              NodeUtil.column(node), "parser-error", Severity::VERY_HIGH,
              message, nil, false, "", "warning")
          end
        end
        nil
      end
    end
  end
end
