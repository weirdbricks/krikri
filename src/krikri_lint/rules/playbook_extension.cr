module Krikri
  module Lint
    # Upstream parity: ansible-lint's playbook-extension (severity MEDIUM,
    # tags formatting, basic profile). matchyaml reports the file once,
    # with no position of its own (create_matcherror(filename=file)), so
    # the violation sits at line 1, column 0. Upstream keeps a per-path
    # `done` list because a Lintable can be visited more than once;
    # krikri walks each linted path once, so one check is an idempotent
    # single report.
    #
    # Upstream's default kind patterns only make *.yml/*.yaml playbooks,
    # so firing needs a `.ansible-lint` kinds entry mapping another
    # extension to playbook (what the fixture pins). krikri never reads
    # kinds: and its FileType falls back to PLAYBOOK for any target that
    # is not role content, so an explicitly named demo.play already
    # carries the classification that entry gives it upstream.
    class PlaybookExtensionRule < Rule
      MESSAGE = %(Use ".yml" or ".yaml" playbook extension.)

      def id : String
        "playbook-extension"
      end

      def severity : Severity
        Severity::MEDIUM
      end

      def tags : Array(String)
        ["formatting"]
      end

      def applies_to : Array(FileType)
        [FileType::PLAYBOOK]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        extension = File.extname(file.path)
        return if extension == ".yml" || extension == ".yaml"
        violations << Violation.new(file.path, 1, 0, id, severity, MESSAGE)
      end
    end
  end
end
