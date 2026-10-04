module Krikri
  module Lint
    # Reports files that fail to load, the way ansible-lint does: the
    # match is shown as a warning but still counts as a failure, and no
    # other rule runs on the file. Upstream's syntax-check rule is a
    # separate mechanism (it shells out to a real playbook syntax
    # check, which needs module resolution krikri-lint does not have),
    # so a YAML load failure is a load-failure here, not a syntax-check.
    class LoadFailureRule < Rule
      def id : String
        "load-failure"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["core", "unskippable"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        return unless file.parse_error
        violations << Violation.new(file.path, 1, 0, "load-failure[runtimeerror]",
          severity, "Failed to load YAML file: #{File.expand_path(file.path)}",
          nil, false, "", "warning")
      end
    end
  end
end
