require "json"
require "yaml"

module Krikri
  module Lint
    # Upstream parity: ansible-lint's schema[playbook] (severity
    # VERY_HIGH, tags core; profile basic). Validates a playbook against
    # the schema ansible-lint ships for that kind (bundled here as
    # schemas/playbook.json, copied verbatim from its 25.2.1 release) and
    # reports only the first, best-match error at the top of the file,
    # because jsonschema positions carry no line numbers.
    class SchemaPlaybookRule < Rule
      SCHEMA = JSON.parse({{ read_file("#{__DIR__}/../schemas/playbook.json") }})

      def id : String
        "schema[playbook]"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["core"]
      end

      def applies_to : Array(FileType)
        [FileType::PLAYBOOK]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        root = file.root || return
        # Upstream only upgrades a generic yaml lintable to the playbook
        # kind when it holds plays, and a file that is not a play list at
        # all fails ansible's syntax check, which keeps every other rule
        # (this one included) off it.
        return unless FileType.playbook_document?(root)
        error = JsonSchema.upstream_error(SchemaValidation.instance(root), SCHEMA)
        return unless error
        violations << Violation.new(file.path, 1, 0, id, severity,
          SchemaValidation.upstream_message(error, SCHEMA),
          nil, false, SchemaValidation::DETAILS)
      end
    end
  end
end
