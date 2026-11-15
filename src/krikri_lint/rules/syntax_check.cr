module Krikri
  module Lint
    # Upstream's syntax-check rule. ansible-lint runs
    # `ansible-playbook --syntax-check` once per playbook/role lintable
    # and turns the first load-time failure into a match, tagged with the
    # failure kind. krikri-lint reaches the same verdicts in-process: a
    # play `roles:` entry no search path holds is detected here
    # (RoleLookup), while an unresolvable module name needs the run's
    # targets to know which files a check loads - SyntaxCheck builds that
    # match and the runner's gate emits it. Either way the file the check
    # failed on gets only its syntax-check match and no other rule runs
    # on it (upstream's failed-file gate).
    class SyntaxCheckRule < Rule
      UNKNOWN_MODULE_TAG = "syntax-check[unknown-module]"
      MESSAGE_SUFFIX     = "This often indicates a misspelling, missing " \
                           "collection, or incorrect module path."

      def id : String
        "syntax-check"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["core", "unskippable"]
      end

      def applies_to : Array(FileType)
        [FileType::PLAYBOOK]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        missing = RoleLookup.first_missing(file) || return
        violations << Violation.new(file.path, missing.line, missing.column,
          "syntax-check[specific]", severity, missing.message)
      end

      # The match ansible's own error names for an unresolvable module:
      # the task mapping's position (so `- name: x` points at `name`, an
      # unnamed task at its module key) and the name exactly as the task
      # wrote it.
      def self.unknown_module(file : PositionedFile, task : LintTask,
                              name : String) : Violation
        Violation.new(file.path, NodeUtil.line(task.node),
          NodeUtil.column(task.node), UNKNOWN_MODULE_TAG, Severity::VERY_HIGH,
          "couldn't resolve module/action '#{name}'. #{MESSAGE_SUFFIX}")
      end
    end
  end
end
