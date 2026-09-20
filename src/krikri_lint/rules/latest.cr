module Krikri
  module Lint
    # Upstream parity: ansible-lint's latest rule (severity MEDIUM,
    # tags idempotency) for the git/hg VCS sub-rules. latest[git] fires
    # when version is missing or "HEAD"; latest[hg] for revision
    # missing or "default".
    class LatestRule < Rule
      def id : String
        "latest"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["idempotency"]
      end

      def applies_to : Array(FileType)
        FileType.values
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        TaskWalker.each_task(file) do |task|
          case task.bare_module
          when "git"
            version = task.param("version") || "HEAD"
            if version == "HEAD"
              violations << Violation.new(file.path, task.line, 0,
                "latest[git]", severity,
                "Result of the command may vary on subsequent runs.", task.line)
            end
          when "hg"
            revision = task.param("revision") || "default"
            if revision == "default"
              violations << Violation.new(file.path, task.line, 0,
                "latest[hg]", severity,
                "Result of the command may vary on subsequent runs.", task.line)
            end
          end
        end
      end
    end
  end
end
