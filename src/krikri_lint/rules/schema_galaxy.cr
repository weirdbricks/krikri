module Krikri
  module Lint
    # Upstream parity: ansible-lint's schema[galaxy] (severity VERY_HIGH,
    # tags core; profile basic). Validates a collection's galaxy.yml
    # against ansible-lint's galaxy.json schema. Like every schema tag it
    # reports only the first (best-match) error, at line 1 with no
    # column, because jsonschema positions carry no line numbers.
    class SchemaGalaxyRule < Rule
      SCHEMA = JSON.parse({{ read_file("#{__DIR__}/../schemas/galaxy.json") }})

      # Upstream reads this from the schema root's markdownDescription.
      DOCS_URL = "https://docs.ansible.com/ansible/latest/dev_guide/collections_galaxy_meta.html"

      def id : String
        "schema[galaxy]"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["core"]
      end

      def applies_to : Array(FileType)
        [FileType::GALAXY]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        root = file.root
        return if root.nil? || file.parse_error
        return unless root.is_a?(YAML::Nodes::Mapping)
        result = JsonSchema.validate(SchemaValidation.instance(root), SCHEMA)
        return if result.valid?
        err = result.error || raise "expected error"
        violations << Violation.new(file.path, 1, 0, id, severity,
          "#{SchemaValidation.message(err)}. See #{DOCS_URL}",
          nil, false, SchemaValidation::DETAILS)
      end
    end
  end
end
