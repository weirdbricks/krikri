module Krikri
  module Lint
    # Upstream's syntax-check rule, for the one failure kind krikri-lint
    # can reach a verdict on without running ansible itself: a play
    # `roles:` entry naming a role no search path holds. Ansible aborts
    # playbook load at that entry, so the playbook gets only this match
    # and no other rule runs on it (upstream's failed-file gate).
    class SyntaxCheckRule < Rule
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
    end
  end
end
