require "json"
require "yaml"

module Krikri
  module Lint
    # Upstream parity: ansible-lint's schema[meta] (severity VERY_HIGH,
    # tags core; profile basic). Validates a role's meta/main.yml against
    # our own JSON Schema (written from the public Galaxy metadata docs) with a
    # minimal Draft-07 validator (see json_schema.cr). Fires only in role
    # context, like upstream; reported at file start with no column.
    class SchemaMetaRule < Rule
      SCHEMA_TEXT = {{ read_file("#{__DIR__}/../schemas/meta.json") }}
      SCHEMA      = JSON.parse(SCHEMA_TEXT)

      def id : String
        "schema[meta]"
      end

      def severity : Severity
        Severity::VERY_HIGH
      end

      def tags : Array(String)
        ["core"]
      end

      def applies_to : Array(FileType)
        [FileType::META]
      end

      def check(file : PositionedFile, violations : Array(Violation)) : Nil
        return unless in_role?(file.path)
        root = file.root
        return if root.nil? || file.parse_error
        return unless root.is_a?(YAML::Nodes::Mapping)
        result = JsonSchema.validate(SchemaValidation.instance(root), SCHEMA)
        return if result.valid?
        err = result.error || raise "expected error"
        violations << Violation.new(file.path, 1, 0, id, severity,
          "#{SchemaValidation.message(err)}. See https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html#using-role-dependencies",
          nil, false, SchemaValidation::DETAILS)
      end

      # Upstream only schema-validates meta when the file belongs to a
      # role: either the roles/ path pattern or a sibling tasks/ dir.
      private def in_role?(path : String) : Bool
        parts = path.split('/')
        roles_idx = parts.index("roles")
        if roles_idx && parts.size > roles_idx + 2 &&
           parts[roles_idx + 2] == "meta"
          return true
        end
        # a <dir>/meta/main.yml file marks the dir as a role, even
        # without tasks/ yet (matches upstream's classification)
        parts.size >= 2 && parts[-2] == "meta"
      end
    end
  end
end
